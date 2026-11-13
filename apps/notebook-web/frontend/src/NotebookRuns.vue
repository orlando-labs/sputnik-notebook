<script setup lang="ts">
import { computed, onUnmounted, ref, watch } from 'vue'
import { api, APIError } from './api'
import { newId, type NotebookDocument } from './notebook'
import { runLabel, terminal, type RunSummary } from './execution'
import { compareRuns, comparisonCSV, restoreError, restoreValues, type RunMetadata, type RunSnapshot } from './run-history'
import { defaultJSON, type InputState } from './inputs'
import { download } from './rich'
import NotebookCellOutput from './NotebookCellOutput.vue'
import { emptyPresentation } from './boards'
const props = defineProps<{ projectId: string; accountId: string; guest?: boolean; document: NotebookDocument; revision: string; sheetId: string; writable: boolean; canRestore: boolean; states: Record<string, InputState>; onRestore: (cell: string | null, values: Record<string, string>, version: string) => Promise<boolean> }>()
const emit = defineEmits<{ changed: [] }>()
const dialog = ref<HTMLDialogElement>(), runs = ref<RunSummary[]>([]), before = ref<string | null>(null), selected = ref(''), baseline = ref(''), compare = ref(false)
const snapshot = ref<RunSnapshot | null>(null), other = ref<RunSnapshot | null>(null), metadata = ref<RunMetadata | null>(null)
const title = ref(''), error = ref(''), note = ref(''), loading = ref(false), busy = ref(false), scope = ref('project'), review = ref(false), deleting = ref(false), sheetFilter = ref('')
const frozenVersion = ref(''), frozenRevision = ref(''), pending = ref<{ run: string; body: { command_id: string; base_version: string; operation: string; title: string; pinned: boolean } } | null>(null), unknown = ref(false)
const base = `/api/projects/${encodeURIComponent(props.projectId)}`
const storageKey = `sputnik.history.pending.v1:${props.accountId}:${props.projectId}`
let disposed = false, generation = 0, timer: ReturnType<typeof setTimeout> | undefined, controller: AbortController | undefined
if (!props.guest) try { const value = JSON.parse(sessionStorage.getItem(storageKey) || 'null'); if (typeof value?.run === 'string' && typeof value.body?.command_id === 'string' && ['update', 'delete'].includes(value.body?.operation)) pending.value = value } catch { /* Receipts remain authoritative. */ }
const visible = computed(() => runs.value.filter(run => !sheetFilter.value || run.sheet_id === sheetFilter.value))
const comparisons = computed(() => snapshot.value && other.value ? compareRuns(other.value, snapshot.value) : [])
const currentState = computed(() => props.states[scope.value])
const restore = computed(() => snapshot.value ? restoreValues(snapshot.value, props.document, scope.value) : {})
const invalid = computed(() => snapshot.value ? restoreError(snapshot.value, props.document, scope.value) : 'Choose a run.')
const stale = computed(() => props.revision !== frozenRevision.value || currentState.value?.version !== frozenVersion.value)
const disabled = computed(() => busy.value || loading.value || !!pending.value)
function remember(value: typeof pending.value) { pending.value = value; unknown.value = false; if (props.guest) return; try { if (value) sessionStorage.setItem(storageKey, JSON.stringify(value)); else sessionStorage.removeItem(storageKey) } catch { /* Optional recovery cache. */ } }
function clearContent() { snapshot.value = null; other.value = null; metadata.value = null; runs.value = []; review.value = false; deleting.value = false }
function close() { dialog.value?.close(); controller?.abort(); generation++; clearTimeout(timer); loading.value = false; clearContent() }
function fail(cause: unknown) { error.value = cause instanceof Error ? cause.message : 'Could not read run history.'; if (cause instanceof APIError && [401, 403, 404].includes(cause.status)) close() }
function scheduleAccessCheck() { clearTimeout(timer); if (props.guest || disposed || !dialog.value?.open) return; timer = setTimeout(async () => { try { await api(`${base}/execution/history`); } catch (cause) { if (!disposed) fail(cause) } finally { scheduleAccessCheck() } }, 4000) }
async function checkPending() { if (!pending.value) return; const response = await api<{ command: { state: string } }>(`${base}/history-commands/${encodeURIComponent(pending.value.body.command_id)}`); if (response.command.state === 'accepted') { remember(null); note.value = 'History command accepted.'; emit('changed'); return true } unknown.value = true; return false }
async function load(older = false) {
  if (loading.value) return
  const stamp = ++generation; loading.value = true; error.value = ''
  controller?.abort(); controller = new AbortController()
  try {
    const page = await api<{ runs: RunSummary[]; before: string | null }>(`${base}/execution/history${older && before.value ? '?before=' + before.value : ''}`, 'GET', undefined, controller.signal)
    if (disposed || stamp !== generation) return
    runs.value = older ? [...page.runs, ...runs.value.filter(run => !page.runs.some(item => item.id === run.id))] : page.runs
    before.value = page.before; await checkPending()
  } catch (cause) { if (!disposed && stamp === generation) fail(cause) }
  finally { if (stamp === generation) loading.value = false; scheduleAccessCheck() }
}
async function inspect() {
  const stamp = ++generation; controller?.abort(); controller = new AbortController(); loading.value = true; error.value = ''; review.value = false; deleting.value = false; snapshot.value = null; other.value = null; metadata.value = null
  try {
    const value = await api<{ snapshot: RunSnapshot; metadata: RunMetadata }>(`${base}/execution/runs/${encodeURIComponent(selected.value)}/snapshot`, 'GET', undefined, controller.signal)
    const previous = compare.value && baseline.value ? await api<{ snapshot: RunSnapshot }>(`${base}/execution/runs/${encodeURIComponent(baseline.value)}/snapshot`, 'GET', undefined, controller.signal) : null
    if (disposed || stamp !== generation) return
    snapshot.value = value.snapshot; metadata.value = value.metadata; title.value = value.metadata.title; other.value = previous?.snapshot || null; scope.value = 'project'
  } catch (cause) { if (!disposed && stamp === generation) fail(cause) }
  finally { if (stamp === generation) loading.value = false }
}
async function act(action: () => Promise<void>) { if (busy.value) return; busy.value = true; error.value = ''; note.value = ''; try { await action() } catch (cause) { fail(cause) } finally { busy.value = false } }
async function send(command: NonNullable<typeof pending.value>) {
  try { await api(`${base}/execution/runs/${encodeURIComponent(command.run)}/history`, 'POST', command.body); remember(null) }
  catch (cause) { if (cause instanceof APIError && cause.status < 500) remember(null); else { try { if (await checkPending()) { await load(); if (command.body.operation !== 'delete') await inspect(); return } } catch { /* Keep exact uncertain command. */ } }; throw cause }
  if (disposed || !dialog.value?.open) return
  emit('changed'); note.value = command.body.operation === 'delete' ? 'Run deleted. Execution usage is retained.' : 'Run labels saved.'
  if (command.body.operation === 'delete') { selected.value = ''; snapshot.value = null; metadata.value = null; deleting.value = false }
  await load(); if (selected.value) await inspect()
}
function change(operation = 'update', pinned = metadata.value?.pinned || false) {
  if (disabled.value || !props.writable || !metadata.value) return
  const command = { run: selected.value, body: { command_id: newId('history'), base_version: metadata.value.version, operation, title: title.value.trim(), pinned } }
  remember(command); void act(() => send(command))
}
function reviewRestore() { if (!currentState.value || !props.canRestore || invalid.value) return; frozenVersion.value = currentState.value.version; frozenRevision.value = props.revision; review.value = true }
async function applyRestore() { if (!review.value || stale.value || invalid.value || !props.canRestore || !currentState.value) return; await act(async () => { if (await props.onRestore(scope.value === 'project' ? null : scope.value, restore.value, frozenVersion.value)) { review.value = false; note.value = 'Scalar parameters accepted. Authored sources and defaults are unchanged.' } else throw new Error('Parameters were not accepted. Your review is kept; check the parameter command status.') }) }
function currentValue(id: string) { const definitions = scope.value === 'project' ? props.document.inputs : props.document.sheets.flatMap(sheet => sheet.cells).find(cell => cell.id === scope.value)?.cell_ui?.inputs; return currentState.value?.values[id] ?? (definitions?.find(input => input.id === id) ? defaultJSON(definitions.find(input => input.id === id)!) : 'Unavailable') }
function exportSnapshot() { if (snapshot.value) download(new Blob([JSON.stringify(snapshot.value, null, 2)], { type: 'application/json' }), `run-${snapshot.value.run.id}.json`) }
function exportComparison() { download(new Blob([comparisonCSV(comparisons.value)], { type: 'text/csv;charset=utf-8' }), 'experiment-comparison.csv') }
function show(comparing = false) { compare.value = comparing; sheetFilter.value = props.sheetId; selected.value = ''; baseline.value = ''; clearContent(); error.value = ''; note.value = ''; dialog.value?.showModal(); void load() }
watch(() => props.writable, () => { review.value = false; deleting.value = false })
onUnmounted(() => { disposed = true; close() })
defineExpose({ show })
</script>
<template>
  <dialog ref="dialog" class="notebook-dialog runs-dialog" aria-labelledby="runs-title" @cancel.prevent="close" @close="close">
    <div class="dialog-heading"><div><h2 id="runs-title">Run snapshots and experiments</h2><p>Retained immutable results and accepted scalar parameters</p></div><button class="plain icon-button" aria-label="Close run snapshots" @click="close">×</button></div>
    <p v-if="error" class="source-error" role="alert">{{ error }}</p><p v-if="note" role="status">{{ note }}</p>
    <div v-if="pending" class="execution-message" role="status"><p>Checking the history command before any retry.</p><button :disabled="busy" @click="act(async () => { await checkPending(); await load() })">Check history command</button><button v-if="unknown && writable" :disabled="busy" @click="act(() => send(pending!))">Retry pending history command</button></div>
    <div class="run-selectors"><label>Sheet<select v-model="sheetFilter" :disabled="disabled"><option value="">All retained sheets</option><option v-for="sheet in document.sheets" :key="sheet.id" :value="sheet.id">{{ sheet.title }}</option></select></label><label><input v-model="compare" type="checkbox" :disabled="disabled" @change="selected && inspect()">Compare experiments</label>
      <label v-if="compare">Baseline<select v-model="baseline" aria-label="Baseline" :disabled="disabled" @change="selected && inspect()"><option value="">Choose baseline…</option><option v-for="run in [...visible].reverse()" :key="run.id" :value="run.id" :disabled="!terminal(run.state)">{{ run.metadata?.pinned ? '📌 ' : '' }}{{ run.metadata?.title || run.id.slice(0,8) }} · {{ runLabel(run.state) }}</option></select></label>
      <label>{{ compare ? 'Candidate' : 'Run' }}<select v-model="selected" aria-label="Snapshot run" :disabled="disabled" @change="selected && inspect()"><option value="">Choose a run…</option><option v-for="run in [...visible].reverse()" :key="run.id" :value="run.id" :disabled="!terminal(run.state)">{{ run.metadata?.pinned ? '📌 ' : '' }}{{ run.metadata?.title || run.id.slice(0,8) }} · {{ runLabel(run.state) }}</option></select></label>
    </div><div class="parameter-actions"><button :disabled="disabled" @click="load()">Refresh run list</button><button v-if="before" :disabled="disabled" @click="load(true)">Load older snapshots</button><button v-if="selected" :disabled="disabled" @click="inspect">Reload selected snapshot</button></div>
    <p class="source-note">Pinned runs (up to ten) and current presentations are protected from automatic retention. Pins consume the same server storage and run-count quotas.</p>
    <template v-if="snapshot && metadata">
      <p class="source-note">{{ runLabel(snapshot.run.state) }} · {{ snapshot.run.id }} · revision {{ snapshot.run.revision }} · started {{ snapshot.created_at ? new Date(Number(snapshot.created_at) * 1000).toISOString() : 'unavailable' }}</p>
      <div v-if="writable" class="run-labels"><label>Run title<input v-model="title" maxlength="256" :disabled="disabled" aria-label="Run title"></label><button :disabled="disabled" @click="change()">Rename run</button><button :disabled="disabled" @click="change('update', !metadata.pinned)">{{ metadata.pinned ? 'Unpin run' : 'Pin run' }}</button><button :disabled="disabled || metadata.pinned" @click="deleting = true">Delete run…</button></div>
      <div v-if="deleting" class="execution-message" role="status"><p>Delete this retained run and its snapshot? Current presentations and pinned runs are protected. Cumulative execution usage is retained.</p><button :disabled="disabled" @click="change('delete')">Confirm delete run</button><button @click="deleting = false">Keep run</button></div>
      <div v-if="compare && other" class="experiment-comparison"><p>{{ other.source_hash === snapshot.source_hash ? 'Same cell sources' : 'Cell sources changed' }} · {{ other.environment.source_fingerprint === snapshot.environment.source_fingerprint ? 'Same module/resource fingerprint' : 'Module/resource fingerprint changed' }}</p><div class="table-scroll"><table><thead><tr><th>Parameter / metric</th><th>Baseline</th><th>Candidate</th><th>Delta</th></tr></thead><tbody><tr v-for="row in comparisons" :key="row.name"><th>{{ row.name }}</th><td><code>{{ row.baseline ?? '—' }}</code></td><td><code>{{ row.candidate ?? '—' }}</code></td><td><code>{{ row.delta }}</code></td></tr></tbody></table></div><button @click="exportComparison">Export comparison CSV…</button></div>
      <section aria-label="Restore scalar parameters"><h3>Restore scalar parameters</h3><label>Parameter scope<select v-model="scope" aria-label="Parameter scope" :disabled="disabled || review"><option value="project">Project parameters</option><option v-for="item in snapshot.cell_inputs" :key="item.cell_id" :value="item.cell_id">Cell {{ item.sheet_id }}/{{ item.cell_id }}</option></select></label><p class="source-note">Apply changes one scope atomically. It may trigger Watch in initialized workers. File/media assets, sources and authored defaults are not restored.</p><p v-if="invalid" class="source-note">{{ invalid }}</p><p v-else-if="!currentState" class="source-note">Switch to this cell’s sheet to load its current accepted parameters before restoring.</p><button v-if="!review" :disabled="disabled || !canRestore || !!invalid || !currentState" @click="reviewRestore">Review scalar restore</button><template v-else><div class="table-scroll"><table><thead><tr><th>Parameter</th><th>Current JSON</th><th>Saved JSON</th></tr></thead><tbody><tr v-for="(value,id) in restore" :key="id"><th>{{ id }}</th><td><code>{{ currentValue(String(id)) }}</code></td><td><code>{{ value }}</code></td></tr></tbody></table></div><p v-if="stale" role="alert">Parameters or the notebook changed. Reset the review before applying.</p><button :disabled="disabled || stale || !canRestore || !!invalid" @click="applyRestore">Apply saved scalar parameters</button><button :disabled="busy" @click="review = false">Reset restore review</button></template></section>
      <details><summary>Inspect sources and environment</summary><p class="source-note">Source hash {{ snapshot.source_hash }}</p><p v-if="!snapshot.environment.available">Environment provenance was not recorded for this older run.</p><template v-else><p>Environment generation: {{ snapshot.environment.generation || 'resolved manifests / operator environment' }}</p><p class="source-note">Source fingerprint {{ snapshot.environment.source_fingerprint }}<br>Runtime fingerprint {{ snapshot.environment.runtime_fingerprint }}<br>Settings fingerprint {{ snapshot.environment.settings_fingerprint }}</p><ul><li v-for="item in snapshot.environment.packages" :key="item.name">{{ item.name }} {{ item.version }} · {{ item.variant }} · {{ item.digest }}</li></ul></template><p class="source-note">Module contents and input assets are in the retained notebook revision export. A snapshot is not a replayable worker heap or an installed environment archive.</p><ul><li v-for="item in snapshot.modules" :key="item.id">{{ item.id }} · {{ item.path }}</li></ul><article v-for="source in snapshot.sources" :key="source.sheet_id + ':' + source.cell_id"><h4>{{ source.sheet_title }} · {{ source.kind }} {{ source.cell_id }}</h4><pre>{{ source.source }}</pre></article></details>
      <details><summary>Inspect retained output</summary><p v-if="snapshot.result.error || snapshot.result.environment_error || snapshot.result.rich_error" role="alert">{{ snapshot.result.error || snapshot.result.environment_error || snapshot.result.rich_error }}</p><article v-for="cell in snapshot.result.cells" :key="cell.id"><h4>Cell {{ cell.id }}</h4><NotebookCellOutput :presentation="{ ...emptyPresentation(snapshot.run.id + ':' + cell.id), result: cell.result, error: cell.error, output: cell.output, ok: cell.ok, metrics: cell.metrics, rich: { ...emptyPresentation().rich, ...cell, audio_stale: true } }" /></article></details>
      <button @click="exportSnapshot">Export run snapshot…</button>
    </template><p v-else-if="loading" role="status">Loading retained runs…</p><p v-else-if="!runs.length" class="source-note">No retained runs.</p><footer class="dialog-actions"><button @click="close">Done</button></footer>
  </dialog>
</template>
