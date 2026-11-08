<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { api, APIError } from './api'
import { documentJSON } from './document-json'
import { newId, parseNotebook, type NotebookDocument, type NotebookResponse } from './notebook'
import { terminal, type CellPresentation, type RunResult, type RunSummary } from './execution'
import { secondsLabel, type ResourceStatus } from './resource-policy'
import NotebookCellOutput from './NotebookCellOutput.vue'
import NotebookTextEditor from './NotebookTextEditor.vue'
import NotebookCodeEditor from './NotebookCodeEditor.vue'
import type { CodeDiagnostic } from './diagnostics'
import { textVariables as resolveTextVariables } from './text-variables'
const props = defineProps<{ projectId?: string; publicTemplate?: string; enabled: boolean }>()
const publicMode = computed(() => !!props.publicTemplate)
const openingCommand = ref('')
const dialog = ref<HTMLDialogElement>(), document = ref<NotebookDocument | null>(null), session = ref(''), revision = ref(''), saved = ref(''), activeSheet = ref('')
const resources = ref<ResourceStatus | null>(null), runs = ref<RunSummary[]>([]), result = ref<RunResult | null>(null), error = ref(''), busy = ref(false), stale = ref(false)
const errorTarget = ref<{ cell: string; diagnostic: CodeDiagnostic }>()
function revealError(cell: string, diagnostic: CodeDiagnostic) { errorTarget.value = { cell, diagnostic: { ...diagnostic } } }
type Command = { kind: 'save' | 'run' | 'stop'; path: string; method: string; body: { command_id: string; [key: string]: unknown } }
const pending = ref<Command | null>(null), retryable = ref(false)
let timer: ReturnType<typeof setTimeout> | undefined, generation = 0, disposed = false, refreshing = false
const dirty = computed(() => !!document.value && documentJSON(document.value) !== saved.value)
const sheet = computed(() => document.value?.sheets.find(sheet => sheet.id === activeSheet.value))
const active = computed(() => runs.value.find(run => !terminal(run.state)))
const locked = computed(() => busy.value || !!pending.value || stale.value)
const prefix = () => publicMode.value ? '/api/public/sessions' : '/api/preview-sessions'
const base = () => `${prefix()}/${encodeURIComponent(session.value)}`
function clear() { generation++; clearTimeout(timer); document.value = null; resources.value = null; runs.value = []; result.value = null; revision.value = ''; saved.value = ''; pending.value = null; retryable.value = false; busy.value = false; stale.value = false; refreshing = false }
function abandon() {
  const token = session.value; session.value = ''; clear()
  return token ? api(`${prefix()}/${encodeURIComponent(token)}`, 'DELETE').catch(() => { /* The independent short lease also erases abandoned copies. */ }) : Promise.resolve()
}
function close() { abandon(); openingCommand.value = ''; dialog.value?.close() }
function fail(cause: unknown) {
  error.value = cause instanceof Error ? cause.message : 'Could not read the temporary notebook.'
  // A disconnected preview is deliberately never reattached or replayed.
  if (!(cause instanceof APIError) || [401, 403, 404, 410, 503].includes(cause.status) && cause.code !== 'execution_budget_exhausted') stale.value = true
}
async function open() {
  if (!props.enabled || busy.value) return
  const retired = abandon(); error.value = ''; busy.value = true; dialog.value?.showModal()
  const version = generation
  try {
    await retired
    if (disposed || version !== generation) return
    const command = publicMode.value ? (openingCommand.value ||= newId('public_open')) : ''
    const endpoint = publicMode.value ? prefix() : `/api/projects/${encodeURIComponent(props.projectId!)}/preview-sessions`
    const opened = await api<{ session_id: string; resources: ResourceStatus }>(endpoint, 'POST', publicMode.value ? { template_id: props.publicTemplate, command_id: command } : {})
    if (disposed || version !== generation) { void api(`${prefix()}/${encodeURIComponent(opened.session_id)}`, 'DELETE').catch(() => {}); return }
    openingCommand.value = ''
    session.value = opened.session_id; resources.value = opened.resources
    const response = await api<NotebookResponse>(base())
    if (disposed || version !== generation || !response.notebook) return
    document.value = parseNotebook(response.notebook); revision.value = response.notebook.revision; saved.value = documentJSON(document.value); activeSheet.value = document.value.sheets[0]!.id
    schedule()
  } catch (cause) { if (version === generation) { if (cause instanceof APIError && cause.status < 500) openingCommand.value = ''; fail(cause) } }
  finally { if (version === generation) busy.value = false }
}
function schedule() { clearTimeout(timer); if (!disposed && session.value && !stale.value && dialog.value?.open) timer = setTimeout(() => void refresh(), 1000) }
function accepted(command: Command, response: { run?: RunSummary; revision?: string; notebook?: { revision: string } }) {
  if (command.kind === 'save') {
    const next = response.notebook?.revision || response.revision
    if (!next) throw new Error('The saved revision was not confirmed. Check command status.')
    revision.value = next; saved.value = command.body.document as string
  }
  if (response.run) runs.value = [...runs.value.filter(run => run.id !== response.run!.id), response.run]
  pending.value = null; retryable.value = false
}
async function checkPending() {
  const command = pending.value, token = session.value
  if (!command) return
  const response = await api<{ command: { state: string; run?: RunSummary; revision?: string } }>(`${base()}/commands/${encodeURIComponent(command.body.command_id)}`)
  if (token !== session.value || pending.value?.body.command_id !== command.body.command_id) return
  if (response.command.state === 'accepted') { accepted(command, response.command); error.value = '' }
  else retryable.value = true
}
async function refresh() {
  if (refreshing || !session.value || stale.value || disposed) return
  refreshing = true; const version = generation
  try {
    const endpoint = base()
    await api(endpoint + '/lease', 'POST', {})
    if (version !== generation) return
    const response = await api<{ resources: ResourceStatus; runs: RunSummary[] }>(endpoint)
    if (version !== generation) return
    resources.value = response.resources; runs.value = response.runs
    await checkPending()
    if (version !== generation) return
    const latest = runs.value.filter(run => run.sheet_id === activeSheet.value).at(-1)
    if (latest) { const detail = await api<{ run: RunResult }>(`${endpoint}/runs/${encodeURIComponent(latest.id)}`); if (version === generation) result.value = detail.run }
  } catch (cause) { if (version === generation) fail(cause) }
  finally { if (version === generation) { refreshing = false; schedule() } }
}
async function send(command: Command) {
  if (busy.value || !session.value || stale.value) return
  busy.value = true; error.value = ''; pending.value = command; retryable.value = false; const version = generation
  try { const response = await api(command.path, command.method, command.body); if (version === generation) accepted(command, response as Parameters<typeof accepted>[1]) }
  catch (cause) {
    if (version !== generation) return
    if (cause instanceof APIError && cause.status < 500) { pending.value = null; fail(cause) }
    else { error.value = 'Command outcome is uncertain. Check status before an explicit retry.'; try { await checkPending() } catch (check) { if (version === generation) fail(check) } }
  } finally { if (version === generation) { busy.value = false; schedule() } }
}
function save() { if (!document.value || !dirty.value || locked.value) return; void send({ kind: 'save', path: base() + '/notebook', method: 'PUT', body: { command_id: newId('preview_save'), base_revision: revision.value, document: documentJSON(document.value) } }) }
function run() {
  const cell = sheet.value?.cells.find(cell => cell.kind === 'code')
  if (!cell || locked.value || dirty.value || active.value || resources.value?.remaining_ms === '0') return
  void send({ kind: 'run', path: base() + '/runs', method: 'POST', body: { command_id: newId('preview_run'), revision: revision.value, sheet_id: activeSheet.value, cell_id: cell.id, action: 'run_all' } })
}
function stop(force = false) {
  if (!active.value || busy.value || pending.value || stale.value) return
  if (force && !window.confirm('Force stop the temporary worker? Open a fresh preview before running again.')) return
  void send({ kind: 'stop', path: `${base()}/runs/${encodeURIComponent(active.value.id)}/stop`, method: 'POST', body: { command_id: newId('preview_stop'), runtime_epoch: active.value.runtime_epoch, force } })
}
function presentation(id: string, source: string): CellPresentation | null {
  if (result.value?.sheet_id !== activeSheet.value) return null
  const cell = (active.value ? result.value.live_cells : result.value.cells).find(cell => cell.id === id) || result.value.cells.find(cell => cell.id === id)
  return cell ? { ...cell, rich: { ...cell, audio_stale: dirty.value || stale.value || !!result.value.environment_stale || cell.source !== source || result.value.revision !== revision.value || !active.value && cell.rich_stale }, stale: dirty.value || stale.value || !!result.value.environment_stale || cell.source !== source || result.value.revision !== revision.value, running: !!active.value && active.value.executing_cell === id, active: !!active.value, identity: result.value.id + ':' + id } : null
}
function textVariables(before: string) {
  const values: Record<string, CellPresentation> = {}
  for (const cell of sheet.value?.cells || []) { if (cell.kind !== 'code') continue; const value = presentation(cell.id, cell.source); if (value) values[cell.id] = value }
  return resolveTextVariables(sheet.value, values, before)
}
function visibility() { if (window.document.hidden && session.value) { abandon(); error.value = 'The temporary preview was discarded when this tab was hidden. Open a fresh preview to continue.' } }
function offline() { if (session.value) { abandon(); error.value = 'Connection lost. Open a fresh preview after reconnecting.' } }
onMounted(() => { window.document.addEventListener('visibilitychange', visibility); window.addEventListener('offline', offline) })
onUnmounted(() => { disposed = true; abandon(); window.document.removeEventListener('visibilitychange', visibility); window.removeEventListener('offline', offline) })
defineExpose({ show: open, isOpen: () => !!dialog.value?.open })
</script>
<template>
  <dialog ref="dialog" class="notebook-dialog preview-dialog" aria-labelledby="preview-title" @cancel.prevent="close" @close="abandon" @keydown.meta.s.prevent.stop="save" @keydown.ctrl.s.prevent.stop="save">
    <div class="dialog-heading"><div><h2 id="preview-title">{{ publicMode ? 'Public notebook' : 'Temporary preview' }}</h2><p>Public execution limits · up to 60 seconds total</p></div><button class="plain icon-button" aria-label="Close temporary preview" @click="close">×</button></div>
    <p class="source-note">Work in a disposable copy of the saved notebook. The template is unchanged. Execution across runs shares a 60-second wall-time budget; simultaneous runs add their time. {{ publicMode ? 'New copies share the remaining budget of this browser session.' : 'Owner/server limits can reduce it.' }} Closing, hiding or disconnecting this preview discards the copy.</p>
    <div v-if="resources" class="resource-usage" data-testid="preview-budget"><span>Used: {{ secondsLabel(resources.spent_ms) }}</span><strong>Remaining: {{ secondsLabel(resources.remaining_ms) }}</strong><span>One run: {{ resources.effective.run_seconds }} s</span></div>
    <p v-if="busy && !document" role="status">Opening a fresh temporary copy…</p><p v-if="error" role="alert" class="source-error">{{ error }}</p><p v-if="resources?.remaining_ms === '0'" role="status">The preview execution budget is exhausted. You can still inspect results or close this copy.</p>
    <div v-if="pending" class="execution-message" role="status">Checking command outcome. No command is repeated automatically.<button :disabled="busy || stale" @click="refresh">Check preview command</button><button v-if="retryable" :disabled="busy || stale" @click="send(pending!)">Retry preview command</button></div>
    <template v-if="document"><div class="preview-toolbar"><select v-model="activeSheet" aria-label="Preview sheet" :disabled="locked"><option v-for="sheet in document.sheets" :key="sheet.id" :value="sheet.id">{{ sheet.title }}</option></select><button :disabled="locked || !dirty" @click="save">Save preview copy</button><button :disabled="locked || dirty || !!active || resources?.remaining_ms === '0' || !sheet?.cells.some(cell => cell.kind === 'code')" @click="run">Run preview sheet</button><button :disabled="!active || busy || !!pending || stale" @click="stop()">Stop preview</button><button v-if="active" :disabled="busy || !!pending || stale" @click="stop(true)">Force Stop preview…</button></div>
      <p role="status" class="source-note">{{ dirty ? 'Preview has unsaved changes. Save this copy before running.' : 'Preview copy saved' }}</p>
      <p v-if="result?.error || result?.environment_error || result?.rich_error" class="source-error" role="alert">{{ result.error || result.environment_error || result.rich_error }}</p><pre v-for="(message, index) in result?.task_errors || []" :key="index" class="source-error">{{ message }}</pre>
      <div class="notebook-cells"><article v-for="(cell, index) in sheet?.cells || []" :key="cell.id" class="notebook-cell"><div class="cell-toolbar">{{ index + 1 }} · {{ cell.kind }}</div><NotebookTextEditor v-if="cell.kind === 'text'" :content="cell" :label="'Preview text cell ' + (index + 1)" :disabled="locked" :variables="textVariables(cell.id)" @change="cell.source = $event.source; cell.formatting = $event.formatting" /><NotebookCodeEditor v-else v-model="cell.source" :label="'Preview code cell ' + (index + 1)" :readonly="cell.kind !== 'code'" :disabled="locked" :sputnik="cell.kind === 'code'" :diagnostics="presentation(cell.id, cell.source)?.diagnostics" :reveal-diagnostic="errorTarget?.cell === cell.id ? errorTarget.diagnostic : undefined" :stale="presentation(cell.id, cell.source)?.stale" /><NotebookCellOutput v-if="presentation(cell.id, cell.source)" :presentation="presentation(cell.id, cell.source)!" @reveal-error="revealError(cell.id, $event)" /></article></div>
      <p class="source-note">This preview supports sheet source edits and Run All with existing bundled dependencies. Boards, parameter controls and dependency installation use the full notebook workspace.</p>
    </template>
    <div class="dialog-actions"><button :disabled="busy || !enabled" @click="open">{{ openingCommand ? 'Retry opening public copy' : 'Open fresh preview' }}</button><button @click="close">Close preview</button></div>
  </dialog>
</template>
