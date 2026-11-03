<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { api, apiBlob, APIError, type Project } from './api'
import { newCell, newId, parseNotebook, plainCell, type NotebookCell, type NotebookDocument, type NotebookResponse } from './notebook'
import NotebookIcon from './NotebookIcon.vue'
import NotebookFileEditor from './NotebookFileEditor.vue'
import NotebookHistory from './NotebookHistory.vue'
import NotebookRuns from './NotebookRuns.vue'
import NotebookDependencies from './NotebookDependencies.vue'
import NotebookEnvironments from './NotebookEnvironments.vue'
import { useSources, archiveName, type FileEdit } from './sources'
import { documentJSON } from './document-json'
import { download } from './rich'
import NotebookCellOutput from './NotebookCellOutput.vue'
import NotebookParameterForm from './NotebookParameterForm.vue'
import NotebookCellComponents from './NotebookCellComponents.vue'
import NotebookInputDesigner from './NotebookInputDesigner.vue'
import { useInputRuntime } from './input-runtime'
import { useMediaInputs } from './media-inputs'
import { runLabel, terminal, sheetRun, useExecution, type RunSummary } from './execution'
import NotebookBoardView from './NotebookBoardView.vue'
import NotebookTextEditor from './NotebookTextEditor.vue'
import type { TextContent } from './rich-text'
import NotebookInvocationResult from './NotebookInvocationResult.vue'
import NotebookServiceHistory from './NotebookServiceHistory.vue'
import { allBoardComponents } from './board-execution'
import type { BoardContext, NotebookBoard } from './boards'
import NotebookBoardDesigner from './NotebookBoardDesigner.vue'
import NotebookResourceLimits from './NotebookResourceLimits.vue'
import { secondsLabel } from './resource-policy'
import NotebookPreview from './NotebookPreview.vue'
import NotebookCodeEditor from './NotebookCodeEditor.vue'
import { duplicateSheet, moveSheet, deleteSheet } from './editor-operations'
import { localDrafts, writeDraft, removeDraft, type DraftRecord, type SaveCommand } from './draft-journal'
import NotebookSaveConflict from './NotebookSaveConflict.vue'

