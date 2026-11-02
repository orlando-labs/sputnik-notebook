import type { RunResult, RunSummary } from './execution'
import type { NotebookDocument } from './notebook'
import { presetError } from './parameter-presets'
export interface RunMetadata { title: string; pinned: boolean; version: string }
export interface RunSnapshot {
  schema: 'notebook.web.run.v1'; run: RunSummary; created_at: string | null; source_hash: string
  sources: { sheet_id: string; sheet_title: string; cell_id: string; kind: string; source: string }[]
  inputs: Record<string, string>; cell_inputs: { sheet_id: string; cell_id: string; values: Record<string, string> }[]
  asset_inputs: string[]
  modules: { id: string; path: string }[]
  environment: { available: boolean; source_fingerprint?: string; runtime_fingerprint?: string; generation?: string | null; settings_fingerprint?: string; packages?: { name: string; version: string; variant?: string; digest: string }[] }
  result: RunResult
}
export interface ComparisonRow { name: string; baseline: string | null; candidate: string | null; delta: string }
// Decimal arithmetic is exact for scalar tokens, including Int64 and exponents.
function decimal(value: string): [bigint, number] | null {
  const match = /^(-?)(\d+)(?:\.(\d+))?(?:e([+-]?\d+))?$/i.exec(value)
  if (!match || value.length > 1024) return null
  const exponent = Number(match[4] || 0), fraction = match[3] || ''
  if (!Number.isSafeInteger(exponent) || Math.abs(exponent) > 308) return null
  return [BigInt((match[1] || '') + match[2] + fraction), fraction.length - exponent]
}
export function exactDelta(a: string | null, b: string | null): string {
  if (a === null || b === null) return '—'
  const x = decimal(a), y = decimal(b)
  if (!x || !y) return a === b ? '=' : 'changed'
  const scale = Math.max(0, x[1], y[1]), delta = y[0] * 10n ** BigInt(scale - y[1]) - x[0] * 10n ** BigInt(scale - x[1])
  const digits = (delta < 0 ? -delta : delta).toString().padStart(scale + 1, '0')
  const text = scale ? (digits.slice(0, -scale) + '.' + digits.slice(-scale)).replace(/\.?0+$/, '') : digits
  return (delta > 0 ? '+' : delta < 0 ? '-' : '') + (text || '0')
}
export function experimentValues(snapshot: RunSnapshot) {
  const values: Record<string, string | null> = Object.create(null)
  for (const [id, json] of Object.entries(snapshot.inputs)) values[`Input · ${id}`] = json
  for (const scope of snapshot.cell_inputs) for (const [id, json] of Object.entries(scope.values)) values[`Cell ${scope.sheet_id}/${scope.cell_id} · input · ${id}`] = json
  for (const cell of snapshot.result.cells) {
    for (const metric of cell.metrics) values[`Cell ${snapshot.run.sheet_id}/${cell.id} · metric · ${metric.name}`] = metric.value
    if (cell.elapsed_ms !== null) values[`Cell ${snapshot.run.sheet_id}/${cell.id} · elapsed_ms`] = cell.elapsed_ms
  }
  return values
}
export function compareRuns(a: RunSnapshot, b: RunSnapshot): ComparisonRow[] {
  const first = experimentValues(a), second = experimentValues(b)
  return [...new Set([...Object.keys(first), ...Object.keys(second)])].sort().map(name => ({ name, baseline: first[name] ?? null, candidate: second[name] ?? null, delta: exactDelta(first[name] ?? null, second[name] ?? null) }))
}
export function comparisonCSV(rows: ComparisonRow[]) {
  // Quoting alone does not prevent spreadsheet formula interpretation.
  const quote = (text: string) => `"${(/^[=+\-@\t\r]/.test(text) ? "'" : '') + text.replaceAll('"', '""')}"`
  return [['Parameter / metric', 'Baseline', 'Candidate', 'Delta'], ...rows.map(row => [row.name, row.baseline ?? '—', row.candidate ?? '—', row.delta])].map(row => row.map(quote).join(',')).join('\r\n') + '\r\n'
}
function assetInputs(components: import('./boards').BoardComponent[]): string[] {
  return components.flatMap(component => [...(component.kind === 'file_input' && component.input ? [component.input] : []), ...(component.panels || []).flatMap(panel => assetInputs(panel.components))])
}
export function restoreValues(snapshot: RunSnapshot, document: NotebookDocument, scope: string) {
  const values = scope === 'project' ? snapshot.inputs : snapshot.cell_inputs.find(item => item.cell_id === scope)?.values || {}
  const assets = scope === 'project' ? new Set([...(snapshot.asset_inputs || []), ...assetInputs(document.boards?.flatMap(board => board.components) || [])]) : new Set()
  return Object.fromEntries(Object.entries(values).filter(([id]) => !assets.has(id)))
}
export function restoreError(snapshot: RunSnapshot, document: NotebookDocument, scope: string) {
  const cell = scope === 'project' ? undefined : document.sheets.flatMap(sheet => sheet.cells).find(cell => cell.id === scope)
  if (scope !== 'project' && (!cell || cell.kind !== 'code')) return 'The source cell is no longer available.'
  const definitions = scope === 'project' ? document.inputs || [] : cell?.cell_ui?.inputs || []
  const values = restoreValues(snapshot, document, scope)
  if (!Object.keys(values).length) return 'This scope has no saved scalar parameters.'
  return presetError({ id: 'restore', title: 'Restore', values }, definitions, [], scope === 'project' ? document.boards?.flatMap(board => board.components) : [])
}
