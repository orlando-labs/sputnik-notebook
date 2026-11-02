import type { CellComponent, InputDefinition, InputState } from './inputs'
import type { NotebookSheet } from './notebook'
import type { CellPresentation, RunResult } from './execution'
import type { ResourceStatus } from './resource-policy'
import { documentJSON } from './document-json'
import type { BoardRuntime } from './board-execution'
import type { TextVariable } from './text-variables'
import type { MediaRuntime } from './media-inputs'
export interface BoardRow { id: string; height?: number; [key: string]: unknown }
export interface BoardPanel { id: string; title: string; rows: BoardRow[]; components: BoardComponent[]; [key: string]: unknown }
export interface BoardComponent extends CellComponent {
  cell?: unknown; row?: string; span?: number; h_align?: string; v_align?: string; panels?: BoardPanel[]
  split_axis?: string; split_fraction?: number; split_min?: number; progress_id?: string; stopwatch_id?: string
  text_content?: { source: string; formatting?: unknown }; text_mode?: string
  image_items?: unknown[]
  module_id?: string; function?: string; period_seconds?: number; timing?: string; retention?: string; tail_limit?: number
  store_values?: boolean; store_errors?: boolean; run_immediately?: boolean; stop_on_error?: boolean; pause_when_hidden?: boolean
}
export interface NotebookBoard { id: string; title: string; sheet: string; columns: number; rows?: BoardRow[]; components: BoardComponent[]; [key: string]: unknown }
export interface BoardContext {
  projectId?: string; savedRevision?: string
  observation?: { result?: RunResult; stale: boolean; connected: boolean; status: string; needsRestart: boolean; state?: string; epoch?: string; resources?: ResourceStatus }
  onOpenSource?: (cell?: string, module?: string) => void
  sheet?: NotebookSheet; presentations: Record<string, CellPresentation>; definitions: InputDefinition[]; state?: InputState
  components?: BoardComponent[]; canConfigure?: boolean; onConfigure?: (id: string, presets: unknown[]) => void
  disabled: boolean; canRun: boolean; canExecute: boolean; identity: string
  onApply: (values: Record<string, string>, version: string) => Promise<boolean>
  onDirty: (id: string, dirty: boolean) => void; onRun: (cell: string) => void
  onHistory?: (compare: boolean) => void
  runtime?: BoardRuntime
  textVariables?: TextVariable[]
  media?: MediaRuntime & { boardId: string; onDirty: (id: string, dirty: boolean) => void }
}
export function referenceID(value: unknown) { return typeof value === 'string' ? value : value == null ? '' : documentJSON(value) }
export function boardLayout(board: Pick<NotebookBoard, 'rows' | 'components' | 'columns'>) {
  if (board.rows) return { rows: board.rows, components: board.components }
  const columns = Math.min(6, Math.max(1, board.columns || 2))
  const visual = board.components.filter(item => item.kind !== 'periodic_work')
  const rows = Array.from({ length: Math.max(1, Math.ceil(visual.length / columns)) }, (_, index) => ({ id: `row_${index + 1}` }))
  return { rows, components: visual.map((item, i) => ({ ...item, row: rows[Math.floor(i / columns)]!.id, span: Math.floor((i % columns + 1) * 12 / columns) - Math.floor(i % columns * 12 / columns) })) }
}
export function emptyPresentation(identity = ''): CellPresentation {
  return { result: '', error: '', output: [], ok: false, metrics: [], stale: false, running: false, active: false, identity,
    rich: { table: null, displays: [], images: [], progress: [], stopwatches: [], charts: [], elapsed_ms: null, timing_running: false, telemetry_stale: false, rich_stale: false, rich_unsupported: false } }
}
// Swift resolves sheet channels in reverse authored cell order. Preserve the
// provenance of each selected source rather than flattening unrelated workers.
export function boardPresentation(component: BoardComponent, context: BoardContext): CellPresentation {
  if (!['live_chart', 'image', 'image_carousel', 'stopwatch'].includes(component.kind)) return context.presentations[referenceID(component.cell)] || emptyPresentation(context.identity)
  const all = (context.sheet?.cells || []).filter(cell => cell.kind === 'code').map(cell => context.presentations[cell.id]).filter((value): value is CellPresentation => !!value).reverse()
  const result = emptyPresentation(context.identity)
  const used: CellPresentation[] = []
  if (component.kind === 'live_chart') {
    const channels = component.p1?.series?.length ? component.p1.series.map(item => item.id) : [component.chart_id || component.id]
    for (const id of channels) { const source = all.find(item => item.rich.charts.some(chart => chart.id === id)); if (source) { result.rich.charts.push(source.rich.charts.find(chart => chart.id === id)!); used.push(source) } }
  } else if (component.kind === 'stopwatch') {
    const channel = component.stopwatch_id ?? 'default', seen = new Set<string>()
    const ordered = [...all.filter(item => item.active && !item.rich.telemetry_stale), ...all.filter(item => !item.active || item.rich.telemetry_stale)]
    for (const source of ordered) for (const timer of source.rich.stopwatches) if ((!channel || timer.id === channel) && !seen.has(timer.id)) { seen.add(timer.id); result.rich.stopwatches.push(timer); used.push(source) }
  } else {
    const id = component.image_id || component.id, source = all.find(item => item.rich.images.some(series => series.id === id))
    if (source) { result.rich.images = [source.rich.images.find(series => series.id === id)!]; used.push(source) }
  }
  result.active = used.some(item => item.active); result.running = used.some(item => item.running)
  result.rich.telemetry_stale = used.some(item => item.rich.telemetry_stale)
  result.rich.rich_stale = used.some(item => item.rich.rich_stale && !item.running)
  result.stale = used.some(item => item.stale)
  return result
}