const props = defineProps<{ project: Project; accountId: string }>()
const emit = defineEmits<{ dirty: [value: boolean]; resumeImport: [command: string] }>()
const document = ref<NotebookDocument | null>(null)
const revision = ref('')
const saved = ref('')
const activeSheet = ref('')
const activeBoardID = ref('')
const activeBoard = computed(() => document.value?.boards?.find(board => board.id === activeBoardID.value))
const selectedCell = ref('')
const collapsedCells = ref(new Set<string>())
const cellKey = (cell: NotebookCell) => `${activeSheet.value}:${cell.id}`
const canCollapse = (cell: NotebookCell) => cell.kind === 'code' && !!cell.cell_ui?.post.length
watch(() => document.value?.sheets.map(sheet => sheet.cells.filter(canCollapse).map(cell => `${sheet.id}:${cell.id}`)).flat(), values => { const eligible = new Set(values || []); collapsedCells.value = new Set([...collapsedCells.value].filter(id => eligible.has(id))) })
const loaded = ref(false)
const loading = ref(false)
const saving = ref(false)
const error = ref('')
const conflict = ref(false)
let allowNavigation = false
const pending = ref<SaveCommand | null>(null)
const journalID = newId('draft'), recovery = ref<DraftRecord[]>([]), journalStatus = ref(''), journalError = ref('')
const recovering = ref(false)
let journalReady = false, journalTimer: ReturnType<typeof setTimeout> | undefined, journalQueue = Promise.resolve()
let recoveredFrom: DraftRecord | null = null
const conflictReview = ref<InstanceType<typeof NotebookSaveConflict>>()
const sheetDialog = ref<HTMLDialogElement>(), replacementSheet = ref(''), sheetError = ref('')
const relocateDialog = ref<HTMLDialogElement>(), relocatedPath = ref(''), relocatedModule = ref(''), relocateError = ref(''), relocating = ref(false)
const sources = reactive(useSources(() => props.project, document, revision))
const history = ref<InstanceType<typeof NotebookHistory>>()
const runSnapshots = ref<InstanceType<typeof NotebookRuns>>()
const dependencies = ref<InstanceType<typeof NotebookDependencies>>()
const environments = ref<InstanceType<typeof NotebookEnvironments>>()
const resourceLimits = ref<InstanceType<typeof NotebookResourceLimits>>()
const resourceDraftDirty = ref(false)
const preview = ref<InstanceType<typeof NotebookPreview>>()
const fileDialog = ref<HTMLDialogElement>()
const moduleName = ref(''), resourcePath = ref(''), fileError = ref('')
const resource = ref<File | null>(null)
const fileMode = ref<'module' | 'resource'>('module')
const transferBusy = ref(false)
const currentModule = computed(() => document.value?.modules?.find(module => module.path === sources.selected))
const endpoint = () => `/api/projects/${encodeURIComponent(props.project.id)}/notebook`
const dirty = computed(() => document.value !== null && (documentJSON(document.value) !== saved.value || sources.dirty))
const parameterMutating = ref(false), mediaMutating = ref(false)
const mediaDrafts = ref<Record<string, boolean>>({})
const busy = computed(() => loading.value || saving.value || relocating.value || recovering.value || mediaMutating.value)
const sheet = computed(() => document.value?.sheets.find(value => value.id === activeSheet.value))
const validTitles = computed(() => document.value?.sheets.every(value => value.title.trim().length > 0))
const execution = reactive(useExecution(props.accountId, () => props.project, document, revision, dirty, computed(() => busy.value || parameterMutating.value), activeSheet, activeBoardID))
const inputs = reactive(useInputRuntime(props.accountId, () => props.project, document, revision, activeSheet, computed(() => execution.registry?.input_version || ''), () => execution.refresh()))
const media = reactive(useMediaInputs(props.accountId, props.project.id, () => revision.value, () => inputState()?.version || '', async () => { accept(await api<NotebookResponse>(endpoint())); await inputs.refresh(); await execution.refresh(); await checkpoint() }))
const designer = ref<InstanceType<typeof NotebookInputDesigner>>()
const boardDesigner = ref<InstanceType<typeof NotebookBoardDesigner>>()
const boardDesignDirty = ref(false)
const inputEpoch = ref(0), parameterPage = ref(0)
const parameterFields = computed(() => (document.value?.inputs || []).slice(parameterPage.value * 128, (parameterPage.value + 1) * 128).map(input => ({ input: input.id })))
const navigationDirty = computed(() => dirty.value || !!pending.value || inputs.dirty || Object.values(mediaDrafts.value).some(Boolean) || boardDesignDirty.value || resourceDraftDirty.value)
watch(() => media.busy || !!media.pending, value => { mediaMutating.value = value }, { immediate: true, flush: 'sync' })
watch(() => inputs.busy || !!inputs.pending || media.busy || !!media.pending, value => { parameterMutating.value = value }, { immediate: true })
function inputState(cell = 'project') { const state = inputs.states[cell]; return state?.revision === revision.value ? state : undefined }
function canApply(cell: string | null) {
  if (!execution.canExecute || !execution.connected || execution.outdated || execution.requestBusy || execution.pending || inputs.busy || inputs.pending || media.busy || media.pending || busy.value || dirty.value || execution.registry?.dependency_busy) return false
  if (cell === null) return !execution.runs.some(run => !terminal(run.state)) && !execution.registry?.runtimes.some(runtime => runtime.needs_restart)
  return !execution.activeRun && !execution.runtime?.needs_restart
}
function discardParameterDrafts() {
  if ((inputs.dirty || Object.values(mediaDrafts.value).some(Boolean)) && !window.confirm('Discard unapplied parameter or media values before changing this view?')) return false
  inputs.resetDrafts(); mediaDrafts.value = {}; inputEpoch.value++; return true
}
function selectSheet(id: string) { if (!discardParameterDrafts()) return; activeBoardID.value = ''; sources.selected = ''; activeSheet.value = id }
function selectBoard(id: string) {
  const board = document.value?.boards?.find(item => item.id === id)
  if (!board || !discardParameterDrafts()) return
  sources.selected = ''; activeBoardID.value = id; activeSheet.value = board.sheet
}
function designBoard(board?: NotebookBoard, duplicate = false) {
  if (!document.value || busy.value || conflict.value || !props.project.permissions.write || !execution.canExecute || !discardParameterDrafts()) return
  boardDesigner.value?.show(board, duplicate, document.value.sheets.some(sheet => sheet.id === activeSheet.value) ? activeSheet.value : undefined)
}
function commitBoard(board: NotebookBoard, original: string | null) {
  if (!document.value || busy.value || conflict.value || !props.project.permissions.write || !execution.canExecute) return
  document.value.boards ||= []
  const index = document.value.boards.findIndex(item => item.id === original)
  if (original && index < 0) return
  if (index >= 0) document.value.boards[index] = board
  else document.value.boards.push(board)
  document.value.version = Math.max(2, document.value.version) as NotebookDocument['version']; document.value.inputs ||= []
  sources.selected = ''; activeBoardID.value = board.id; activeSheet.value = board.sheet; inputEpoch.value++
}
function removeBoard() {
  if (!document.value || !activeBoard.value || busy.value || conflict.value || !props.project.permissions.write || !execution.canExecute || !discardParameterDrafts()) return
  if (!window.confirm(`Delete board ${activeBoard.value.title} and its component configurations from your notebook draft? Save notebook to commit this change.`)) return
  document.value.boards = document.value.boards?.filter(board => board.id !== activeBoardID.value); activeBoardID.value = ''
}
function openFile(path: string) { if (discardParameterDrafts()) { activeBoardID.value = ''; void sources.open(path) } }
function showInputs(cell?: NotebookCell) { if (discardParameterDrafts()) designer.value?.show(cell) }
function inputDraftChanged() { parameterPage.value = 0 }
function parameterPageTo(page: number) { if (discardParameterDrafts()) parameterPage.value = page }
const firstCode = computed(() => sheet.value?.cells.find(cell => cell.kind === 'code'))
const boardContext = computed<BoardContext>(() => ({
  projectId: props.project.id, savedRevision: revision.value,
  observation: { result: execution.displayedResult, stale: dirty.value || execution.outdated || execution.runtime?.needs_restart === true || execution.displayedResult?.environment_stale === true || !!execution.registry?.reset_epochs.includes(execution.displayedRun?.runtime_epoch || '') || !!execution.displayedRun && (execution.displayedRun.revision !== revision.value || execution.displayedRun.id !== execution.runs.filter(run => sheetRun(run) && run.sheet_id === activeSheet.value).at(-1)?.id), connected: execution.connected, status: execution.status, needsRestart: execution.runtime?.needs_restart === true, state: execution.runtime?.state, epoch: execution.runtime?.runtime_epoch, resources: execution.registry?.resources },
  onOpenSource: (cell, module) => {
    if (!discardParameterDrafts()) return
    if (module) { const file = document.value?.modules?.find(item => item.id === module); if (file) { activeBoardID.value = ''; void sources.open(file.path); return } }
    activeBoardID.value = ''; sources.selected = ''
    if (cell && sheet.value?.cells.some(item => item.id === cell)) { selectedCell.value = cell; collapsedCells.value.delete(cellKey(sheet.value.cells.find(item => item.id === cell)!)); void nextTick(() => window.document.getElementById(`cell-source-${cell}`)?.focus()) }
  },
  textVariables: execution.textVariables(),
  components: (document.value?.boards || []).filter(board => board.sheet === activeSheet.value).flatMap(board => board.components),
  canConfigure: projectCanConfigure(), onConfigure: configurePresets,
  media: { projectId: props.project.id, revision: revision.value, readable: execution.connected, boardId: activeBoardID.value, values: inputState()?.values, version: inputState()?.version || '', canApply: media.ready && canApply(null) && !inputs.dirty && !boardDesignDirty.value && !resourceDraftDirty.value && Object.values(mediaDrafts.value).filter(Boolean).length <= 1, apply: media.apply, onDirty: (id, value) => { if(value)mediaDrafts.value[id]=true;else delete mediaDrafts.value[id] } },
  sheet: sheet.value, presentations: Object.fromEntries((sheet.value?.cells || []).filter(cell => cell.kind === 'code').map(cell => [cell.id, execution.cellPresentation(cell.id, cell.source)])),
  definitions: document.value?.inputs || [], state: inputState(), disabled: !sheet.value || !canApply(null) || inputState()?.can_apply !== true,
  canRun: !!sheet.value && execution.canRun, canExecute: execution.canExecute, identity: `${execution.displayedRun?.id || ''}:${activeSheet.value}`,
  onApply: (values, version) => inputs.apply(null, values, version), onDirty: (id, value) => inputs.dirtyForm(`board:${activeBoardID.value}:${id}`, value),
  onRun: id => { void execution.start(id, 'run') },
  onHistory: comparing => runSnapshots.value?.show(comparing),
  runtime: activeBoard.value ? { boardId: activeBoard.value.id, components: allBoardComponents(activeBoard.value), runs: execution.runs, services: execution.registry?.services || [], canStart: execution.canStart, canControl: execution.canControl, connected: execution.connected, sheetRun: execution.activeRun || [...execution.runs].reverse().find(run => sheetRun(run) && run.sheet_id === activeSheet.value), sheetNeedsRestart: execution.runtime?.needs_restart === true,
    invoke: component => { void execution.invoke(activeBoardID.value, component) }, configure: (component, operation) => { void execution.configureService(activeBoardID.value, component, operation) }, stop: (run, force) => { void execution.stop(run, force) }, restart: run => { void (run ? execution.restartInvocation(run) : execution.restart()) }, inspect: execution.inspectInvocation, history: component => execution.inspectService(activeBoardID.value, component), runSheet: () => { if (firstCode.value) void execution.start(firstCode.value.id, 'run_all') } } : undefined,
}))
function projectCanConfigure() { return props.project.permissions.write && !busy.value && !conflict.value && execution.canExecute }
function configurePresets(id: string, presets: unknown[]) {
  if (!document.value || !activeBoard.value || !projectCanConfigure()) return
  const component = allBoardComponents(activeBoard.value).find(c => c.id === id)
  if (component) (component.p1 ||= {}).presets = presets
}
function runDescription(run: RunSummary) {
  const sourceSheet = document.value?.sheets.find(value => value.id === run.sheet_id)
  const position = sourceSheet?.cells.findIndex(cell => cell.id === run.cell_id)
  const action = !sheetRun(run) ? `${run.action === 'periodic_run' ? 'Service' : 'Action'} · ${run.component_id || ''}` : run.action === 'run_all' ? 'Run All' : run.action === 'inputs' ? 'Apply parameters' : run.action === 'watch' ? 'Watch update' : `Cell ${position != null && position >= 0 ? position + 1 : run.cell_id}`
  return `${sourceSheet?.title || run.sheet_id} · ${action}`
}
async function viewRun(run: RunSummary) {
  if (!discardParameterDrafts()) return
  if (!sheetRun(run)) { execution.inspectInvocation(run); return }
  if (!document.value?.sheets.some(sheet => sheet.id === run.sheet_id)) return
  sources.selected = ''
  if (activeBoard.value?.sheet !== run.sheet_id) activeBoardID.value = ''
  activeSheet.value = run.sheet_id
  await nextTick()
  execution.selectedHistory = run.id
}
watch(navigationDirty, value => emit('dirty', value), { immediate: true })

