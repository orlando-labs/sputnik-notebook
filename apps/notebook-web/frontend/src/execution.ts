import { computed, onMounted, onUnmounted, ref, watch, type Ref } from 'vue'
import { api, APIError, type Project } from './api'
import { newId, type NotebookDocument } from './notebook'
import type { RichCell } from './rich'
import type { ServiceSummary, ServiceHistory, ServiceOperation } from './board-execution'
import type { ResourceStatus } from './resource-policy'
import { textResolver, type PublishedText } from './text-variables'
import type { CodeDiagnostic } from './diagnostics'
import type { TableSnapshot } from './rich'

export interface ResultFormat { pretty: string; is_container: boolean; truncated: boolean; pretty_truncated: boolean }
export interface RuntimeTask { id: string; parent: string; cell: string | null; line: string | null; elapsed_ms: string; state: string; error: string }
export interface TaskTelemetry { revision: string; active: string; total: string; dropped: string; sampled_ms: string; cpu_percent: number | null; resident_bytes: string | null; tasks: RuntimeTask[] }

export const terminal = (state: string) => ['succeeded', 'failed', 'cancelled', 'force-stopped', 'interrupted'].includes(state)
const labels: Record<string, string> = { preparing: 'Preparing', running: 'Running', draining: 'Finishing', stopping: 'Stopping', terminating: 'Terminating', succeeded: 'Succeeded', failed: 'Failed', cancelled: 'Cancelled', 'force-stopped': 'Force stopped', interrupted: 'Interrupted' }
export const runLabel = (state: string) => labels[state] || state
const latest = <T>(values: T[], predicate: (value: T) => boolean) => [...values].reverse().find(predicate)
export interface RunSummary {
  metadata?: import('./run-history').RunMetadata
  id: string; revision: string; sheet_id: string; cell_id: string; action: string; board_id?: string; component_id?: string
  input_version: string | null; runtime_epoch: string; state: string; executing_cell: string
}
export const sheetRun = (run: RunSummary) => ['run', 'run_all', 'inputs', 'watch'].includes(run.action)
export interface CellResult extends RichCell {
  result_format?: ResultFormat | null
  id: string; source: string | null; ok: boolean; dirty: boolean; result: string; error: string
  output: { stream: string; text: string }[]
  metrics: { name: string; value: string | null }[]
  text_values?: PublishedText[]; diagnostics?: CodeDiagnostic[]; diagnostics_truncated?: boolean
}
export interface CellPresentation {
  result_format?: ResultFormat | null; result_table?: TableSnapshot | null; revision?: string
  result: string; error: string; output: CellResult['output']; ok: boolean; metrics: CellResult['metrics']
  stale: boolean; running: boolean; active: boolean; rich: RichCell; identity: string
  text_values?: PublishedText[]; diagnostics?: CodeDiagnostic[]; diagnostics_truncated?: boolean; diagnostics_stale?: boolean
}
export interface RunResult extends RunSummary {
  task_telemetry?: TaskTelemetry | null
  error: string; environment_error: string; rich_error: string; task_errors: string[]; cells: CellResult[]; live_cells: CellResult[]
  text_limited?: boolean
  environment_stale?: boolean
}
interface Runtime { sheet_id: string; input_version: string | null; runtime_epoch: string; state: string; needs_restart: boolean; iteration_ready?: string[]; iteration_running?: boolean }
interface Registry { resources?: ResourceStatus; services: ServiceSummary[]; input_version: string; dependency_busy: boolean; revision: string; runs: RunSummary[]; runtimes: Runtime[]; reset_epochs: string[]; can_execute: boolean }
type Command = { kind: 'run' | 'stop' | 'restart' | 'invoke' | 'service' | 'restart_invocation'; run_id?: string; body: Record<string, unknown> & { command_id: string } }

