<script setup lang="ts">
import { computed, ref } from 'vue'
import { api, apiBlob } from './api'
import { parseNotebook, type NotebookResponse, type StoredNotebook } from './notebook'
import { mergeDocument, mergeFiles, type MergeChoices } from './draft-merge'
import type { FileEdit, ProjectFile } from './sources'
import { download } from './rich'
const props = defineProps<{ projectId: string }>()
const emit = defineEmits<{ rebase: [value: { head: StoredNotebook; document: string; changes: Record<string, FileEdit | null> }] }>()
const dialog = ref<HTMLDialogElement>(), busy = ref(false), error = ref('')
const local = ref(''), base = ref(''), head = ref<StoredNotebook>()
const changes = ref<Record<string, FileEdit | null>>({}), baseFiles = ref<ProjectFile[]>([]), headFiles = ref<ProjectFile[]>([])
const choices = ref<MergeChoices>({})
const downloading = ref(false)
async function downloadVersion(path: string, saved: boolean) {
  if (downloading.value || !head.value) return
  downloading.value = true; error.value = ''
  try {
    const edit = changes.value[path], name = path.split('/').at(-1)!
    if (saved) download(await apiBlob(`/api/projects/${encodeURIComponent(props.projectId)}/notebook/download?revision=${head.value.revision}&path=${encodeURIComponent(path)}`), name)
    else if (edit) download(edit.encoding === 'utf8' ? new Blob([edit.data]) : new Blob([Uint8Array.from(atob(edit.data), char => char.charCodeAt(0))]), name)
  } catch (cause) { error.value = cause instanceof Error ? cause.message : 'Could not download this file.' }
  finally { downloading.value = false }
}
const merged = computed(() => {
  if (!head.value) return null
  try {
    const document = mergeDocument(base.value, local.value, head.value.document, choices.value)
    const files = mergeFiles(baseFiles.value, headFiles.value, changes.value, choices.value)
    return { document: document.document, changes: files.changes, conflicts: [...document.conflicts, ...files.conflicts], error: '' }
  } catch (cause) { return { document: '', changes: {}, conflicts: [], error: cause instanceof Error ? cause.message : 'Could not compare these drafts.' } }
})
const ready = computed(() => merged.value && !merged.value.error && merged.value.conflicts.every(item => choices.value[item.id]))
async function show(revision: string, original: string, draft: string, edits: Record<string, FileEdit | null>) {
  busy.value = true; error.value = ''; head.value = undefined; choices.value = {}
  base.value = original; local.value = draft; changes.value = JSON.parse(JSON.stringify(edits)); dialog.value?.showModal()
  const endpoint = `/api/projects/${encodeURIComponent(props.projectId)}/notebook`
  try {
    const result = await api<NotebookResponse>(endpoint)
    if (!result.notebook) throw new Error('The saved notebook is unavailable. Your draft is kept.')
    parseNotebook(result.notebook)
    const [before, after] = await Promise.all([
      api<{ entries: ProjectFile[] }>(`${endpoint}/files?revision=${revision}`),
      api<{ entries: ProjectFile[] }>(`${endpoint}/files?revision=${result.notebook.revision}`),
    ])
    baseFiles.value = before.entries; headFiles.value = after.entries; head.value = result.notebook
  } catch (cause) { error.value = cause instanceof Error ? cause.message : 'Could not load saved changes.' }
  finally { busy.value = false }
}
function apply() {
  if (!ready.value || !head.value || !merged.value) return
  try {
    parseNotebook({ revision: head.value.revision, document: merged.value.document })
    emit('rebase', { head: head.value, document: merged.value.document, changes: merged.value.changes }); dialog.value?.close()
  } catch { error.value = 'These choices do not form a supported notebook. Review deletions and required fields; your original draft is kept.' }
}
defineExpose({ show, isOpen: () => !!dialog.value?.open })
</script>

<template>
  <dialog ref="dialog" class="notebook-dialog save-conflict-dialog" aria-labelledby="save-conflict-title">
    <div class="dialog-heading"><h2 id="save-conflict-title">Review saved changes</h2><button class="plain icon-button" aria-label="Close saved changes" @click="dialog?.close()">×</button></div>
    <p>Independent changes are combined. Choose which version to keep for each overlapping change. This updates your draft; Save notebook commits it.</p>
    <p v-if="busy" role="status">Loading the current revision and file list…</p>
    <p v-if="error || merged?.error" class="source-error" role="alert">{{ error || merged?.error }}</p>
    <template v-if="!busy && merged && !merged.error">
      <p v-if="!merged.conflicts.length" role="status">No overlapping changes. Both editors’ changes can be kept.</p>
      <fieldset v-for="item in merged.conflicts" :key="item.id" class="merge-conflict">
        <legend>{{ item.label }}</legend>
        <div class="merge-versions"><label><span><input v-model="choices[item.id]" type="radio" :name="item.id" value="local" aria-label="Your draft">Your draft</span><pre>{{ item.local }}</pre></label><label><span><input v-model="choices[item.id]" type="radio" :name="item.id" value="remote" aria-label="Saved version">Saved version</span><pre>{{ item.remote }}</pre></label></div>
        <div v-if="item.file" class="merge-file-downloads"><button v-if="changes[item.file]" :disabled="downloading" @click="downloadVersion(item.file, false)">Download your file</button><button v-if="headFiles.some(file => file.path === item.file)" :disabled="downloading" @click="downloadVersion(item.file, true)">Download saved file</button></div>
      </fieldset>
    </template>
    <div class="dialog-actions"><button @click="dialog?.close()">Cancel</button><button class="primary" :disabled="busy || !ready" @click="apply">Update notebook draft</button></div>
  </dialog>
</template>
