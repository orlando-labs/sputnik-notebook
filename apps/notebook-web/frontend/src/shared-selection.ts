import { documentJSON, parseDocumentJSON } from './document-json'
import type { BoardComponent } from './boards'
import type { TableSnapshot } from './rich'
export interface SharedSelection { version: 1; source: string; key: unknown; row: Record<string, unknown> }
export interface SourceTable { columns: TableSnapshot['columns']; rows: { id: string; values: unknown[] }[]; total_rows: unknown; truncated: boolean }
export function parseSourceTable(text: string): SourceTable {
  if (new TextEncoder().encode(text).length > 1048576) throw new Error('Table exceeds 1 MiB.')
  const table = parseDocumentJSON(text) as SourceTable
  if (!Array.isArray(table.columns) || !table.columns.length || table.columns.length > 32 || !Array.isArray(table.rows) || table.rows.length > 4096 || new Set(table.columns.map(c => c.id)).size !== table.columns.length || new Set(table.rows.map(r => r.id)).size !== table.rows.length || table.rows.some(r => !Array.isArray(r.values) || r.values.length !== table.columns.length)) throw new Error('Invalid table snapshot.')
  return table
}
export function publicTable(table: SourceTable): TableSnapshot {
  return { ...table, total_rows: documentJSON(table.total_rows), rows: table.rows.map(row => ({ id: row.id, values: row.values.map(value => ({ kind: value === null ? 'null' : typeof value === 'string' ? 'text' : typeof value === 'boolean' ? 'boolean' : /^-?\d+$/.test(documentJSON(value)) ? 'integer' : 'number', text: typeof value === 'string' ? value : value === null ? '' : documentJSON(value) })) })) }
}
export function selectionError(table: SourceTable, key: string) {
  if (new Set(table.columns.map(c => c.title)).size !== table.columns.length) return 'Selection requires unique column names.'
  const matches = table.columns.map((c, i) => c.id === key || c.title === key ? i : -1).filter(i => i >= 0)
  if (matches.length !== 1) return 'Choose exactly one unique key column by name or ID.'
  const index = matches[0]!, keys = table.rows.map(r => r.values[index])
  if (keys.some(v => v === null)) return 'Selection keys cannot be null.'
  if (new Set(keys.map(documentJSON)).size !== keys.length) return 'Selection keys must be unique.'
  return ''
}
export function selectedRow(table: SourceTable, source: string, key: string, rowID: string): SharedSelection {
  const invalid = selectionError(table, key); if (invalid) throw new Error(invalid)
  const index = table.columns.findIndex(c => c.id === key || c.title === key), row = table.rows.find(r => r.id === rowID)
  if (!row) throw new Error('Choose a retained row.')
  const record: Record<string, unknown> = Object.create(null); table.columns.forEach((c, i) => { record[c.title] = row.values[i] })
  const result: SharedSelection = { version: 1, source, key: row.values[index], row: record }
  if (new TextEncoder().encode(documentJSON(result)).length > 256 * 1024) throw new Error('Selected row exceeds 256 KiB.')
  return result
}
export function selectionOwner(components: BoardComponent[], channel: string): SharedSelection | null {
  for (const c of components) { if (c.kind === 'table' && c.selection_id === channel) return (c.selection as SharedSelection) || null; for (const panel of c.panels || []) { const found = selectionOwner(panel.components, channel); if (found) return found } }
  return null
}
export async function assetMatches(data: string, selection: SharedSelection | null, column = 'asset_id') {
  const identity = selection?.row[column]
  if (typeof identity !== 'string' || !/^[a-f0-9]{64}$/.test(identity)) return false
  const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0)), digest = await crypto.subtle.digest('SHA-256', bytes)
  return Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('') === identity
}
export async function assetID(data: string) { const digest = await crypto.subtle.digest('SHA-256', Uint8Array.from(atob(data), c => c.charCodeAt(0))); return Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('') }