function accept(result: NotebookResponse) {
  inputs.resetDrafts(); mediaDrafts.value = {}; inputEpoch.value++; parameterPage.value = 0
  sources.reset()
  if (!result.notebook) {
    document.value = null
    revision.value = ''
    saved.value = ''
    return
  }
  const parsed = parseNotebook(result.notebook)
  document.value = parsed
  revision.value = result.notebook.revision
  saved.value = documentJSON(parsed)
  const board = parsed.boards?.find(item => item.id === activeBoardID.value)
  if (!board) activeBoardID.value = ''
  activeSheet.value = board?.sheet || (parsed.sheets.some(value => value.id === parsed.active_sheet) ? parsed.active_sheet! : parsed.sheets[0]!.id)
  pending.value = null
}
function checkpoint() {
  if (journalTimer) { clearTimeout(journalTimer); journalTimer = undefined }
  if (!journalReady || !document.value || !props.project.permissions.write) return journalQueue
  const record: DraftRecord | null = dirty.value || pending.value ? {
    id: journalID, account: props.accountId, project: props.project.id, updated: Date.now(), base_revision: revision.value,
    base_document: saved.value, document: documentJSON(document.value), changes: JSON.parse(JSON.stringify(sources.changes)),
    pending: pending.value ? JSON.parse(JSON.stringify(pending.value)) : null,
    sheet: activeSheet.value, file: sources.selected, board: activeBoardID.value,
  } : null
  const transferred = recoveredFrom
  if (record) journalStatus.value = 'Keeping local draft…'
  journalQueue = journalQueue.then(async () => {
    await writeDraft(record, journalID)
    if (transferred) {
      await removeDraft(transferred); recovery.value = recovery.value.filter(item => item.id !== transferred.id)
      if (recoveredFrom === transferred) recoveredFrom = null
    }
    journalError.value = ''; journalStatus.value = record ? 'Local recovery copy saved' : ''
  }).catch(cause => { journalError.value = cause instanceof Error ? cause.message : 'Local recovery is unavailable. Export your draft before leaving.'; journalStatus.value = '' })
  return journalQueue
}
function queueCheckpoint() {
  if (!journalReady) return
  if (dirty.value || pending.value) journalStatus.value = 'Keeping local draft…'
  if (journalTimer) clearTimeout(journalTimer)
  journalTimer = setTimeout(() => { void checkpoint() }, 200)
}
watch([() => document.value && documentJSON(document.value), () => JSON.stringify(sources.changes), pending], queueCheckpoint, { deep: true })
async function readRecovery() {
  try { recovery.value = (await localDrafts(props.accountId, props.project.id)).filter(item => item.id !== journalID) }
  catch (cause) { journalError.value = cause instanceof Error ? cause.message : 'Local recovery is unavailable.' }
}
async function restoreDraft(record: DraftRecord) {
  if (busy.value || !props.project.permissions.write || !discardParameterDrafts() || (dirty.value && !window.confirm('Replace your current draft with this local recovery copy?'))) return
  recovering.value = true
  try {
    const [access, current, session] = await Promise.all([api<{ project: Project }>(`/api/projects/${encodeURIComponent(props.project.id)}`), api<NotebookResponse>(endpoint()), api<{ account: { id: string } | null }>('/api/session')])
    if (session.account?.id !== props.accountId) throw new Error('Sign in with the same account to restore this local draft. The copy is kept.')
    if (!access.project.permissions.write) throw new Error('Editing access is required to restore this draft. The local copy is kept.')
    if (!current.notebook) throw new Error('The saved notebook is unavailable. The local copy is kept.')
    document.value = parseNotebook({ revision: record.base_revision, document: record.document })
    saved.value = record.base_document; revision.value = record.base_revision; pending.value = record.pending
    activeSheet.value = document.value.sheets.some(item => item.id === record.sheet) ? record.sheet : document.value.sheets[0]!.id
    activeBoardID.value = document.value.boards?.some(item => item.id === record.board) ? record.board : ''
    sources.restore(record.changes, record.file); inputs.resetDrafts(); inputEpoch.value++
    conflict.value = current.notebook.revision !== record.base_revision && !pending.value
    error.value = conflict.value ? 'The saved notebook has changed since this local draft. Review saved changes before saving.' : pending.value ? 'A Save response was not confirmed. Retry the original save command to check its result.' : ''
    recoveredFrom = record; await checkpoint()
  } catch (cause) { journalError.value = cause instanceof Error ? cause.message : 'Could not restore this draft. The local copy is kept.' }
  finally { recovering.value = false }
}
async function discardRecovery(record: DraftRecord) {
  if (!window.confirm('Delete this local recovery copy? The saved notebook will stay as it is.')) return
  try { await removeDraft(record); await readRecovery() } catch (cause) { journalError.value = String(cause) }
}
function reviewConflict() {
  if (document.value && !busy.value && !pending.value && props.project.permissions.write) void conflictReview.value?.show(revision.value, saved.value, documentJSON(document.value), sources.changes)
}
function rebaseDraft(value: { head: { revision: string; document: string }; document: string; changes: Record<string, FileEdit | null> }) {
  document.value = parseNotebook({ revision: value.head.revision, document: value.document })
  saved.value = documentJSON(parseNotebook(value.head)); revision.value = value.head.revision
  if (!document.value.sheets.some(item => item.id === activeSheet.value)) activeSheet.value = document.value.sheets[0]!.id
  if (!document.value.boards?.some(item => item.id === activeBoardID.value)) activeBoardID.value = ''
  sources.restore(value.changes); pending.value = null; conflict.value = false; error.value = ''; inputs.resetDrafts(); inputEpoch.value++
  void checkpoint()
}
function failure(cause: unknown) {
  error.value = cause instanceof APIError && cause.code === 'notebook_conflict' ? 'The notebook has changed. Your draft is kept; review saved changes or reload the saved version.' : cause instanceof Error ? cause.message : 'The notebook request failed. Your draft is kept.'
  conflict.value = cause instanceof APIError && cause.status === 409
}
async function load() {
  if (busy.value || (navigationDirty.value && !window.confirm('Discard your unsaved changes and load the saved notebook?'))) return
  journalReady = false
  loading.value = true
  error.value = ''
  conflict.value = false
  try { accept(await api<NotebookResponse>(endpoint())); collapsedCells.value.clear(); loaded.value = true; journalReady = true; await checkpoint(); await readRecovery() }
  catch (cause) { failure(cause) }
  finally { loading.value = false; journalReady = true }
}
async function create() {
  if (busy.value) return
  loading.value = true
  error.value = ''
  try { accept(await api<NotebookResponse>(endpoint(), 'POST', {})); loaded.value = true; journalReady = true; await readRecovery() }
  catch (cause) { failure(cause) }
  finally { loading.value = false }
}
async function save() {
  if (!document.value || (!dirty.value && !pending.value) || busy.value || !props.project.permissions.write || (!validTitles.value && !pending.value) || conflict.value) return
  saving.value = true
  error.value = ''
  document.value.active_sheet = activeSheet.value
  const source = documentJSON(document.value)
  const edits = JSON.stringify(sources.changes)
  if (!pending.value) pending.value = { command_id: newId('save'), base_revision: revision.value, document: source, changes: JSON.parse(edits) }
  const command = pending.value
  await checkpoint()
  try {
    const result = await api<NotebookResponse>(endpoint(), 'PUT', command)
    if (!result.notebook) throw new Error('The service did not confirm the saved notebook. Retry saving.')
    parseNotebook(result.notebook)
    const remaining = Object.fromEntries(Object.entries(sources.changes).filter(([path, edit]) => JSON.stringify(edit) !== JSON.stringify(command.changes[path])))
    revision.value = result.notebook.revision
    saved.value = command.document
    sources.restore(remaining, sources.selected)
    pending.value = null
  } catch (cause) {
    if (cause instanceof APIError && [400, 403, 404, 409, 413, 422, 507].includes(cause.status)) pending.value = null
    failure(cause)
  }
  finally { saving.value = false; void checkpoint() }
}
function changeSheet(operation: 'copy' | 'up' | 'down') {
  if (!document.value || !sheet.value || busy.value || conflict.value || !props.project.permissions.write || !discardParameterDrafts()) return
  if (operation === 'copy') selectSheet(duplicateSheet(document.value, activeSheet.value))
  else moveSheet(document.value, activeSheet.value, operation === 'up' ? -1 : 1)
}
function showDeleteSheet() {
  if (!document.value || !sheet.value || !discardParameterDrafts()) return
  replacementSheet.value = document.value.sheets.find(item => item.id !== activeSheet.value)?.id || ''; sheetError.value = ''; sheetDialog.value?.showModal()
}
function removeSheet() {
  if (!document.value || busy.value || conflict.value || !props.project.permissions.write) return
  try { selectSheet(deleteSheet(document.value, activeSheet.value, replacementSheet.value)); sheetDialog.value?.close() }
  catch (cause) { sheetError.value = String(cause) }
}
function showRelocate() {
  if (busy.value || pending.value || conflict.value || !props.project.permissions.write) return
  relocatedPath.value = sources.selected; relocatedModule.value = currentModule.value?.id || ''; relocateError.value = ''; relocateDialog.value?.showModal()
}
async function relocate() {
  if (busy.value || conflict.value || !props.project.permissions.write) return
  relocating.value = true; relocateError.value = ''
  try { await sources.relocate(relocatedPath.value.trim(), currentModule.value ? relocatedModule.value.trim() : undefined); relocateDialog.value?.close() }
  catch (cause) { relocateError.value = cause instanceof Error ? cause.message : 'Could not move this file.' }
  finally { relocating.value = false }
}
function addSheet() {
  if (!document.value || !discardParameterDrafts()) return
  const used = new Set(document.value.sheets.flatMap(value => value.cells.map(cell => cell.id)))
  const added = { id: newId('sheet'), title: `Sheet ${document.value.sheets.length + 1}`, cells: [newCell('code', used)] }
  document.value.sheets.push(added)
  sources.selected = ''
  activeBoardID.value = ''
  activeSheet.value = added.id
}
function addCell(kind: 'code' | 'text') {
  if (!sheet.value) return
  const used = new Set(document.value!.sheets.flatMap(value => value.cells.map(cell => cell.id)))
  const cell = newCell(kind, used)
  sheet.value.cells.push(cell)
  selectedCell.value = cell.id
  void nextTick(() => window.document.getElementById(`cell-source-${cell.id}`)?.focus())
}
function moveCell(index: number, direction: -1 | 1) {
  if (!sheet.value) return
  const cells = sheet.value.cells
  const [cell] = cells.splice(index, 1)
  cells.splice(index + direction, 0, cell!)
}
function deleteCell(index: number) {
  if (sheet.value && window.confirm('Delete this cell and its source?')) sheet.value.cells.splice(index, 1)
}
function updateText(cell: NotebookCell, content: TextContent) {
  if (!props.project.permissions.write || busy.value || conflict.value) return
  cell.source = content.source
  if (content.formatting === undefined) delete cell.formatting
  else cell.formatting = content.formatting
}
function downloadDraft() {
  if (!document.value) return
  const payload = sources.dirty ? JSON.stringify({ base_revision: revision.value, document: documentJSON(document.value), changes: sources.changes }) : documentJSON(document.value)
  const url = URL.createObjectURL(new Blob([payload], { type: 'application/json' }))
  const link = window.document.createElement('a')
  link.href = url
  link.download = 'project-draft.json'
  link.click()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
async function transfer(draft = false) {
  if (!document.value || transferBusy.value) return
  transferBusy.value = true
  try {
    if (draft) download(await apiBlob(endpoint() + '/draft-archive', 'POST', { base_revision: revision.value, document: documentJSON(document.value), changes: sources.changes }), archiveName(props.project.title + '-draft'))
    else await sources.archive()
  } catch (cause) { failure(cause) }
  finally { transferBusy.value = false }
}
function showFile(mode: 'module' | 'resource') {
  if (!discardParameterDrafts()) return
  fileMode.value = mode; moduleName.value = ''; resourcePath.value = ''; resource.value = null; fileError.value = ''; fileDialog.value?.showModal()
}
async function addFile() {
  if (busy.value || pending.value || conflict.value || !props.project.permissions.write) return
  fileError.value = ''
  try {
    if (fileMode.value === 'module') sources.addModule(moduleName.value.trim())
    else { if (!resource.value) throw new Error('Choose a file.'); if (!await sources.upload(resource.value, resourcePath.value.trim())) return }
    fileDialog.value?.close()
  } catch (cause) { fileError.value = cause instanceof Error ? cause.message : 'Could not add this file.' }
}
async function downloadFile() { try { await sources.downloadFile() } catch (cause) { sources.error = cause instanceof Error ? cause.message : 'Could not download file.' } }
function beforeUnload(event: BeforeUnloadEvent) {
  void checkpoint()
  if (navigationDirty.value && !allowNavigation) { event.preventDefault(); event.returnValue = '' }
}
function shortcut(event: KeyboardEvent) {
  if (event.defaultPrevented) return
  if (boardDesigner.value?.isOpen()) return
  if (resourceLimits.value?.isOpen()) return
  if (preview.value?.isOpen()) return
  if (conflictReview.value?.isOpen() || sheetDialog.value?.open || relocateDialog.value?.open) return
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 's') { event.preventDefault(); void save() }
  if (event.key === 'Enter' && event.shiftKey && !event.ctrlKey && !event.metaKey && !event.altKey) {
    const cell = sheet.value?.cells.find(value => value.id === selectedCell.value && value.kind === 'code')
    if (cell && (event.target as HTMLElement)?.id === `cell-source-${cell.id}`) { event.preventDefault(); void execution.start(cell.id, 'run') }
  }
}
defineExpose({ allowNavigation: () => { allowNavigation = true } })
onMounted(() => {
  void load()
  window.addEventListener('beforeunload', beforeUnload)
  window.addEventListener('keydown', shortcut)
  window.addEventListener('pagehide', checkpoint)
})
onUnmounted(() => {
  window.removeEventListener('beforeunload', beforeUnload)
  window.removeEventListener('keydown', shortcut)
  window.removeEventListener('pagehide', checkpoint)
  void checkpoint()
})
</script>

