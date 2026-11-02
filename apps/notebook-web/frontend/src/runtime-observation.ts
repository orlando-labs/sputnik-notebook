import type { BoardComponent, BoardContext } from './boards'
import type { CellPresentation, RuntimeTask } from './execution'
import type { TableSnapshot } from './rich'

export function literalMatches(text: string, query: string, matchCase = false) {
  const ranges: { start: number; end: number }[] = []
  if (!query || query.length > 256) return { ranges, limited: false }
  const pattern = new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), matchCase ? 'gu' : 'giu')
  for (const match of text.matchAll(pattern)) {
    if (ranges.length === 4096) return { ranges, limited: true }
    ranges.push({ start: match.index!, end: match.index! + match[0].length })
  }
  return { ranges, limited: false }
}
export function taskDepth(task: RuntimeTask, tasks: RuntimeTask[]) {
  const byID = new Map(tasks.map(item => [item.id, item])), seen = new Set([task.id])
  let parent = task.parent, depth = 0
  while (parent !== '0' && depth < 12 && !seen.has(parent)) {
    const next = byID.get(parent); if (!next) break
    seen.add(parent); depth++; parent = next.parent
  }
  return depth
}
export function artifactRows(table: TableSnapshot | null | undefined) {
  if (!table) return []
  const path = table.columns.findIndex(column => column.title === 'path'), name = table.columns.findIndex(column => column.title === 'name'), caption = table.columns.findIndex(column => column.title === 'caption')
  if (path === -1) return []
  return table.rows.slice(0, 128).flatMap(row => {
    const value = row.values[path]
    if (value?.kind !== 'text' || !value.text) return []
    const member = value.text, safe = new TextEncoder().encode(member).length <= 1024 && !/[\u0000-\u001f\u007f\\:]/.test(member) && member.toLowerCase() !== 'project.json' && member.split('/').every(part => part !== '' && part !== '.' && part !== '..')
    return [{ id: row.id, path: member, title: row.values[name]?.text || member.split('/').at(-1) || 'File', caption: row.values[caption]?.text || '', safe }]
  })
}
export function logEntries(output: CellPresentation['output']) {
  const entries: { id: number; stream: string; text: string }[] = []
  let bytes = 0
  for (const [index, event] of output.entries()) {
    const last = entries.at(-1)
    const size = new TextEncoder().encode(event.text).length
    if (last && last.stream === event.stream && bytes + size <= 65536) { last.text += event.text; bytes += size }
    else { entries.push({ id: index, ...event }); bytes = size }
  }
  return entries
}
const stateLabel = (state: string) => ({ succeeded: 'Success', failed: 'Error', cancelled: 'Cancelled', 'force-stopped': 'Force stopped', interrupted: 'Interrupted', preparing: 'Preparing', running: 'Running', draining: 'Finishing', stopping: 'Stopping', terminating: 'Terminating' }[state] || state)
export function targetStatus(component: BoardComponent, context: BoardContext) {
  const kind = component.p1?.target_kind || (component.cell == null ? 'sheet' : 'cell'), runtime = context.runtime, observation = context.observation
  const status = (title: string, detail: string, failed = false, stale = false) => ({ title, detail, failed, stale })
  if (!['sheet', 'cell', 'action', 'service', 'runtime'].includes(kind)) return status('Unavailable', 'Unsupported saved status target. Its settings are preserved.')
  if (!observation) return status('Preview', 'Status is available in the running board.')
  if (!observation.connected) return status('Disconnected', 'Showing previously loaded state. Reconnect to refresh.', true, true)
  if (kind === 'runtime') {
    if (observation.resources?.remaining_ms === '0') return status('Computation quota exhausted', 'Stop, results and retained history remain available.' + (observation.needsRestart ? ' The worker also requires an explicit restart.' : ''), false, true)
    if (observation.needsRestart) return status('Restart required', 'Explicitly restart the worker before another run.', false, true)
    return status('Connected', [observation.state || 'No worker initialized', observation.epoch ? 'Epoch: ' + observation.epoch : '', observation.status].filter(Boolean).join(' · '))
  }
  if (['service', 'action'].includes(kind)) {
    const source = runtime?.components.find(item => item.id === component.p1?.target_component && item.kind === (kind === 'service' ? 'periodic_work' : 'action'))
    if (!source) return status('Unavailable', 'Choose an available ' + kind + ' in the designer.')
    if (kind === 'service') {
      const service = runtime?.services.find(item => item.board_id === runtime.boardId && item.component_id === source.id)
      return service ? status(service.status, `${service.runs} runs · ${service.failures} errors · ${service.skipped} skipped`, service.status === 'Last run failed', observation.stale) : status('Ready', 'Start the service explicitly.')
    }
    const run = [...(runtime?.runs || [])].reverse().find(item => item.board_id === runtime?.boardId && item.component_id === source.id)
    if (!run) return status('Ready', 'Run the action explicitly.')
    const stale = observation.stale || run.revision !== context.savedRevision
    return status(stateLabel(run.state), stale ? 'Source or parameters changed · previous invocation.' : 'Last accepted invocation.', ['failed', 'interrupted'].includes(run.state), stale)
  }
  const cells = (context.sheet?.cells || []).filter(cell => cell.kind === 'code' && (kind !== 'cell' || cell.id === String(component.cell)))
  if (!cells.length) return status('Unavailable', 'Source cell unavailable')
  const run = observation.result
  if (run && !['succeeded', 'failed', 'cancelled', 'force-stopped', 'interrupted'].includes(run.state)) return status(stateLabel(run.state), 'Accepted work belongs to the server.')
  if (kind === 'sheet' && run && ['failed', 'interrupted', 'force-stopped', 'cancelled'].includes(run.state) && !observation.stale) return status(stateLabel(run.state), run.task_errors.join('\n') || run.environment_error || run.error || 'The last accepted run did not complete successfully.', ['failed', 'interrupted'].includes(run.state))
  const values = cells.map(cell => context.presentations[cell.id]).filter((value): value is CellPresentation => !!value)
  if (!values.some(value => value.ok || value.error)) return status('Ready', 'Run to publish the first result.')
  const failed = values.find(value => value.error && !value.stale)
  if (failed) return status('Error', failed.error, true)
  if (observation.stale || values.some(value => value.stale)) return status('Stale', 'Source, parameters or worker changed. Run to refresh.', false, true)
  if (values.length === cells.length && values.every(value => value.ok)) return status('Success', 'Last committed result')
  return status('Ready', 'Run to publish the first result.')
}
