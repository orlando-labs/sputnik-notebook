<script setup lang="ts">
import { ref } from 'vue'
import { api, apiBlob } from './api'
import { archiveName } from './sources'
import { download } from './rich'
const props = defineProps<{ projectId: string; title: string }>()
const dialog = ref<HTMLDialogElement | null>(null)
const rows = ref<{ revision: string; title: string }[]>([])
const head = ref(''), next = ref<string | null>(null), busy = ref(false), error = ref('')
const base = `/api/projects/${encodeURIComponent(props.projectId)}/notebook`
async function load(older = false) {
  if (busy.value) return
  busy.value = true; error.value = ''
  try {
    const result = await api<{ head: string; revisions: typeof rows.value; next: string | null }>(`${base}/revisions${older && next.value ? `?before=${next.value}` : ''}`)
    rows.value = older ? [...rows.value, ...result.revisions] : result.revisions; head.value = result.head; next.value = result.next
  } catch (cause) { error.value = cause instanceof Error ? cause.message : 'Could not load revision history.' }
  finally { busy.value = false }
}
async function exportRevision(revision: string) {
  busy.value = true; error.value = ''
  try { download(await apiBlob(`${base}/archive?revision=${revision}`), archiveName(`${props.title}-${revision.slice(0, 8)}`)) }
  catch (cause) { error.value = cause instanceof Error ? cause.message : 'Could not export this revision.' }
  finally { busy.value = false }
}
function show() { dialog.value?.showModal(); void load() }
defineExpose({ show })
</script>

<template>
  <dialog ref="dialog" class="notebook-dialog history-dialog" aria-labelledby="history-title">
    <div class="dialog-heading"><div><h2 id="history-title">Saved revisions</h2><p>{{ title }}</p></div><button class="plain icon-button" aria-label="Close revision history" @click="dialog?.close()">×</button></div>
    <p class="source-note">Export a saved revision to open locally or import it as a separate notebook. Your current draft is kept.</p>
    <p v-if="error" class="source-error" role="alert">{{ error }}</p>
    <ul class="revision-list"><li v-for="row in rows" :key="row.revision"><div><strong>{{ row.title }}</strong><code>{{ row.revision }}</code></div><span v-if="row.revision === head" class="role-badge">Current</span><button :disabled="busy" :aria-label="`Export revision ${row.revision}`" @click="exportRevision(row.revision)">Export…</button></li></ul>
    <p v-if="busy" class="source-note" role="status">Loading…</p>
    <div class="dialog-actions"><button v-if="next" :disabled="busy" @click="load(true)">Older revisions</button><button :disabled="busy" @click="load()">Refresh</button><button @click="dialog?.close()">Done</button></div>
  </dialog>
</template>
