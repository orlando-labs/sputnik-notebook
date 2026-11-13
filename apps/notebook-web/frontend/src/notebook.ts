import { parseDocumentJSON } from './document-json'
import type { InputDefinition, CellUI } from './inputs'
import type { NotebookBoard } from './boards'
export interface NotebookCell {
  id: string
  kind: string
  source: string
  mode?: string
  cell_ui?: CellUI
  formatting?: unknown
  [key: string]: unknown
}
export interface NotebookSheetImport { name: string; sheet: string; cell: string; export: string }
export interface NotebookSheet {
  id: string
  title: string
  cells: NotebookCell[]
  imports?: NotebookSheetImport[]
  [key: string]: unknown
}
export interface NotebookModule { id: string; path: string; [key: string]: unknown }
export interface NotebookDocument {
  format: 'sputnik-notebook'
  version: 1 | 2 | 3 | 4 | 5
  title: string
  active_sheet?: string
  sheets: NotebookSheet[]
  modules?: NotebookModule[]
  auto_imports?: string[]
  inputs?: InputDefinition[]
  boards?: NotebookBoard[]
  [key: string]: unknown
}
export interface StoredNotebook { revision: string; document: string }
export interface NotebookResponse { notebook: StoredNotebook | null }

export function parseNotebook(stored: StoredNotebook): NotebookDocument {
  const document = parseDocumentJSON(stored.document) as NotebookDocument
  if (!/^[a-f0-9]{64}$/.test(stored.revision) || document?.format !== 'sputnik-notebook' || ![1, 2, 3, 4, 5].includes(document.version) ||
      typeof document.title !== 'string' || !Array.isArray(document.sheets) || document.sheets.length === 0 ||
      !document.sheets.every((sheet: NotebookSheet) => typeof sheet?.id === 'string' && typeof sheet.title === 'string' &&
        Array.isArray(sheet.cells) && sheet.cells.every(cell => typeof cell?.id === 'string' && typeof cell.kind === 'string' && typeof cell.source === 'string')) ||
      (document.modules != null && (!Array.isArray(document.modules) || !document.modules.every((item: NotebookModule) => typeof item.id === 'string' && typeof item.path === 'string'))) ||
      (document.auto_imports != null && (!Array.isArray(document.auto_imports) || !document.auto_imports.every((item: unknown) => typeof item === 'string')))) {
    throw new Error('This notebook format is not supported by the web editor. Its saved document has not been changed.')
  }
  return document
}
export const newId = (kind: string) => `${kind}_${crypto.randomUUID().replaceAll('-', '')}`
export function newCell(kind: 'code' | 'text', used = new Set<string>()): NotebookCell {
  // Cell IDs are canonical uint64 decimal strings in the native document format.
  // Random IDs avoid reusing deleted IDs; BigInt preserves all 64 bits in JS.
  let id: bigint
  do { id = crypto.getRandomValues(new BigUint64Array(1))[0]! }
  while (id === 0n || id === 18446744073709551615n || used.has(id.toString()))
  return kind === 'code' ? { id: id.toString(), kind, source: '', mode: 'manual' } : { id: id.toString(), kind, source: '' }
}
export function plainCell(cell: NotebookCell) {
  return cell.kind === 'code' || (cell.kind === 'text' && cell.formatting == null)
}