<template>
  <section class="notebook-section" aria-label="Notebook" :aria-busy="busy" data-testid="notebook-workspace">
    <div v-if="error" class="notebook-error" role="alert">
      <p>{{ error }}</p>
      <div class="notebook-error-actions">
        <button v-if="conflict && document && project.permissions.write" :disabled="busy" @click="reviewConflict">Review saved changes…</button>
        <button v-if="!conflict && document" :disabled="busy || !dirty" @click="save">Retry save</button>
        <button :disabled="busy" @click="load">{{ document ? 'Reload saved version' : 'Retry loading' }}</button>
        <button v-if="dirty" :disabled="busy" @click="downloadDraft">Download draft JSON</button>
      </div>
    </div>
    <div v-if="recovery.length && document && project.permissions.write" class="draft-recovery" data-testid="draft-recovery">
      <details><summary>{{ recovery.length }} local recovery {{ recovery.length === 1 ? 'copy' : 'copies' }} available</summary>
        <p>These drafts are stored in this browser for your account and project for up to 30 days. Restoring keeps the original base revision and does not save or run anything.</p>
        <ul><li v-for="record in recovery" :key="record.id"><span>{{ new Date(record.updated).toLocaleString() }} · base {{ record.base_revision.slice(0, 8) }}<span v-if="record.pending"> · Save not confirmed</span></span><button :disabled="busy" @click="restoreDraft(record)">Restore local draft</button><button :disabled="busy" @click="discardRecovery(record)">Delete local copy</button></li></ul>
      </details>
    </div>
    <p v-if="journalError && document && project.permissions.write" class="source-error" role="status">{{ journalError }}</p>
    <div v-if="!document" class="notebook-empty panel">
      <div class="placeholder-icon"><NotebookIcon name="book" /></div>
      <h2>{{ loading ? 'Opening notebook…' : loaded ? 'Your notebook starts here.' : 'Notebook service' }}</h2>
      <p v-if="loaded && !loading">{{ project.permissions.write ? 'Create the first sheet and start writing Sputnik code.' : 'The owner has not created a notebook in this project yet.' }}</p>
      <p v-if="project.import_pending" class="source-note">An import is pending. Resume it with the original notebook file.</p>
      <button v-if="project.import_pending && project.import_command_id" @click="emit('resumeImport', project.import_command_id)">Resume import…</button>
      <button v-if="loaded && project.permissions.write && !project.import_pending" class="primary" :disabled="busy" @click="create"><NotebookIcon name="plus" />Create notebook</button>
    </div>
    <div v-else class="notebook-shell">
      <aside class="notebook-sidebar" aria-label="Notebook navigation">
        <div class="notebook-identity"><div class="heading-icon"><NotebookIcon name="book" /></div>
          <div><h2>{{ project.title }}</h2><p role="status" data-testid="notebook-save-status">{{ saving ? 'Saving…' : dirty ? 'Unsaved changes' : 'All changes saved' }}</p></div>
        </div>
        <div class="sidebar-section-title"><h3>Sheets</h3><button v-if="project.permissions.write" class="icon-button plain" aria-label="New sheet" title="New sheet" :disabled="busy || conflict" @click="addSheet"><NotebookIcon name="plus" /></button></div>
        <nav class="sheet-list" aria-label="Sheets">
          <button v-for="item in document.sheets" :key="item.id" class="plain sheet-link" :class="{ active: item.id === activeSheet && !sources.selected && !activeBoard }" :aria-current="item.id === activeSheet && !sources.selected && !activeBoard ? 'page' : undefined" @click="selectSheet(item.id)">
            <NotebookIcon name="sheet" /><span>{{ item.title || 'Untitled sheet' }}</span><span class="sheet-cell-count">{{ item.cells.length }}</span>
          </button>
        </nav>
        <div class="sidebar-section-title"><h3>Modules &amp; Files</h3><button v-if="project.permissions.write" class="plain icon-button" aria-label="New module" :disabled="busy || !!pending || conflict || !sources.ready" @click="showFile('module')"><NotebookIcon name="plus" /></button></div>
        <nav class="project-file-list" aria-label="Project files"><button v-for="file in sources.files" :key="file.path" class="plain sheet-link" :class="{ active: sources.selected === file.path }" :aria-current="sources.selected === file.path ? 'page' : undefined" :title="file.path" @click="openFile(file.path)"><NotebookIcon :name="file.kind === 'module' ? 'sheet' : 'folder'" /><span>{{ file.module_id || file.path }}</span><span v-if="sources.changes[file.path] !== undefined" aria-label="Unsaved file">•</span></button></nav>
        <p v-if="sources.indexBusy" class="source-note">Loading files…</p>
        <p v-else-if="sources.ready && !sources.files.length" class="source-note">No bundled files</p>
        <button v-if="project.permissions.write" class="plain text-button sidebar-add-resource" :disabled="busy || !!pending || conflict || !sources.ready" @click="showFile('resource')">Add resource…</button>
        <button class="plain sheet-link" :disabled="!project.permissions.write || busy || conflict" @click="showInputs()"><NotebookIcon name="sheet" /><span>Project Inputs…</span></button>
        <button class="plain sheet-link environments-link" @click="environments?.show()"><NotebookIcon name="folder" /><span>Environments…</span></button>
        <button class="plain sheet-link dependencies-link" @click="dependencies?.show()"><NotebookIcon name="folder" /><span>Dependencies…</span></button>
        <button class="plain sheet-link" @click="resourceLimits?.show()"><NotebookIcon name="book" /><span>Resource limits…</span></button>
        <button v-if="execution.canExecute" class="plain sheet-link" :disabled="busy || dirty || conflict" @click="preview?.show()"><NotebookIcon name="play" /><span>Temporary preview…</span></button>
        <template v-if="document.boards?.length || project.permissions.write"><div class="sidebar-section-title"><h3>Boards</h3><button v-if="project.permissions.write" class="icon-button plain" aria-label="New board" :disabled="busy || conflict || !execution.canExecute" @click="designBoard()"><NotebookIcon name="plus" /></button></div><nav class="sheet-list" aria-label="Boards"><button v-for="board in document.boards" :key="board.id" class="plain sheet-link" :class="{ active: board.id === activeBoardID && !sources.selected }" :aria-current="board.id === activeBoardID && !sources.selected ? 'page' : undefined" @click="selectBoard(board.id)"><NotebookIcon name="sheet" /><span>{{ board.title || 'Untitled board' }}</span></button></nav></template>
        <div class="notebook-sidebar-footer">{{ project.permissions.write ? 'Server notebook' : 'Read-only notebook' }}</div>
      </aside>
      <div class="notebook-detail">
        <div class="notebook-toolbar">
          <div class="sheet-title-field"><label class="sr-only" for="sheet-title">Sheet title</label>
            <input v-if="sheet && project.permissions.write && !sources.selected && !activeBoard" id="sheet-title" v-model="sheet.title" maxlength="200" title="Rename sheet · save notebook to keep the name" :disabled="busy || conflict" :aria-invalid="!sheet.title.trim()">
            <h2 v-else>{{ sources.selected ? currentModule?.id || sources.selected.split('/').at(-1) : activeBoard?.title || sheet?.title }}</h2>
            <p v-if="!validTitles">Every sheet needs a title.</p></div>
          <button v-if="project.permissions.write" class="primary" :disabled="busy || !dirty || !validTitles || conflict" @click="save"><NotebookIcon name="save" />Save notebook</button>
          <span v-else class="role-badge">Read only</span>
          <button class="icon-button plain" :disabled="busy" aria-label="Reload saved notebook" title="Reload saved notebook" @click="load"><NotebookIcon name="refresh" /></button>
        </div>
        <div class="notebook-transfer-toolbar"><button :disabled="transferBusy" @click="transfer()">Export saved…</button><button v-if="dirty" :disabled="transferBusy" @click="transfer(true)">Export draft…</button><button :disabled="busy" @click="history?.show()">Revisions…</button></div>
        <div v-if="sheet && !sources.selected && !activeBoard && project.permissions.write" class="sheet-operations" aria-label="Sheet operations">
          <button :disabled="busy || conflict" @click="changeSheet('copy')">Duplicate sheet</button>
          <button :disabled="busy || conflict || document.sheets[0]?.id === activeSheet" @click="changeSheet('up')">Move sheet up</button>
          <button :disabled="busy || conflict || document.sheets.at(-1)?.id === activeSheet" @click="changeSheet('down')">Move sheet down</button>
          <button :disabled="busy || conflict || document.sheets.length <= 1" @click="showDeleteSheet">Delete sheet…</button>
        </div>
        <p v-if="pending" class="execution-note" role="status" data-testid="pending-save">A Save response was not confirmed. Retrying checks the original command. Newer notebook edits are kept; resolve this Save before editing bundled files. <button :disabled="busy || conflict" @click="save">Retry original save</button></p>
        <div v-if="execution.registry?.resources" class="resource-summary" data-testid="resource-summary"><span>Execution: {{ secondsLabel(execution.registry.resources.spent_ms) }} used<span v-if="execution.registry.resources.remaining_ms !== null"> · {{ secondsLabel(execution.registry.resources.remaining_ms) }} remaining</span></span><span v-if="execution.registry.resources.effective.run_seconds">One run: {{ execution.registry.resources.effective.run_seconds }} s</span><button class="plain text-button" @click="resourceLimits?.show()">Limits &amp; storage…</button><p v-if="execution.registry.resources.remaining_ms === '0'" role="status">Execution budget exhausted. Stop and saved results remain available.</p></div>
        <details v-if="document.inputs?.length && !sources.selected && !activeBoard" :key="'project-inputs-' + inputEpoch" class="project-inputs-panel" open><summary>Project parameters <span>{{ document.inputs.length }}</span></summary><p class="source-note">Apply updates accepted values. Watch consumers in initialized sheets recompute; Manual results become stale. Saved defaults stay unchanged.</p><NotebookParameterForm :title="'Project Parameters' + (document.inputs.length > 128 ? ' · ' + (parameterPage + 1) : '')" :definitions="document.inputs" :fields="parameterFields" :state="inputState()" :disabled="!canApply(null) || inputState()?.can_apply !== true" :on-apply="(values, version) => inputs.apply(null, values, version)" @dirty="inputs.dirtyForm('project', $event)" /><div v-if="document.inputs.length > 128" class="parameter-paging"><button :disabled="parameterPage === 0" @click="parameterPageTo(parameterPage - 1)">Previous parameters</button><button :disabled="(parameterPage + 1) * 128 >= document.inputs.length" @click="parameterPageTo(parameterPage + 1)">Next parameters</button></div></details>
        <div v-if="media.error || media.pending" class="execution-message" role="status" data-testid="media-status"><p>{{ media.error || 'Checking the media command. Its exact bytes are kept for recovery.' }}</p><button :disabled="media.busy || media.checking" @click="media.check">Check media status</button><button v-if="media.pending && media.unknown && execution.canExecute" :disabled="media.busy || media.checking" @click="media.retry">Retry pending media command</button></div>
        <div v-if="inputs.error || inputs.pending" class="execution-message" role="status" data-testid="input-status"><p>{{ inputs.error || 'Checking the parameter command. Accepted values are recovered without repeating the update.' }}</p><button :disabled="inputs.busy" @click="inputs.refresh">Check parameter status</button><button v-if="inputs.pending && inputs.unknown && execution.canExecute" :disabled="inputs.busy || execution.requestBusy || !!execution.pending" @click="inputs.retry">Retry pending input command</button></div>
        <div v-if="dirty && (document.inputs?.length || sheet?.cells.some(cell => cell.cell_ui?.inputs.length))" class="source-note parameter-save-note">Save notebook changes before applying parameter values.</div>
        <div v-if="sources.error" class="source-error" role="alert">{{ sources.error }} <button class="text-button" @click="sources.selected ? sources.open(sources.selected) : sources.index()">Retry files</button></div>
        <NotebookFileEditor v-if="sources.selected" :file="sources.view" :path="sources.selected" :module-id="currentModule?.id" :auto-import="!!document.auto_imports?.includes(currentModule?.id || '')" :loading="sources.fileBusy" :writable="project.permissions.write" :disabled="busy || !!pending || conflict" :changed="sources.changes[sources.selected] !== undefined" @text="sources.text" @auto-import="sources.autoImport" @download="downloadFile" @remove="sources.remove" @relocate="showRelocate" />
        <div v-if="!sources.selected" class="execution-toolbar">
          <span class="execution-status" role="status" data-testid="execution-status"><span class="runtime-dot" :class="{ 'is-running': execution.activeRun, 'is-offline': !execution.connected }"></span>{{ execution.status }}</span>
          <div v-if="execution.canExecute" class="execution-actions">
            <button :disabled="!execution.canRun || !firstCode" title="Run all code cells in the saved sheet" @click="firstCode && execution.start(firstCode.id, 'run_all')"><NotebookIcon name="play" />{{ activeBoard ? 'Run Sheet' : 'Run All' }}</button>
            <button :disabled="!execution.activeRun || execution.requestBusy || !!execution.pending" @click="execution.activeRun && execution.stop(execution.activeRun)"><NotebookIcon name="stop" />Stop</button>
            <button v-if="execution.activeRun" class="plain" :disabled="execution.requestBusy || !!execution.pending" @click="execution.stop(execution.activeRun, true)">Force Stop…</button>
            <button v-else-if="execution.runtime" :disabled="execution.requestBusy || !!execution.pending || !execution.connected" @click="execution.restart">Restart Worker…</button>
          </div>
        </div>
        <div v-if="execution.error || execution.connectionError || execution.pending" class="execution-message" :class="{ 'execution-warning': execution.pending }" :role="execution.error || execution.connectionError ? 'alert' : 'status'" data-testid="execution-message">
          <p v-if="execution.error || execution.connectionError">{{ execution.error || execution.connectionError }}</p>
          <p v-if="execution.pending">The command outcome is being checked. An accepted run will be reattached; a retry keeps the same command ID.</p>
          <div class="execution-message-actions"><button :disabled="execution.requestBusy" @click="execution.refresh">Check execution status</button>
            <button v-if="execution.pending && execution.pendingState === 'not_recorded' && execution.canExecute" :disabled="execution.requestBusy" @click="execution.retry">Retry pending command</button></div>
        </div>
        <div v-if="execution.outdated" class="execution-note">The server has a newer saved notebook. <button class="text-button" :disabled="busy" @click="load">Reload notebook</button> before running.</div>
        <div v-if="execution.displayedResult?.rich_error" class="execution-note" role="alert">{{ execution.displayedResult.rich_error }}</div>
        <div v-if="execution.displayedResult?.text_limited" class="execution-note" role="status">Published text exceeds the preview limits. Values are unavailable; reduce the number or size of requested variables.</div>
        <div v-if="execution.displayedResult?.error || execution.displayedResult?.environment_error || execution.displayedResult?.task_errors.length" class="execution-failure" role="alert">
          <p>{{ execution.displayedResult?.error || execution.displayedResult?.environment_error }}</p>
          <button v-if="execution.displayedResult?.environment_error" class="plain" @click="dependencies?.show()">Open Dependencies…</button>
          <pre v-for="(message, index) in execution.displayedResult?.task_errors" :key="index">{{ message }}</pre>
        </div>
        <div v-if="execution.selectedHistory" class="execution-note">Viewing run {{ execution.selectedHistory.slice(0, 8) }}. <button class="text-button" @click="execution.selectedHistory = ''">Show latest results</button></div>
        <NotebookBoardView v-if="activeBoard && !sources.selected" :key="activeBoard.id + ':' + inputEpoch" :board="activeBoard" :context="boardContext" :can-design="project.permissions.write" :design-disabled="busy || conflict || !execution.canExecute" @open-sheet="selectSheet(activeBoard.sheet)" @design="designBoard(activeBoard)" @duplicate="designBoard(activeBoard, true)" @remove="removeBoard" />
        <div v-if="sheet && !sources.selected && !activeBoard" class="notebook-cells">
          <article v-for="(cell, index) in sheet.cells" :key="cell.id" class="notebook-cell" :class="{ selected: cell.id === selectedCell, 'text-cell': cell.kind === 'text' }" data-testid="notebook-cell" @focusin="selectedCell = cell.id">
            <div class="cell-toolbar"><span class="cell-number">{{ index + 1 }}</span><span class="cell-kind">{{ cell.kind === 'code' ? 'Code' : cell.kind === 'text' ? 'Text' : cell.kind }}</span>
              <select v-if="cell.kind === 'code' && project.permissions.write" :value="cell.mode || 'manual'" @change="cell.mode = ($event.target as HTMLSelectElement).value" class="cell-mode-select" :aria-label="`Execution mode for cell ${index + 1}`" :disabled="busy || conflict"><option value="manual">Manual</option><option value="watch">Watch</option></select><span v-else-if="cell.kind === 'code'" class="cell-mode">{{ cell.mode === 'watch' ? 'Watch' : 'Manual' }}</span>
              <div v-if="project.permissions.write || execution.canExecute" class="cell-actions">
                <button v-if="cell.kind === 'code' && execution.canExecute" class="icon-button plain cell-run-button" :aria-label="`Run cell ${index + 1}`" title="Run saved cell · Shift+Enter" :disabled="!execution.canRun" @click="execution.start(cell.id, 'run')"><NotebookIcon name="play" /></button>
                <template v-if="project.permissions.write">
                <button v-if="cell.kind === 'code'" class="plain cell-components-button" :disabled="busy || conflict" :aria-label="`Components for cell ${index + 1}`" @click="showInputs(cell)">Components…</button>
                <button class="icon-button plain" :aria-label="`Move cell ${index + 1} up`" :disabled="busy || conflict || index === 0" @click="moveCell(index, -1)"><NotebookIcon name="up" /></button>
                <button class="icon-button plain" :aria-label="`Move cell ${index + 1} down`" :disabled="busy || conflict || index === sheet.cells.length - 1" @click="moveCell(index, 1)"><NotebookIcon name="down" /></button>
                <button class="icon-button plain" :aria-label="`Delete cell ${index + 1}`" :disabled="busy || conflict" @click="deleteCell(index)"><NotebookIcon name="trash" /></button>
                </template>
              </div>
            </div>
            <button v-if="canCollapse(cell)" class="plain source-collapse-toggle" :aria-label="`${collapsedCells.has(cellKey(cell)) ? 'Expand' : 'Collapse'} source for cell ${index + 1}`" :aria-expanded="!collapsedCells.has(cellKey(cell))" @click="collapsedCells.has(cellKey(cell)) ? collapsedCells.delete(cellKey(cell)) : collapsedCells.add(cellKey(cell))">{{ collapsedCells.has(cellKey(cell)) ? '▸ Show code' : '▾ Hide code' }}</button>
            <NotebookCellComponents v-if="cell.cell_ui" :key="cell.id + '-pre-' + inputEpoch" :cell-id="cell.id" :components="cell.cell_ui.pre" :definitions="cell.cell_ui.inputs" :state="inputState(cell.id)" :presentation="execution.cellPresentation(cell.id, cell.source)" :disabled="!canApply(cell.id) || inputState(cell.id)?.can_apply !== true" :on-apply="(values, version) => inputs.apply(cell.id, values, version)" @dirty="inputs.dirtyForm" />
            <label class="sr-only" :for="`cell-source-${cell.id}`">{{ cell.kind === 'text' ? 'Text' : 'Code' }} cell {{ index + 1 }}</label>
            <p v-if="canCollapse(cell) && collapsedCells.has(cellKey(cell))" class="source-collapsed" data-testid="source-collapsed">{{ cell.source.split('\n').length }} lines · {{ cell.source.split('\n').find(line => line.trim()) || 'Empty code cell' }}</p>
            <NotebookTextEditor v-if="cell.kind === 'text'" :content="{ source: cell.source, formatting: cell.formatting }" :label="`Text cell ${index + 1}`" :source-id="`cell-source-${cell.id}`" :readonly="!project.permissions.write || conflict" :disabled="busy" :variables="execution.textVariables(cell.id)" @change="updateText(cell, $event)" />
            <NotebookCodeEditor v-else v-show="!canCollapse(cell) || !collapsedCells.has(cellKey(cell))" :source-id="`cell-source-${cell.id}`" v-model="cell.source" :label="`Code cell ${index + 1}`" :readonly="!project.permissions.write || !plainCell(cell) || conflict" :disabled="busy" :sputnik="cell.kind === 'code'" :diagnostics="execution.cellPresentation(cell.id, cell.source).diagnostics" :diagnostics-truncated="execution.cellPresentation(cell.id, cell.source).diagnostics_truncated" :stale="execution.cellPresentation(cell.id, cell.source).stale" placeholder="Write Sputnik code…" />
            <p v-if="!['code', 'text'].includes(cell.kind)" class="cell-preserved">This content is preserved and read-only in this editor.</p>
            <NotebookCellOutput v-if="cell.kind === 'code'" :presentation="execution.cellPresentation(cell.id, cell.source)" :components="[...(cell.cell_ui?.pre || []), ...(cell.cell_ui?.post || [])]" />
            <NotebookCellComponents v-if="cell.cell_ui" :key="cell.id + '-post-' + inputEpoch" :cell-id="cell.id" :components="cell.cell_ui.post" :definitions="cell.cell_ui.inputs" :state="inputState(cell.id)" :presentation="execution.cellPresentation(cell.id, cell.source)" :disabled="!canApply(cell.id) || inputState(cell.id)?.can_apply !== true" :on-apply="(values, version) => inputs.apply(cell.id, values, version)" @dirty="inputs.dirtyForm" />
          </article>
          <p v-if="!sheet.cells.length" class="sheet-empty">This sheet is empty. Add a code or text cell below.</p>
          <div v-if="project.permissions.write" class="add-cell-actions">
            <button :disabled="busy || conflict" @click="addCell('code')"><NotebookIcon name="plus" />Code cell</button>
            <button :disabled="busy || conflict" @click="addCell('text')"><NotebookIcon name="plus" />Text cell</button>
          </div>
        </div>
        <NotebookInvocationResult v-if="execution.invocationRun" :run="execution.invocationRun" :result="execution.invocationResult" :stale="dirty || execution.outdated || execution.invocationRun.revision !== revision || execution.registry?.input_version !== execution.invocationRun.input_version || !!execution.registry?.reset_epochs.includes(execution.invocationRun.runtime_epoch)" @close="execution.selectedInvocation = ''" />
        <NotebookServiceHistory v-if="execution.selectedService" :value="execution.serviceHistory" :error="execution.serviceError" @close="execution.selectedService = null; execution.serviceHistory = null" @older="execution.inspectService(execution.selectedService!.board, execution.selectedService!.component, $event)" @newest="execution.inspectService(execution.selectedService!.board, execution.selectedService!.component)" />
        <details v-if="execution.runs.length || execution.historyRows.length" class="run-history" @toggle="($event.target as HTMLDetailsElement).open && !execution.historyLoaded && execution.loadHistory()">
          <summary>Run history <span>{{ execution.historyRows.length }}</span></summary>
          <p v-if="execution.historyError" role="alert">{{ execution.historyError }}</p>
          <button @click="runSnapshots?.show()">Snapshots and experiments…</button>
          <button :disabled="execution.historyBusy" @click="execution.loadHistory()">Refresh history</button>
          <ul><li v-for="run in [...execution.historyRows].reverse()" :key="run.id">
            <button class="plain run-history-item" :aria-label="`View run ${run.id}`" :disabled="sheetRun(run) && !document.sheets.some(sheet => sheet.id === run.sheet_id)" @click="viewRun(run)">
              <span>{{ runDescription(run) }}</span><span class="run-state" :class="{ 'run-failed': ['failed', 'interrupted', 'force-stopped'].includes(run.state) }">{{ runLabel(run.state) }}</span><code :title="`Parameters ${run.input_version || 'default'}`">{{ run.id.slice(0, 8) }}</code>
            </button>
            <button v-if="execution.canExecute && !terminal(run.state)" class="plain history-stop" :aria-label="`Stop run ${run.id}`" :disabled="execution.requestBusy || !!execution.pending" @click="execution.stop(run)">Stop</button>
          </li></ul>
          <button v-if="execution.historyBefore" :disabled="execution.historyBusy" @click="execution.loadHistory(true)">Older runs</button>
        </details>
        <div class="notebook-statusbar"><span>{{ sheet?.cells.length || 0 }} cells<span class="dot">·</span>{{ project.permissions.write ? 'Changes are saved explicitly' : 'Read-only access' }}<span v-if="journalStatus" data-testid="draft-journal-status"> · {{ journalStatus }}</span></span><span v-if="execution.displayedRun">{{ runLabel(execution.displayedRun.state) }} · revision {{ execution.displayedRun.revision.slice(0, 8) }}</span><span v-else>Server runtime</span></div>
      </div>
    </div>
    <NotebookInputDesigner v-if="document" ref="designer" :document="document" :disabled="busy || conflict || !project.permissions.write" @changed="inputDraftChanged" />
    <NotebookBoardDesigner v-if="document" ref="boardDesigner" :document="document" :disabled="busy || conflict || !project.permissions.write || !execution.canExecute" @commit="commitBoard" @dirty="boardDesignDirty = $event" />
    <NotebookRuns v-if="document" ref="runSnapshots" :project-id="project.id" :account-id="accountId" :document="document" :revision="revision" :sheet-id="activeSheet" :writable="project.permissions.write && execution.canExecute" :can-restore="canApply(null) && !inputs.busy && !inputs.pending && !inputs.dirty" :states="inputs.states" :on-restore="(cell,values,version) => inputs.apply(cell,values,version)" @changed="execution.loadHistory(); execution.refresh()" />
    <NotebookHistory ref="history" :project-id="project.id" :title="project.title" />
    <NotebookEnvironments v-if="document" ref="environments" :project-id="project.id" :account-id="accountId" :revision="revision" :sheets="document.sheets" :sheet-id="activeSheet" :writable="project.permissions.manage && execution.canExecute" :disabled="busy || dirty || !!execution.pending" @changed="execution.refresh" />
    <NotebookDependencies ref="dependencies" :project-id="project.id" :account-id="accountId" @changed="execution.refresh" @permissions="environments?.show(true, $event)" />
    <NotebookResourceLimits v-if="document" ref="resourceLimits" :project-id="project.id" :policy="document.resource_policy" :writable="project.permissions.write && execution.canExecute" :disabled="busy || conflict" @change="document.resource_policy = $event" @dirty="resourceDraftDirty = $event" />
    <NotebookPreview v-if="document" ref="preview" :project-id="project.id" :enabled="execution.canExecute && !busy && !dirty && !conflict" />
    <NotebookSaveConflict ref="conflictReview" :project-id="project.id" @rebase="rebaseDraft" />
    <dialog ref="sheetDialog" class="notebook-dialog" aria-labelledby="delete-sheet-title"><form @submit.prevent="removeSheet">
      <div class="dialog-heading"><h2 id="delete-sheet-title">Delete sheet {{ sheet?.title }}</h2><button type="button" class="plain icon-button" aria-label="Close delete sheet" @click="sheetDialog?.close()">×</button></div>
      <p>The sheet and its cells will be removed from your draft. Save notebook commits the deletion. Existing run history stays available.</p>
      <label for="replacement-sheet">Replacement controller sheet</label><select id="replacement-sheet" v-model="replacementSheet"><option v-for="item in document?.sheets.filter(item => item.id !== activeSheet)" :key="item.id" :value="item.id">{{ item.title }}</option></select>
      <p>{{ document?.boards?.filter(board => board.sheet === activeSheet).length || 0 }} linked boards will use this controller. Their component bindings are preserved; review them before running.</p>
      <p v-if="sheetError" class="source-error" role="alert">{{ sheetError }}</p><div class="dialog-actions"><button type="button" @click="sheetDialog?.close()">Cancel</button><button class="primary" :disabled="busy || !replacementSheet">Delete from draft</button></div>
    </form></dialog>
    <dialog ref="relocateDialog" class="notebook-dialog" aria-labelledby="relocate-title" @cancel="relocating && $event.preventDefault()"><form @submit.prevent="relocate">
      <div class="dialog-heading"><h2 id="relocate-title">Rename or move {{ currentModule ? 'module' : 'file' }}</h2><button type="button" class="plain icon-button" aria-label="Close rename or move" :disabled="relocating" @click="relocateDialog?.close()">×</button></div>
      <template v-if="currentModule"><label for="relocated-module">New module name</label><input id="relocated-module" v-model="relocatedModule" maxlength="64" required :disabled="relocating"></template>
      <label for="relocated-path">Destination path</label><input id="relocated-path" v-model="relocatedPath" required :disabled="relocating">
      <p>File contents move with the path. {{ currentModule ? 'Module metadata, its package declaration, auto-imports and board actions follow the new name.' : '' }} References inside other source code and resource paths must be updated manually. Save notebook commits all changes together.</p>
      <p v-if="relocateError" class="source-error" role="alert">{{ relocateError }}</p><div class="dialog-actions"><button type="button" :disabled="relocating" @click="relocateDialog?.close()">Cancel</button><button class="primary" :disabled="relocating">{{ relocating ? 'Reading file…' : 'Update notebook draft' }}</button></div>
    </form></dialog>
    <dialog ref="fileDialog" class="notebook-dialog" aria-labelledby="file-dialog-title"><form @submit.prevent="addFile">
      <div class="dialog-heading"><h2 id="file-dialog-title">{{ fileMode === 'module' ? 'New module' : 'Add resource' }}</h2><button type="button" class="plain icon-button" aria-label="Close file dialog" @click="fileDialog?.close()">×</button></div>
      <template v-if="fileMode === 'module'"><label for="module-name">Module name</label><input id="module-name" v-model="moduleName" required maxlength="64" placeholder="helpers"><p class="source-note">Source will be saved in modules/{{ moduleName || 'helpers' }}.s</p></template>
      <template v-else><label for="resource-file">Resource file</label><input id="resource-file" type="file" required @change="resource = ($event.target as HTMLInputElement).files?.[0] || null; resourcePath = resource ? 'resources/' + resource.name : ''"><label for="resource-path">Project path</label><input id="resource-path" v-model="resourcePath" required placeholder="resources/data.csv"><p class="source-note">Up to 16 MiB per file. Text up to 1 MiB can be edited here.</p></template>
      <p v-if="fileError" class="source-error" role="alert">{{ fileError }}</p><div class="dialog-actions"><button type="button" @click="fileDialog?.close()">Cancel</button><button class="primary">Add to draft</button></div>
    </form></dialog>
  </section>
</template>
