import { documentJSON, parseDocumentJSON } from './document-json'
import { newCell, newId, type NotebookDocument } from './notebook'

export function duplicateSheet(document: NotebookDocument, id: string) {
  const original = document.sheets.find(sheet => sheet.id === id)
  if (!original) throw new Error('Select a sheet to duplicate.')
  const copy = parseDocumentJSON(documentJSON(original)) as typeof original
  copy.id = newId('sheet'); copy.title = (original.title + ' copy').slice(0, 200)
  const used = new Set(document.sheets.flatMap(sheet => sheet.cells.map(cell => cell.id)))
  for (const cell of copy.cells) {
    cell.id = newCell('code', used).id; used.add(cell.id)
    const components = [...(cell.cell_ui?.pre || []), ...(cell.cell_ui?.post || [])]
    const ids = new Map(components.map(component => [component.id, newId('component')]))
    for (const component of components) {
      component.id = ids.get(component.id)!
      if (component.p1?.target_component && ids.has(component.p1.target_component)) component.p1.target_component = ids.get(component.p1.target_component)
    }
  }
  document.sheets.splice(document.sheets.indexOf(original) + 1, 0, copy)
  return copy.id
}

export function moveSheet(document: NotebookDocument, id: string, direction: -1 | 1) {
  const index = document.sheets.findIndex(sheet => sheet.id === id), destination = index + direction
  if (index < 0 || destination < 0 || destination >= document.sheets.length) return
  document.sheets.splice(destination, 0, document.sheets.splice(index, 1)[0]!)
}

export function deleteSheet(document: NotebookDocument, id: string, replacement: string) {
  const removed = document.sheets.find(sheet => sheet.id === id)
  if (!removed) throw new Error('Select a sheet to delete.')
  const consumers = document.sheets.flatMap(sheet =>
    (sheet.imports || []).filter(link => link.sheet === id).map(link => `${sheet.title} · ${link.name}`))
  if (consumers.length) throw new Error(`Remove or change these imports before deleting the sheet: ${consumers.join(', ')}.`)
  if (document.sheets.length === 1) {
    const blank = { id: newId('sheet'), title: 'Main', cells: [newCell('code', new Set(removed.cells.map(cell => cell.id)))] }
    document.sheets.push(blank)
    replacement = blank.id
  } else if (!document.sheets.some(sheet => sheet.id === replacement && sheet.id !== id)) {
    throw new Error('Choose a replacement controller sheet.')
  }
  document.sheets = document.sheets.filter(sheet => sheet.id !== id)
  for (const board of document.boards || []) if (board.sheet === id) board.sheet = replacement
  if (document.active_sheet === id) document.active_sheet = replacement
  return replacement
}
