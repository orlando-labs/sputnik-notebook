import { boardLayout, referenceID, type NotebookBoard, type BoardComponent, type BoardPanel, type BoardRow } from './boards'
import type { NotebookDocument } from './notebook'
import { newId } from './notebook'
import { documentJSON, parseDocumentJSON } from './document-json'
import { displayError } from './displays'
import { defaultJSON, editingText, inputError } from './inputs'
import { commandSettingsError } from './board-execution'
import { formattingError } from './rich-text'
import { annotationClassesError, type AnnotationClass } from './image-annotations'

import { dateSettingsError } from './date-input'
import { presetListError, type ParameterPreset } from './parameter-presets'
import { audioSettingsError } from './audio-annotations'

export type GridPath = { component: string; panel: string }[]
export interface BoardGrid { rows: BoardRow[]; components: BoardComponent[] }
export const cloneBoard = <T>(value: T): T => parseDocumentJSON(documentJSON(value)) as T
export const boardTools = [
  { kind: 'status', title: 'Status / Alert', category: 'Display' }, { kind: 'artifacts', title: 'Artifact Browser', category: 'Display' }, { kind: 'task_monitor', title: 'Task Monitor', category: 'Display' },
  { kind: 'action', title: 'Action Button', category: 'Controls' }, { kind: 'execution_controls', title: 'Execution Controls', category: 'Controls' }, { kind: 'periodic_work', title: 'Periodic Work', category: 'Services' },
  { kind: 'file_input', title: 'File Input', category: 'Controls' }, { kind: 'audio_input', title: 'Audio Input', category: 'Controls' },
  { kind: 'date_input', title: 'Date / Time Input', category: 'Controls' }, { kind: 'parameter_presets', title: 'Parameter Presets', category: 'Controls' },
  { kind: 'run_history', title: 'Run History', category: 'Display' }, { kind: 'experiment_compare', title: 'Experiment Compare', category: 'Display' },
  { kind: 'audio_annotator', title: 'Audio Annotator', category: 'Display' },
  { kind: 'input', title: 'Input', category: 'Controls' }, { kind: 'parameter_form', title: 'Parameter Form', category: 'Controls' }, { kind: 'range_input', title: 'Range Input', category: 'Controls' },
  { kind: 'metric', title: 'Metric', category: 'Display' }, { kind: 'table', title: 'Table', category: 'Display' }, { kind: 'live_chart', title: 'Live Chart', category: 'Display' }, { kind: 'image', title: 'Image', category: 'Display' }, { kind: 'image_carousel', title: 'Image Carousel', category: 'Display' }, { kind: 'audio', title: 'Audio', category: 'Display' },
  { kind: 'result', title: 'Result', category: 'Display' }, { kind: 'progress', title: 'Progress', category: 'Display' }, { kind: 'stopwatch', title: 'Stopwatch', category: 'Display' }, { kind: 'plot', title: 'Plot', category: 'Display' }, { kind: 'log', title: 'Log', category: 'Display' }, { kind: 'rich_text', title: 'Text', category: 'Display' },
  { kind: 'text', title: 'Published Text', category: 'Display' },
  { kind: 'run', title: 'Run Cell', category: 'Controls' }, { kind: 'group', title: 'Group', category: 'Layout' }, { kind: 'tabs', title: 'Tabs', category: 'Layout' }, { kind: 'split', title: 'Split View', category: 'Layout' },
] as const
export function designBoard(source: NotebookBoard): NotebookBoard {
  const copy = cloneBoard(source), services = copy.components.filter(component => component.kind === 'periodic_work')
  const layout = boardLayout(copy)
  copy.rows = layout.rows; copy.components = source.rows ? layout.components : [...layout.components, ...services]
  return copy
}
export function newBoard(document: NotebookDocument, sheet = document.active_sheet || document.sheets[0]!.id): NotebookBoard {
  let number = (document.boards?.length || 0) + 1
  const titles = new Set(document.boards?.map(board => board.title))
  while (titles.has(`Board ${number}`)) number++
  return { id: newId('board'), title: `Board ${number}`, sheet, columns: 2, rows: [{ id: newId('row') }], components: [] }
}
export function gridAt(board: NotebookBoard, path: GridPath): BoardGrid {
  let grid: BoardGrid = { rows: board.rows || [], components: board.components }
  for (const step of path) {
    const panel = grid.components.find(component => component.id === step.component)?.panels?.find(panel => panel.id === step.panel)
    if (!panel) throw new Error('This panel is no longer available. Return to the board root.')
    grid = panel
  }
  return grid
}
export function visitComponents(components: BoardComponent[], visitor: (component: BoardComponent) => void) {
  for (const component of components) { visitor(component); for (const panel of component.panels || []) visitComponents(panel.components, visitor) }
}
export function boardCounts(board: NotebookBoard) {
  let components = 0, panels = 0, rows = board.rows?.length || 0
  visitComponents(board.components, component => { components++; panels += component.panels?.length || 0; rows += component.panels?.reduce((sum, panel) => sum + panel.rows.length, 0) || 0 })
  return { components, panels, rows }
}
export function freeColumns(grid: BoardGrid, row: string, exclude = '') { return 12 - grid.components.filter(component => component.row === row && component.id !== exclude && component.kind !== 'periodic_work').reduce((sum, component) => sum + (component.span || 12), 0) }
export function addRow(board: NotebookBoard, path: GridPath) {
  if (boardCounts(board).rows >= 256) throw new Error('A board permits at most 256 rows across all panels.')
  const row = { id: newId('row') }; gridAt(board, path).rows.push(row); return row.id
}
const emptyPanel = (title: string): BoardPanel => ({ id: newId('panel'), title, rows: [{ id: newId('row') }], components: [] })
export function addComponent(board: NotebookBoard, path: GridPath, row: string, kind: string, span: number, document: NotebookDocument) {
  const tool = boardTools.find(tool => tool.kind === kind)
  if (!tool) throw new Error('This component cannot be authored in the web designer yet.')
  if (kind === 'periodic_work' && path.length) throw new Error('Services belong to the board root.')
  if (['group', 'tabs', 'split'].includes(kind) && path.length >= 8) throw new Error('Nested panels may be at most 8 levels deep.')
  if (!Number.isInteger(span) || span < 1 || span > 12) throw new Error('Choose an insertion width from 1 to 12.')
  if (boardCounts(board).components >= 256) throw new Error('A board permits at most 256 components across all panels.')
  const grid = gridAt(board, path)
  if (kind !== 'periodic_work' && (!grid.rows.some(item => item.id === row) || freeColumns(grid, row) < span)) row = addRow(board, path)
  const component: BoardComponent = { id: newId('component'), kind, title: tool.title, row, span }
  if (['metric', 'table', 'result', 'progress', 'plot', 'log', 'artifacts', 'run', 'text', 'audio'].includes(kind)) component.cell = document.sheets.find(sheet => sheet.id === board.sheet)?.cells.find(cell => cell.kind === 'code')?.id || '1'
  if (kind === 'input' || kind === 'range_input') { component.input = document.inputs?.find(input => kind !== 'range_input' || input.type === 'range')?.id || ''; component.control = { style: 'automatic' } }
  if (kind === 'date_input') { component.input = document.inputs?.find(input => input.type === 'string')?.id || ''; component.date_mode = 'date_time'; component.date_time_zone = 'UTC' }
  if (kind === 'parameter_presets') component.p1 = { preset_inputs: [], presets: [] }
  if (kind === 'file_input') { component.input = document.inputs?.find(input => input.type === 'string')?.id || ''; component.p1 = { extensions: '' } }
  if (kind === 'audio_input') { component.audio_id = component.id; component.show_waveform = true; component.audio_recording = true }
  if (kind === 'audio_annotator') { component.audio_source = 'file'; component.audio_id = component.id; component.annotation_id = component.id + '_labels'; component.annotation_classes = []; component.audio_view = 'waveform'; component.audio_fft_size = 1024 }
  if (kind === 'parameter_form') component.fields = (document.inputs || []).slice(0, 128).map(input => ({ input: input.id, control: { style: 'automatic' } }))
  if (kind === 'live_chart') { component.chart_id = 'loss'; component.stroke = '#d97706' }
  if (kind === 'image' || kind === 'image_carousel') { component.image_id = 'image'; component.image_mode = 'fit'; component.image_allow_save = false }
  if (kind === 'rich_text') component.text_content = { source: '' }
  if (kind === 'action' || kind === 'periodic_work') { component.module_id = document.modules?.[0]?.id || ''; component.function = kind === 'action' ? 'run' : 'tick' }
  if (kind === 'action') component.p1 = { arguments: [] }
  if (kind === 'execution_controls') component.p1 = { target_kind: 'sheet' }
  if (kind === 'status') component.p1 = { target_kind: 'sheet' }
  if (kind === 'periodic_work') { delete component.row; delete component.span; component.period_seconds = 60; component.timing = 'fixed_delay'; component.retention = 'tail'; component.tail_limit = 100 }
  if (kind === 'group') component.panels = [emptyPanel('Contents')]
  if (kind === 'tabs' || kind === 'split') component.panels = [emptyPanel('First'), emptyPanel('Second')]
  if (kind === 'split') { component.split_axis = 'horizontal'; component.split_fraction = .5; component.split_min = 120 }
  grid.components.push(component)
  return component.id
}
export function moveComponent(board: NotebookBoard, path: GridPath, id: string, row: string) {
  const grid = gridAt(board, path), component = grid.components.find(component => component.id === id)
  if (!component || component.kind === 'periodic_work' || !grid.rows.some(item => item.id === row)) throw new Error('Choose an available row and component.')
  if (freeColumns(grid, row, id) < (component.span || 12)) throw new Error('Not enough columns in this row. Reduce the width or choose another row.')
  if (component.row !== row) { grid.components.splice(grid.components.indexOf(component), 1); component.row = row; grid.components.push(component) }
}
export function duplicateComponent(board: NotebookBoard, path: GridPath, id: string) {
  const grid = gridAt(board, path), original = grid.components.find(component => component.id === id)
  if (!original) throw new Error('Choose an available component.')
  const identities = new Map<string, string>(), copy = cloneBoard(original)
  function remapIds(component: BoardComponent) {
    const old = component.id; component.id = newId('component'); identities.set(old, component.id)
    for (const panel of component.panels || []) {
      panel.id = newId('panel'); const rows = new Map(panel.rows.map(row => [row.id, newId('row')]))
      for (const row of panel.rows) row.id = rows.get(row.id)!
      for (const child of panel.components) { child.row = rows.get(child.row || '') || child.row; remapIds(child) }
    }
  }
  remapIds(copy)
  visitComponents([copy], component => { const id = component.p1?.target_component; if (typeof id === 'string' && identities.has(id)) component.p1!.target_component = identities.get(id) })
  copy.title += ' copy'
  if (copy.kind !== 'periodic_work' && freeColumns(grid, copy.row || '') < (copy.span || 12)) copy.row = addRow(board, path)
  grid.components.push(copy)
  return copy.id
}
export function addPanel(board: NotebookBoard, component: BoardComponent) {
  if (component.kind !== 'tabs' || (component.panels?.length || 0) >= 32 || boardCounts(board).panels >= 128 || boardCounts(board).rows >= 256) throw new Error('Tabs permit up to 32 panels, within the board limit of 128 panels and 256 rows.')
  ;(component.panels ||= []).push(emptyPanel(`Panel ${(component.panels?.length || 0) + 1}`))
}
export function boardError(board: NotebookBoard, document: NotebookDocument): string {
  if (!board.title.trim() || board.title.includes('\0')) return 'Enter a board title.'
  if (!document.sheets.some(sheet => sheet.id === board.sheet)) return 'Choose an available controller sheet.'
  const counts = boardCounts(board)
  if (counts.components > 256 || counts.rows > 256 || counts.panels > 128) return 'A board permits at most 256 components, 256 rows and 128 panels.'
  const ids = new Set<string>(), identifier = (id: string) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(id)
  function check(grid: BoardGrid, depth: number): string {
    if (depth > 8) return 'Nested panels may be at most 8 levels deep.'
    const rows = new Set<string>()
    for (const row of grid.rows) {
      if (!identifier(row.id) || rows.has(row.id)) return 'Rows need unique valid identities.'
      rows.add(row.id)
      if (row.height !== undefined && (!Number.isFinite(row.height) || row.height < 48 || row.height > 4096)) return 'Row height must be between 48 and 4096 points.'
    }
    for (const component of grid.components) {
      if (!identifier(component.id) || ids.has(component.id)) return 'Component identities must be unique within the board.'
      ids.add(component.id)
      if (!component.title.trim() || component.title.includes('\0')) return 'Every component needs a title.'
      if (component.kind === 'rich_text' && component.text_content && component.text_mode !== 'markdown') { const invalid = formattingError(component.text_content); if (invalid) return `${component.title}: ${invalid}` }
      const invalidCommand = commandSettingsError(component, document)
      if (invalidCommand) return `${component.title}: ${invalidCommand}`
      if (component.kind === 'periodic_work') { if (depth || component.row) return 'Services belong to the root service tray.'; continue }
      if (!rows.has(component.row || '') || !Number.isInteger(component.span ?? 12) || (component.span ?? 12) < 1 || (component.span ?? 12) > 12 || freeColumns(grid, component.row!) < 0) return 'Components must fit within 12 columns in an existing row.'
      if (['image','image_carousel'].includes(component.kind) && component.image_annotator && component.annotation_classes !== undefined) { const invalid=annotationClassesError(component.annotation_classes as AnnotationClass[]); if(invalid)return `${component.title}: ${invalid}` }
      if (component.kind === 'parameter_presets') { const scope = (component.p1?.preset_inputs || []) as string[]; if (new Set(scope).size !== scope.length || scope.some(id => !document.inputs?.some(input => input.id === id))) return 'Choose available preset parameters.'; const invalid = presetListError((component.p1?.presets || []) as ParameterPreset[], document.inputs || [], scope); if (invalid) return invalid }
      if (component.kind === 'date_input') { const input = document.inputs?.find(input => input.id === component.input && input.type === 'string'); if (!input) return 'Date Input requires a String project parameter.'; const invalid = dateSettingsError(component, editingText(defaultJSON(input), 'string')); if (invalid) return invalid }
      if (component.kind === 'audio_annotator') { const invalid = audioSettingsError(component); if (invalid) return `${component.title}: ${invalid}` }
      const invalidDisplay = ['metric', 'live_chart', 'table', 'image', 'image_carousel', 'audio'].includes(component.kind) ? displayError(component.kind === 'image_carousel' ? { ...component, kind: 'image' } : component) : ''
      if (invalidDisplay) return `${component.title}: ${invalidDisplay}`
      if (['metric', 'table', 'result', 'progress', 'plot', 'log', 'artifacts', 'run', 'audio'].includes(component.kind) && !referenceID(component.cell)) return `${component.title}: choose a source cell.`
      if (['input', 'range_input', 'file_input', 'parameter_form'].includes(component.kind)) {
        const fields = component.kind === 'parameter_form' ? component.fields || [] : [{ input: component.input || '', control: component.control }]
        if (fields.length > 128 || new Set(fields.map(field => field.input)).size !== fields.length) return 'A form permits up to 128 different parameters.'
        for (const field of fields) {
          const input = document.inputs?.find(input => input.id === field.input)
          if (!input || (component.kind === 'range_input' && input.type !== 'range') || (component.kind === 'file_input' && input?.type !== 'string')) return `${component.title}: choose an available ${component.kind === 'range_input' ? 'Range ' : ''}project parameter.`
          const invalid = inputError(editingText(defaultJSON(input), input.type), input, field.control)
          if (invalid) return `${component.title}: ${invalid}`
        }
      }
      if (['group', 'tabs', 'split'].includes(component.kind) && !component.panels) return 'Choose valid group, tabs or split panels.'
      if (component.panels) {
        if (!['group', 'tabs', 'split'].includes(component.kind) || !component.panels.length || component.panels.length > 32 || (component.kind === 'group' && component.panels.length !== 1) || (component.kind === 'split' && component.panels.length !== 2)) return 'Choose valid group, tabs or split panels.'
        if (new Set(component.panels.map(panel => panel.id)).size !== component.panels.length) return 'Panel identities must be unique in their container.'
        for (const panel of component.panels) { if (!identifier(panel.id) || !panel.title.trim()) return 'Every panel needs a title and valid identity.'; const invalid = check(panel, depth + 1); if (invalid) return invalid }
      }
      if (component.kind === 'split' && (!Number.isFinite(component.split_fraction ?? .5) || (component.split_fraction ?? .5) < .1 || (component.split_fraction ?? .5) > .9 || !Number.isFinite(component.split_min ?? 120) || (component.split_min ?? 120) < 48 || (component.split_min ?? 120) > 1024)) return 'Split ratio must be 0.1–0.9 and minimum panel size 48–1024 points.'
    }
    return ''
  }
  return check({ rows: board.rows || [], components: board.components }, 0)
}
export class BoardHistory {
  undo: string[] = []; redo: string[] = []; private lastKey = ''; private lastTime = 0
  constructor(private maxBytes = 16 * 1024 * 1024) {}
  remember(before: string, key = '', now = Date.now()) {
    if (!key || key !== this.lastKey || now - this.lastTime > 500 || !this.undo.length) this.undo.push(before)
    this.lastKey = key; this.lastTime = now; this.redo = []; this.trim()
  }
  restore(current: string, backwards: boolean) {
    const from = backwards ? this.undo : this.redo, to = backwards ? this.redo : this.undo
    const value = from.pop(); if (value === undefined) return undefined
    to.push(current); this.lastKey = ''; this.trim(); return value
  }
  private trim() {
    let bytes = [...this.undo, ...this.redo].reduce((sum, value) => sum + new TextEncoder().encode(value).length, 0)
    while (this.undo.length + this.redo.length > 100 || bytes > this.maxBytes) { const value = this.undo.length ? this.undo.shift() : this.redo.shift(); if (value === undefined) break; bytes -= new TextEncoder().encode(value).length }
  }
}