function readCommand(key: string): Command | null {
  try {
    const value = JSON.parse(sessionStorage.getItem(key) || 'null')
    if (!value || !['run', 'stop', 'restart', 'invoke', 'service', 'restart_invocation'].includes(value.kind) || typeof value.body?.command_id !== 'string') return null
    if (value.kind === 'run' && !['revision', 'sheet_id', 'cell_id', 'action'].every(field => typeof value.body[field] === 'string')) return null
    if (value.kind === 'stop' && (typeof value.run_id !== 'string' || typeof value.body.runtime_epoch !== 'string' || typeof value.body.force !== 'boolean')) return null
    if (value.kind === 'restart' && (typeof value.body.sheet_id !== 'string' || (value.body.runtime_epoch !== null && typeof value.body.runtime_epoch !== 'string'))) return null
    if (['invoke', 'service'].includes(value.kind) && !['revision', 'board_id', 'component_id'].every(field => typeof value.body[field] === 'string')) return null
    if (value.kind === 'service' && !['start', 'pause', 'once', 'clear'].includes(value.body.operation)) return null
    if (value.kind === 'restart_invocation' && (typeof value.run_id !== 'string' || typeof value.body.runtime_epoch !== 'string')) return null
    return value
  } catch { return null }
}

type GuestLease = { leasePath: string; leaseSeconds: number; expired: (message: string) => void }

