<script setup lang="ts">
import { computed, ref } from 'vue'
import { api, type Project } from './api'
import { newId } from './notebook'
import { fileBase64 } from './sources'
const props = defineProps<{ accountId: string }>()
const emit = defineEmits<{ complete: [project: Project] }>()
interface Pending { command_id: string; title: string; fingerprint: string }
interface Preview { fingerprint: string; summary: { title: string; sheets: number; modules: number; files: number; bytes: number } }
const dialog = ref<HTMLDialogElement>(), busy = ref(false), error = ref(''), title = ref(''), preview = ref<Preview | null>(null)
const payload = ref<{ archive: string } | { entries: { path: string; data: string }[] } | null>(null)
const pending = ref<Pending | null>(null), state = ref('')
const key = `sputnik.import.pending.v1:${props.accountId}`
const canImport = computed(() => !!preview.value && !!payload.value && !!title.value.trim() && (!pending.value || pending.value.fingerprint === preview.value.fingerprint))
function remember(value: Pending | null) { pending.value = value; try { if (value) sessionStorage.setItem(key, JSON.stringify(value)); else sessionStorage.removeItem(key) } catch { /* Pending catalog imports can also be resumed from their project. */ } }
async function act(action: () => Promise<void>) {
  if (busy.value) return
  busy.value = true; error.value = ''
  try { await action() } catch (cause) { error.value = cause instanceof Error ? cause.message : 'The import failed. Your original file is unchanged.' }
  finally { busy.value = false }
}
async function check() {
  if (!pending.value) return
  const result = await api<{ state: string; project?: Project; title?: string; fingerprint?: string }>(`/api/imports/${pending.value.command_id}`)
  state.value = result.state
  if (result.state === 'complete' && result.project) { remember(null); dialog.value?.close(); emit('complete', result.project) }
  else if (result.fingerprint && result.title) { remember({ ...pending.value, title: result.title, fingerprint: result.fingerprint }); title.value = result.title }
}
function show(command?: string) {
  preview.value = null; payload.value = null; error.value = ''; state.value = ''; title.value = ''
  let previous: Pending | null = null
  try { const value = JSON.parse(sessionStorage.getItem(key) || 'null'); if (typeof value?.command_id === 'string' && typeof value?.title === 'string' && typeof value?.fingerprint === 'string') previous = value } catch { /* No saved browser command. */ }
  pending.value = command ? { command_id: command, title: '', fingerprint: '' } : previous
  if (pending.value) title.value = pending.value.title
  dialog.value?.showModal()
  if (pending.value) void act(check)
}
async function select(event: Event, folder: boolean) {
  const input = event.target as HTMLInputElement, files = [...(input.files || [])]
  input.value = ''
  if (!files.length) return
  await act(async () => {
    preview.value = null; payload.value = null
    if (folder) {
      if (files.length > 2049) throw new Error('A notebook accepts up to 2048 bundled files plus project.json.')
      let total = 0
      for (const file of files) { total += file.size; if (file.size > 16 * 1024 * 1024 || total > 71 * 1024 * 1024) throw new Error('This folder exceeds the supported notebook limits.') }
      const entries = []
      for (const file of files) entries.push({ path: file.webkitRelativePath || file.name, data: await fileBase64(file) })
      payload.value = { entries }
    } else {
      if (files.length !== 1 || files[0]!.size > 80 * 1024 * 1024) throw new Error('Choose one notebook ZIP up to 80 MiB.')
      payload.value = { archive: await fileBase64(files[0]!) }
    }
    const result = await api<Preview>('/api/imports/inspect', 'POST', payload.value)
    preview.value = result
    if (pending.value && pending.value.fingerprint && pending.value.fingerprint !== result.fingerprint) throw new Error('Select the original notebook used for the pending import.')
    if (!pending.value) title.value = result.summary.title || 'Imported Notebook'
  })
}
function start() { void act(async () => {
  if (!canImport.value || !preview.value || !payload.value) return
  if (!pending.value) remember({ command_id: newId('import'), fingerprint: preview.value.fingerprint, title: title.value.trim() })
  const result = await api<{ state: string; project: Project }>('/api/imports', 'POST', { ...pending.value!, ...payload.value })
  remember(null); dialog.value?.close(); emit('complete', result.project)
}) }
function newImport() { remember(null); preview.value = null; payload.value = null; title.value = ''; state.value = ''; error.value = '' }
defineExpose({ show })
</script>
<template>
  <dialog ref="dialog" class="notebook-dialog import-dialog" aria-labelledby="import-title" @cancel.prevent="!busy && dialog?.close()">
    <div class="dialog-heading"><div><h2 id="import-title">Import Notebook</h2><p>Open a copy in your server workspace</p></div><button class="plain icon-button" aria-label="Close import" :disabled="busy" @click="dialog?.close()">×</button></div>
    <p class="source-note">Choose a .sputnikbook folder from the desktop app, or a ZIP containing it. Inspecting the file does not create a project or run code.</p>
    <div v-if="pending" class="execution-message"><p>An import is pending. Check its status or select the original file to resume.</p><button :disabled="busy" @click="act(check)">Check import status</button><button :disabled="busy" @click="newImport">Start another import</button></div>
    <div class="import-choices"><label class="file-picker">Notebook ZIP<input aria-label="Notebook ZIP" type="file" accept=".zip,.sputnikbook" :disabled="busy" @change="select($event, false)"></label><label class="file-picker">Notebook folder<input aria-label="Notebook folder" type="file" webkitdirectory multiple :disabled="busy" @change="select($event, true)"></label></div>
    <p v-if="busy" class="source-note" role="status">{{ preview ? 'Importing notebook…' : 'Inspecting notebook…' }}</p>
    <p v-if="error" class="source-error" role="alert">{{ error }}</p>
    <template v-if="preview"><dl class="import-summary"><div><dt>Notebook</dt><dd>{{ preview.summary.title }}</dd></div><div><dt>Contents</dt><dd>{{ preview.summary.sheets }} sheets · {{ preview.summary.modules }} modules · {{ preview.summary.files }} files</dd></div><div><dt>Bundle size</dt><dd>{{ preview.summary.bytes.toLocaleString() }} bytes</dd></div></dl><label for="import-project-title">Project title</label><input id="import-project-title" v-model="title" required maxlength="200" :disabled="busy || !!pending"></template>
    <div class="dialog-actions"><button :disabled="busy" @click="dialog?.close()">Cancel</button><button class="primary" :disabled="busy || !canImport" @click="start">{{ pending ? 'Resume import' : 'Import as new notebook' }}</button></div>
  </dialog>
</template>
