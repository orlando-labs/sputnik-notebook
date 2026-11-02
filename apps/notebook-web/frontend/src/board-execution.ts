import type { BoardComponent, NotebookBoard } from './boards'
import type { NotebookDocument } from './notebook'
import type { CellPresentation, RunResult, RunSummary } from './execution'
import { emptyPresentation } from './boards'
import { parseDocumentJSON } from './document-json'
export interface ServiceSummary {
  board_id: string; component_id: string; sheet_id: string; revision: string; enabled: boolean; running: boolean
  run_id: string | null; runs: string; failures: string; skipped: string; history_count: string; status: string
}
export type ServiceOperation = 'start' | 'pause' | 'once' | 'clear'
export interface ServiceHistory { service: ServiceSummary; history: { id: string; started: number; duration: number; ok: boolean; value: string | null; error: string | null; truncated: boolean }[]; before: string | null }
export interface BoardRuntime {
  boardId: string; components: BoardComponent[]; runs: RunSummary[]; services: ServiceSummary[]
  canStart: boolean; canControl: boolean; connected: boolean; sheetRun?: RunSummary; sheetNeedsRestart: boolean
  invoke: (component: string) => void; configure: (component: string, operation: ServiceOperation) => void
  stop: (run: RunSummary, force?: boolean) => void; restart: (run?: RunSummary) => void
  inspect: (run: RunSummary) => void; history: (component: string) => void; runSheet: () => void
}
export function allBoardComponents(board: NotebookBoard): BoardComponent[] {
  return board.components.flatMap(component => [component, ...(component.panels || []).flatMap(panel => allBoardComponents({ ...board, components: panel.components }))])
}
const identifier = /^[A-Za-z_][A-Za-z0-9_]*$/
export function commandSettingsError(component: BoardComponent, document: NotebookDocument): string {
  if (component.kind === 'action' || component.kind === 'periodic_work') {
    if (!identifier.test(component.module_id || '') || !identifier.test(component.function || '')) return 'Choose a module and exported function.'
    if (component.kind === 'action') {
      const args = component.p1?.arguments || [], names = new Set<string>(), ids = new Set<string>(); let named = false
      if (args.length > 64) return 'An action permits at most 64 arguments.'
      for (const arg of args) {
        if (!identifier.test(arg.id) || ids.has(arg.id)) return 'Arguments need unique valid identities.'
        ids.add(arg.id)
        if (arg.name) { if (!identifier.test(arg.name) || names.has(arg.name)) return 'Use unique argument names.'; names.add(arg.name); named = true }
        else if (named) return 'Place positional arguments before named arguments.'
        if (arg.input != null) { if (!document.inputs?.some(input => input.id === arg.input)) return 'Choose an available project parameter.' }
        else {
          try { const source = (arg.value_json || '').trim(), value = parseDocumentJSON(source), integer = /^-?(?:0|[1-9]\d*)$/.test(source); if (value !== null && typeof value === 'object' && !integer) throw new Error(); if (integer && (BigInt(source) < -9223372036854775808n || BigInt(source) > 9223372036854775807n)) throw new Error() }
          catch { return 'Enter scalar JSON for every constant argument.' }
        }
      }
    } else {
      if (!Number.isFinite(component.period_seconds ?? 60) || (component.period_seconds ?? 60) < .01 || (component.period_seconds ?? 60) > 31536000) return 'Period must be 0.01–31536000 seconds.'
      if (!['fixed_delay', 'fixed_rate'].includes(component.timing || 'fixed_delay') || !['none', 'all', 'tail'].includes(component.retention || 'tail')) return 'Choose valid schedule and history modes.'
      if (!Number.isInteger(component.tail_limit ?? 100) || (component.tail_limit ?? 100) < 1 || (component.tail_limit ?? 100) > 1000000) return 'Tail must be 1–1000000 runs.'
    }
  }
  if (component.kind === 'execution_controls' && !['sheet', 'cell', 'action', 'service'].includes(component.p1?.target_kind || 'sheet')) return 'Choose an execution target.'
  if (component.kind === 'status' && !['sheet', 'cell', 'action', 'service', 'runtime'].includes(component.p1?.target_kind || (component.cell == null ? 'sheet' : 'cell'))) return 'Choose a status target.'
  return ''
}
export function invocationPresentation(run: RunSummary, result: RunResult | undefined, stale: boolean): CellPresentation {
  const value = result?.cells.find(cell => cell.id === run.cell_id), live = result?.live_cells.find(cell => cell.id === run.cell_id), media = live || value
  const presentation = emptyPresentation(run.id)
  return { ...presentation, result: value?.result || '', error: value?.error || '', output: live?.output.length ? live.output : value?.output || [], ok: value?.ok || false, metrics: value?.metrics || [],
    result_format: value?.result_format, result_table: value?.table || null, revision: run.revision,
    active: !['succeeded', 'failed', 'cancelled', 'force-stopped', 'interrupted'].includes(run.state), running: ['preparing', 'running', 'draining', 'stopping', 'terminating'].includes(run.state), stale,
    rich: media ? { ...media, audio_stale: stale || ['succeeded', 'failed', 'cancelled', 'force-stopped', 'interrupted'].includes(run.state) && media.rich_stale, rich_stale: media.rich_stale || stale, telemetry_stale: media.telemetry_stale || stale } : presentation.rich }
}