export function useExecution(accountId: string, project: () => Project, document: Ref<NotebookDocument | null>, revision: Ref<string>, dirty: Readonly<Ref<boolean>>, editorBusy: Readonly<Ref<boolean>>, activeSheet: Ref<string>, activeBoard: Ref<string>, guest?: GuestLease) {
  const base = `/api/projects/${encodeURIComponent(project().id)}/execution`
  const storageKey = `sputnik.execution.pending.v1:${accountId}:${project().id}`
  const registry = ref<Registry | null>(null)
  const details = ref<Record<string, RunResult>>({})
  const detailOrder: string[] = [] // Media snapshots are bounded; retain at most three runs.
  const selectedHistory = ref('')
  const historyRuns = ref<RunSummary[]>([]), historyBefore = ref<string | null>(null), historyLoaded = ref(false), historyBusy = ref(false), historyError = ref('')
  const selectedInvocation = ref('')
  const selectedService = ref<{ board: string; component: string; before: string | null } | null>(null)
  const serviceHistory = ref<ServiceHistory | null>(null), serviceError = ref('')
  let generation = 0, historyRequest = 0
  const pending = ref<Command | null>(guest ? null : readCommand(storageKey))
  const pendingState = ref<'unknown' | 'not_recorded'>('unknown')
  const requestBusy = ref(false)
  const connected = ref(false)
  const error = ref('')
  const connectionError = ref('')
  const accessLost = ref(false)
  let disposed = false
  let timer: ReturnType<typeof setTimeout> | undefined
  let refreshing: Promise<void> | null = null
  let heartbeatRuns: string | undefined
  const readController = new AbortController()
  const runs = computed(() => registry.value?.runs || [])
  const historyRows = computed(() => {
    const current = new Map(runs.value.map(run => [run.id, run]))
    return [...historyRuns.value.map(run => current.get(run.id) || run), ...runs.value.filter(run => !historyRuns.value.some(old => old.id === run.id))]
  })
  const activeRun = computed(() => latest(runs.value, run => sheetRun(run) && run.sheet_id === activeSheet.value && !terminal(run.state)))
  const runtime = computed(() => latest(registry.value?.runtimes || [], value => value.sheet_id === activeSheet.value && !registry.value?.reset_epochs.includes(value.runtime_epoch)))
  const currentRuns = computed(() => runs.value.filter(run => sheetRun(run) && run.sheet_id === activeSheet.value && !registry.value?.reset_epochs.includes(run.runtime_epoch)))
  const displayedRun = computed(() => historyRows.value.find(run => sheetRun(run) && run.id === selectedHistory.value && run.sheet_id === activeSheet.value) || currentRuns.value.at(-1))
  const displayedResult = computed(() => displayedRun.value ? details.value[displayedRun.value.id] : undefined)
  const outdated = computed(() => !!registry.value && registry.value.revision !== revision.value)
  const canExecute = computed(() => !accessLost.value && (registry.value?.can_execute ?? project().permissions.execute))
  const canStart = computed(() => canExecute.value && connected.value && registry.value?.resources?.remaining_ms !== '0' && !registry.value?.dependency_busy && !pending.value && !requestBusy.value && !editorBusy.value && !dirty.value && !outdated.value)
  const canControl = computed(() => canExecute.value && connected.value && !pending.value && !requestBusy.value)
  const canRestart = computed(() => canControl.value && !activeRun.value)
  const canApplyModules = computed(() => canRestart.value && !!runtime.value && !runtime.value.iteration_running &&
    !registry.value?.dependency_busy && !editorBusy.value && !dirty.value && !outdated.value)
  const canRun = computed(() => canStart.value && !activeRun.value && !runtime.value?.needs_restart && !runtime.value?.iteration_running)
  const invocationRun = computed(() => historyRows.value.find(run => run.id === selectedInvocation.value && !sheetRun(run)))
  const invocationResult = computed(() => invocationRun.value ? details.value[invocationRun.value.id] : undefined)
  const status = computed(() => connectionError.value ? 'Disconnected' : !connected.value ? 'Connecting…' : requestBusy.value ? 'Updating execution status…' : activeRun.value ? runLabel(activeRun.value.state) : pending.value ? 'Checking command status' : !canExecute.value ? 'Read-only runtime' : registry.value?.dependency_busy ? 'Updating dependencies…' : runtime.value?.needs_restart ? 'Restart required' : outdated.value ? 'Newer notebook version available' : dirty.value ? 'Save changes to run' : 'Ready to run')
  const resolveText = computed(() => {
    const sheet = document.value?.sheets.find(sheet => sheet.id === activeSheet.value)
    return textResolver(sheet, Object.fromEntries((sheet?.cells || []).filter(cell => cell.kind === 'code').map(cell => [cell.id, cellPresentation(cell.id, cell.source)])))
  })

  async function loadHistory(older = false) {
    if (historyBusy.value || accessLost.value) return
    historyBusy.value = true; historyError.value = ''
    const version = generation
    try {
      const cursor = older ? historyBefore.value : null
      const page = await api<{ runs: RunSummary[]; before: string | null }>(`${base}/history${cursor ? '?before=' + encodeURIComponent(cursor) : ''}`, 'GET', undefined, readController.signal)
      if (!disposed && version === generation) {
        historyRuns.value = older ? [...page.runs, ...historyRuns.value.filter(run => !page.runs.some(value => value.id === run.id))] : page.runs
        historyBefore.value = page.before; historyLoaded.value = true
      }
    } catch (cause) { if (!disposed) historyError.value = cause instanceof Error ? cause.message : 'Could not read run history.' }
    finally { historyBusy.value = false }
  }
  function setPending(command: Command | null) {
    pending.value = command
    pendingState.value = 'unknown'
    if (guest) return
    try { if (command) sessionStorage.setItem(storageKey, JSON.stringify(command)); else sessionStorage.removeItem(storageKey) }
    catch { /* Read-only registry recovery also works without browser storage. */ }
  }
  async function resultFor(run: RunSummary) {
    const version = generation
    const cached = details.value[run.id]
    if (cached && terminal(cached.state) && !cached.rich_error) return cached
    const response = await api<{ run: RunResult }>(`${base}/runs/${encodeURIComponent(run.id)}`, 'GET', undefined, readController.signal)
    if (response.run.id !== run.id || !Array.isArray(response.run.cells) || !Array.isArray(response.run.live_cells)) throw new Error('Could not read the run result.')
    if (!disposed && !accessLost.value && version === generation) {
      details.value[run.id] = response.run
      const index = detailOrder.indexOf(run.id)
      if (index !== -1) detailOrder.splice(index, 1)
      detailOrder.push(run.id)
      while (detailOrder.length > 3) delete details.value[detailOrder.shift()!]
    }
    return response.run
  }
  async function checkPending() {
    const command = pending.value
    if (!command) return
    const response = await api<{ command: { state: 'unknown' | 'accepted'; run?: RunSummary; service?: ServiceSummary } }>(`${base}/commands/${encodeURIComponent(command.body.command_id)}`, 'GET', undefined, readController.signal)
    if (disposed || pending.value?.body.command_id !== command.body.command_id) return
    if (response.command.state === 'accepted') {
      if (command.kind === 'invoke' && response.command.run) selectedInvocation.value = response.command.run.id
      if (command.kind === 'service' && command.body.operation === 'once' && response.command.service?.run_id) selectedInvocation.value = response.command.service.run_id
      setPending(null); error.value = ''
    }
    else pendingState.value = 'not_recorded'
  }
  function schedule() {
    clearTimeout(timer)
    if (disposed || accessLost.value || !document.value || window.document.hidden) return
    const active = runs.value.some(run => !terminal(run.state)) || !!pending.value
    const delay = guest ? Math.min(guest.leaseSeconds * 1000 / 3, active ? 1000 : 5000) : active ? 500 : 2000
    timer = setTimeout(() => void refresh(true), delay)
  }
  async function refreshOnce(poll: boolean) {
    try {
      if (guest && poll) {
        const response = await api<{ runs: RunSummary[]; resources: ResourceStatus }>(guest.leasePath, 'POST', { status: true }, readController.signal)
        if (disposed) return
        const current = registry.value
        const signature = JSON.stringify(response.runs.map(run => [run.id, run.state, run.runtime_epoch]))
        const changed = heartbeatRuns === undefined
          ? response.runs.some(run => !current?.runs.some(previous => previous.id === run.id && previous.state === run.state))
          : heartbeatRuns !== signature
        heartbeatRuns = signature
        if (current && connected.value && !changed && !pending.value && !response.runs.some(run => !terminal(run.state))) {
          current.resources = response.resources
          return
        }
      }
      const response = await api<Registry>(base + (activeBoard.value ? '?board_id=' + encodeURIComponent(activeBoard.value) : ''), 'GET', undefined, readController.signal)
      if (disposed) return
      if (!Array.isArray(response.services) || !Array.isArray(response.runs) || !Array.isArray(response.runtimes) || !Array.isArray(response.reset_epochs) || typeof response.revision !== 'string' || typeof response.can_execute !== 'boolean') throw new Error('Could not read execution status.')
      registry.value = response
      connected.value = true
      accessLost.value = false
      connectionError.value = ''
      const visible = new Set([...response.runs, ...historyRuns.value].map(run => run.id))
      for (const id of Object.keys(details.value)) if (!visible.has(id)) delete details.value[id]
      await checkPending()
      if (invocationRun.value) await resultFor(invocationRun.value)
      if (selectedService.value) await loadServiceHistory()
      const run = displayedRun.value
      if (run) {
        await resultFor(run)
        if (!terminal(run.state)) {
          const previous = latest(currentRuns.value, value => value.id !== run.id && value.runtime_epoch === run.runtime_epoch && terminal(value.state))
          if (previous) await resultFor(previous)
        }
      }
    } catch (cause) {
      if (disposed) return
      connected.value = false
      connectionError.value = cause instanceof Error ? cause.message : 'Could not refresh execution status.'
      if (guest && (!(cause instanceof APIError) || [401, 403, 404, 410, 503].includes(cause.status))) {
        accessLost.value = true
        guest.expired('The demo notebook expired or lost its connection. Open a fresh copy to continue.')
        return
      }
      if (cause instanceof APIError && [401, 403, 404].includes(cause.status)) {
        generation++; historyRequest++
        accessLost.value = true
        serviceHistory.value = null; selectedService.value = null; selectedInvocation.value = ''
        registry.value = null
        historyRuns.value = []; historyBefore.value = null; historyLoaded.value = false
        details.value = {}
      }
    }
  }
  function refresh(poll = false): Promise<void> {
    if (disposed || !document.value) return Promise.resolve()
    if (refreshing) return refreshing
    clearTimeout(timer)
    refreshing = refreshOnce(poll).finally(() => { refreshing = null; schedule() })
    return refreshing
  }
  async function send(command: Command) {
    if (requestBusy.value) return
    requestBusy.value = true
    error.value = ''
    setPending(command) // Publish the exact command before any bytes are sent.
    const path = command.kind === 'run' ? `${base}/runs` : command.kind === 'invoke' ? `${base}/invocations` : command.kind === 'service' ? `${base}/services` : command.kind === 'stop' || command.kind === 'restart_invocation' ? `${base}/runs/${encodeURIComponent(command.run_id!)}/${command.kind === 'stop' ? 'stop' : 'restart'}` : `${base}/restart`
    try {
      const response = await api<{ run?: RunSummary; service?: ServiceSummary }>(path, 'POST', command.body)
      if (command.kind === 'invoke' && response.run) selectedInvocation.value = response.run.id
      if (command.kind === 'service' && command.body.operation === 'once' && response.service?.run_id) selectedInvocation.value = response.service.run_id
      if (pending.value?.body.command_id === command.body.command_id) setPending(null)
      selectedHistory.value = ''
    } catch (cause) {
      error.value = cause instanceof Error ? cause.message : 'The execution request failed.'
      if (cause instanceof APIError && cause.status < 500) setPending(null)
      // A transport/5xx failure can follow acceptance. Never invent a new ID or
      // automatically repeat a mutation; a receipt read resolves its outcome.
    } finally {
      // An idle poll may predate this mutation. Join it, then read a fresh
      // registry before enabling another command.
      if (refreshing) await refreshing
      await refresh()
      requestBusy.value = false
    }
  }
  function start(cellId: string, action: 'run' | 'run_all') {
    if (!canRun.value) return
    return send({ kind: 'run', body: { command_id: newId('run'), revision: revision.value, sheet_id: activeSheet.value, cell_id: cellId, action } })
  }
  function stop(run: RunSummary, force = false) {
    if (!canExecute.value || requestBusy.value || pending.value) return
    if (force && !window.confirm('Force stop this worker? Its current variables and in-progress work will be discarded.')) return
    return send({ kind: 'stop', run_id: run.id, body: { command_id: newId('stop'), runtime_epoch: run.runtime_epoch, force } })
  }
  function resetWorker() {
    return send({ kind: 'restart', body: { command_id: newId('restart'), sheet_id: activeSheet.value, runtime_epoch: runtime.value?.runtime_epoch || null } })
  }
  function restart() {
    if (!canRestart.value) return
    if (!window.confirm('Restart this worker? Its variables and current results will be cleared. The saved notebook will be kept.')) return
    return resetWorker()
  }
  function applyModules() {
    if (!canApplyModules.value) return
    if (!window.confirm("Restart this sheet's worker to apply the saved modules? Current variables and results will be cleared. The next run will load the saved modules.")) return
    return resetWorker()
  }
  function retry() {
    if (canExecute.value && pending.value && pendingState.value === 'not_recorded') return send(pending.value)
  }
  function invoke(board: string, component: string) {
    if (!canStart.value || runs.value.some(run => run.board_id === board && run.component_id === component && !terminal(run.state))) return
    return send({ kind: 'invoke', body: { command_id: newId('invoke'), revision: revision.value, board_id: board, component_id: component } })
  }
  function configureService(board: string, component: string, operation: ServiceOperation) {
    if (!(['start', 'once'].includes(operation) ? canStart.value : canControl.value)) return
    return send({ kind: 'service', body: { command_id: newId('service'), revision: revision.value, board_id: board, component_id: component, operation } })
  }
  function restartInvocation(run: RunSummary) {
    if (!canControl.value || !terminal(run.state)) return
    if (!window.confirm('Restart this invocation worker? Its variables and current results will be cleared. Pause an enabled service first.')) return
    return send({ kind: 'restart_invocation', run_id: run.id, body: { command_id: newId('restart'), runtime_epoch: run.runtime_epoch } })
  }
  function inspectInvocation(run: RunSummary) { if (!sheetRun(run)) { selectedInvocation.value = run.id; void refresh() } }
  async function loadServiceHistory() {
    const selected = selectedService.value, version = generation, request = ++historyRequest
    if (!selected) { serviceHistory.value = null; return }
    try {
      const response = await api<ServiceHistory>(`${base}/services/${encodeURIComponent(selected.board)}/${encodeURIComponent(selected.component)}${selected.before ? '?before=' + encodeURIComponent(selected.before) : ''}`, 'GET', undefined, readController.signal)
      if (!disposed && !accessLost.value && version === generation && request === historyRequest) { serviceHistory.value = response; serviceError.value = '' }
    } catch (cause) { if (!disposed && request === historyRequest) { serviceHistory.value = null; serviceError.value = cause instanceof Error ? cause.message : 'Could not read service history.' } }
  }
  function inspectService(board: string, component: string, before: string | null = null) {
    serviceHistory.value = null; serviceError.value = ''; selectedService.value = { board, component, before }; void loadServiceHistory()
  }
  function cellPresentation(id: string, source: string): CellPresentation {
    const run = displayedRun.value
    const result = displayedResult.value
    let value = result?.cells.find(cell => cell.id === id)
    let valueRun = run
    let previous = false
    if (!value && run && !terminal(run.state)) {
      const earlier = latest(currentRuns.value, item => item.id !== run.id && item.runtime_epoch === run.runtime_epoch && !!details.value[item.id]?.cells.some(cell => cell.id === id))
      value = earlier ? details.value[earlier.id]?.cells.find(cell => cell.id === id) : undefined
      valueRun = earlier
      previous = !!value
    }
    const live = result?.live_cells.find(cell => cell.id === id)
    const media = live || value
    const sourceStale = dirty.value || outdated.value || run?.revision !== revision.value || !!registry.value?.reset_epochs.includes(run?.runtime_epoch || '') || run?.id !== currentRuns.value.at(-1)?.id
    const stale = sourceStale || result?.environment_stale || runtime.value?.needs_restart
    return {
      result_format: value?.result_format, result_table: value?.table || null, revision: valueRun?.revision,
      result: value?.result || '', error: value?.error || '', output: live?.output.length ? live.output : value?.output || [],
      ok: value?.ok || false, metrics: value?.metrics || [],
      text_values: media?.text_values || [], diagnostics: media?.diagnostics || [], diagnostics_truncated: media?.diagnostics_truncated || false,
      diagnostics_stale: sourceStale || (!live && previous) || media?.source !== source,
      stale: !!value && (previous || stale || value.dirty || value.source !== source),
      rich: { table: media?.table || null, displays: media?.displays || [], images: media?.images || [], rich_unsupported: media?.rich_unsupported || false,
        audio: media?.audio || [], audio_limited: media?.audio_limited || false,
        audio_stale: !!media && (stale || media.source !== source || (!live && previous) || !!run && terminal(run.state) && media.rich_stale),
        audio_controls: (result?.live_cells.length ? result.live_cells : result?.cells || []).flatMap(cell => cell.audio_controls || []).filter(control => control.cell === id),
        progress: media?.progress || [], stopwatches: media?.stopwatches || [], charts: media?.charts || [],
        elapsed_ms: media?.elapsed_ms ?? null, timing_running: media?.timing_running || false,
        environment_rebuild_ms: media?.environment_rebuild_ms ?? null,
        telemetry_stale: !!media && (media.telemetry_stale || stale || media.source !== source || (!live && previous)),
        rich_stale: !!media && (media.rich_stale || stale || media.source !== source || (!live && previous)) },
      identity: `${run?.id || ''}:${id}`,
      active: !!run && !terminal(run.state),
      running: !!run && !terminal(run.state) && (result?.executing_cell || run.executing_cell || run.cell_id) === id,
    }
  }
  function visibility() { if (window.document.hidden) clearTimeout(timer); else void refresh() }
  function textVariables(before?: string) {
    return resolveText.value(before)
  }
  watch([() => document.value !== null, revision, activeSheet, activeBoard], () => { selectedHistory.value = ''; void refresh() })
  watch(selectedHistory, () => void refresh())
  onMounted(() => { window.addEventListener('focus', visibility); window.document.addEventListener('visibilitychange', visibility) })
  onUnmounted(() => { disposed = true; clearTimeout(timer); readController.abort(); window.removeEventListener('focus', visibility); window.document.removeEventListener('visibilitychange', visibility) })
  function checkStatus() { error.value = ''; return refresh() }
  return { historyRows, historyBefore, historyLoaded, historyBusy, historyError, loadHistory, textVariables, selectedInvocation, invocationRun, invocationResult, selectedService, serviceHistory, serviceError, canStart, canControl, invoke, configureService, restartInvocation, inspectInvocation, inspectService, registry, runs, runtime, activeRun, displayedRun, displayedResult, selectedHistory, pending, pendingState, requestBusy, connected, error, connectionError, canExecute, canRun, canApplyModules, outdated, status, refresh: checkStatus, start, stop, restart, applyModules, retry, cellPresentation }
}
