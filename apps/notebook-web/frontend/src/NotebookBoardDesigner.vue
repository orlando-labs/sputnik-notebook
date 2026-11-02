<script setup lang="ts">
import { computed, onUnmounted, ref, watch } from 'vue'
import type { NotebookDocument } from './notebook'
import { newId } from './notebook'
import { documentJSON, parseDocumentJSON } from './document-json'
import { emptyPresentation, type NotebookBoard, type BoardComponent, type BoardContext } from './boards'
import { BoardHistory, addComponent, addPanel, addRow, boardCounts, boardError, boardTools, cloneBoard, designBoard, duplicateComponent, freeColumns, gridAt, moveComponent, newBoard, type GridPath } from './board-editor'
import NotebookBoardInspector from './NotebookBoardInspector.vue'
import NotebookBoardView from './NotebookBoardView.vue'
const props = defineProps<{ document: NotebookDocument; disabled: boolean }>()
const emit = defineEmits<{ commit: [board: NotebookBoard, original: string | null]; dirty: [value: boolean] }>()
const dialog = ref<HTMLDialogElement>(), draft = ref<NotebookBoard | null>(null), path = ref<GridPath>([]), selectedRow = ref(''), selectedComponent = ref('')
const original = ref<string | null>(null), initial = ref(''), error = ref(''), query = ref(''), category = ref('Controls'), span = ref(6), preview = ref(false), history = ref(new BoardHistory())
const ignore = ref(''), focusKey = ref(''), dropRow = ref('')
let sourceDocument: NotebookDocument | null = null, dragSession = '', dragged = ''
const serialized = computed(() => draft.value ? documentJSON(draft.value) : '')
const changed = computed(() => !!draft.value && (original.value === null || serialized.value !== initial.value))
const grid = computed(() => draft.value ? gridAt(draft.value, path.value) : { rows: [], components: [] })
const component = computed(() => grid.value.components.find(component => component.id === selectedComponent.value))
const row = computed(() => grid.value.rows.find(row => row.id === selectedRow.value))
const counts = computed(() => draft.value ? boardCounts(draft.value) : { components: 0, rows: 0, panels: 0 })
const invalid = computed(() => draft.value ? boardError(draft.value, props.document) : '')
const tools = computed(() => boardTools.filter(tool => query.value ? `${tool.title} ${tool.category}`.toLowerCase().includes(query.value.toLowerCase()) : tool.category === category.value))
const crumbs = computed(() => {
  if (!draft.value) return []
  return path.value.map((step, index) => gridAt(draft.value!, path.value.slice(0, index)).components.find(component => component.id === step.component)?.panels?.find(panel => panel.id === step.panel)?.title || 'Panel')
})
const previewContext = computed<BoardContext>(() => {
  const sheet = props.document.sheets.find(sheet => sheet.id === draft.value?.sheet)
  return { sheet, presentations: Object.fromEntries((sheet?.cells || []).map(cell => [cell.id, emptyPresentation('design')])), definitions: props.document.inputs || [], disabled: true, canRun: false, canExecute: false, identity: 'design', onApply: async () => false, onDirty: () => {}, onRun: () => {} }
})
watch(changed, value => emit('dirty', value), { immediate: true })
watch(serialized, (value, previous) => {
  if (!value) return
  if (value === ignore.value) { ignore.value = ''; return }
  if (previous) history.value.remember(previous, `${selectedComponent.value}:${focusKey.value}`)
})
function resetSelection() {
  if (!draft.value) return
  try { gridAt(draft.value, path.value) } catch { path.value = [] }
  if (!grid.value.rows.some(row => row.id === selectedRow.value)) selectedRow.value = grid.value.rows[0]?.id || ''
  if (!grid.value.components.some(component => component.id === selectedComponent.value)) selectedComponent.value = ''
}
function act(operation: (board: NotebookBoard) => void) {
  if (props.disabled || !draft.value) return false
  error.value = ''; focusKey.value = ''
  const before = serialized.value, copy = cloneBoard(draft.value)
  try {
    operation(copy)
    const count = boardCounts(copy)
    if (count.components > 256 || count.rows > 256 || count.panels > 128) throw new Error('A board permits at most 256 components, 256 rows and 128 panels.')
    const after = documentJSON(copy)
    if (before !== after) { history.value.remember(before); ignore.value = after; draft.value = copy }
    resetSelection(); return true
  } catch (cause) { error.value = cause instanceof Error ? cause.message : 'Could not change this board.'; return false }
}
function show(board?: NotebookBoard, duplicate = false, preferredSheet?: string) {
  sourceDocument = props.document; original.value = board && !duplicate ? board.id : null
  const copy = board ? designBoard(board) : newBoard(props.document, preferredSheet)
  if (duplicate) { copy.id = newId('board'); copy.title += ' copy' }
  initial.value = documentJSON(copy); ignore.value = initial.value; draft.value = copy
  path.value = []; selectedRow.value = copy.rows?.[0]?.id || ''; selectedComponent.value = ''; query.value = ''; category.value = 'Controls'; error.value = ''; preview.value = false; history.value = new BoardHistory(); focusKey.value = ''
  dragSession = crypto.randomUUID(); dragged = ''; dialog.value?.showModal()
}
function close() { dialog.value?.close(); draft.value = null; emit('dirty', false); sourceDocument = null; dragged = ''; dropRow.value = '' }
function restore(backwards: boolean) {
  if (!draft.value || props.disabled) return
  const value = history.value.restore(serialized.value, backwards)
  if (value !== undefined) { ignore.value = value; draft.value = parseDocumentJSON(value) as NotebookBoard; resetSelection(); error.value = '' }
}
function add(kind: string) {
  let id = ''
  const applied = act(board => { id = addComponent(board, path.value, selectedRow.value, kind, span.value, props.document) })
  if (applied && id) { selectedComponent.value = id; selectedRow.value = grid.value.components.find(component => component.id === id)?.row || selectedRow.value }
}
function appendRow() { let id = ''; const applied = act(board => { id = addRow(board, path.value) }); if (applied && id) { selectedRow.value = id; selectedComponent.value = '' } }
function selectRow(id: string) { selectedRow.value = id; selectedComponent.value = ''; error.value = ''; focusKey.value = '' }
function selectComponent(value: BoardComponent) { selectedComponent.value = value.id; selectedRow.value = value.row || ''; error.value = ''; focusKey.value = '' }
function moveRow(id: string, direction: number) { act(board => { const rows = gridAt(board, path.value).rows, index = rows.findIndex(row => row.id === id), target = index + direction; if (index >= 0 && target >= 0 && target < rows.length) [rows[index], rows[target]] = [rows[target]!, rows[index]!] }) }
function removeRow(id: string) {
  if (grid.value.components.some(component => component.row === id) && !window.confirm('Delete this row and its components from the designer draft? Undo can restore them.')) return
  act(board => { const grid = gridAt(board, path.value); const index = grid.rows.findIndex(row => row.id === id); if (index < 0) return; grid.rows.splice(index, 1); grid.components.splice(0, grid.components.length, ...grid.components.filter(component => component.row !== id)) })
}
function height(event: Event) { if (!row.value) return; const text = (event.target as HTMLInputElement).value; if (!text) delete row.value.height; else row.value.height = Number(text) }
function move(row: string) { act(board => moveComponent(board, path.value, selectedComponent.value, row)); selectedRow.value = component.value?.row || selectedRow.value }
function width(value: number) { act(board => { const grid = gridAt(board, path.value), component = grid.components.find(component => component.id === selectedComponent.value)!; if (!Number.isInteger(value) || value < 1 || value > freeColumns(grid, component.row || '', component.id)) throw new Error('Choose a width that fits the available columns.'); component.span = value }) }
function reorder(direction: number) { act(board => { const components = gridAt(board, path.value).components, current = components.find(component => component.id === selectedComponent.value)!, siblings = components.filter(component => component.row === current.row), target = siblings[siblings.indexOf(current) + direction]; if (target) { const first = components.indexOf(current), second = components.indexOf(target); [components[first], components[second]] = [components[second]!, components[first]!] } }) }
function duplicate() { let id = ''; const applied = act(board => { id = duplicateComponent(board, path.value, selectedComponent.value) }); if (applied && id) { selectedComponent.value = id; selectedRow.value = component.value?.row || '' } }
function removeComponent() { act(board => { const components = gridAt(board, path.value).components; const index = components.findIndex(component => component.id === selectedComponent.value); if (index >= 0) components.splice(index, 1) }) }
function enter(panel: string) { if (component.value) { path.value = [...path.value, { component: component.value.id, panel }]; selectedComponent.value = ''; selectedRow.value = grid.value.rows[0]?.id || ''; preview.value = false } }
function navigate(depth: number) { path.value = path.value.slice(0, depth); selectedComponent.value = ''; selectedRow.value = grid.value.rows[0]?.id || ''; error.value = '' }
function appendPanel() { act(board => addPanel(board, gridAt(board, path.value).components.find(component => component.id === selectedComponent.value)!)) }
function removePanel(id: string) {
  const panel = component.value?.panels?.find(panel => panel.id === id)
  if (panel?.components.length && !window.confirm('Delete this panel and its components from the designer draft? Undo can restore them.')) return
  act(board => { const component = gridAt(board, path.value).components.find(component => component.id === selectedComponent.value)!; const index = component.panels?.findIndex(panel => panel.id === id) ?? -1; if (index >= 0 && component.kind === 'tabs' && (component.panels?.length || 0) > 1) component.panels!.splice(index, 1) })
}
function movePanel(id: string, direction: number) { act(board => { const panels = gridAt(board, path.value).components.find(component => component.id === selectedComponent.value)!.panels!, index = panels.findIndex(panel => panel.id === id), next = index + direction; if (index >= 0 && next >= 0 && next < panels.length) [panels[index], panels[next]] = [panels[next]!, panels[index]!] }) }
function dragStart(event: DragEvent, id: string) { if (props.disabled) { event.preventDefault(); return }; dragged = id; event.dataTransfer?.setData('application/x-sputnik-board-component', JSON.stringify({ session: dragSession, path: documentJSON(path.value), id })); if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move' }
function dragOver(event: DragEvent, row: string) { if (!props.disabled && dragged && event.dataTransfer?.types.includes('application/x-sputnik-board-component')) { event.preventDefault(); dropRow.value = row; if (event.dataTransfer) event.dataTransfer.dropEffect = 'move' } }
function drop(event: DragEvent, row: string) { event.preventDefault(); try { const payload = JSON.parse(event.dataTransfer?.getData('application/x-sputnik-board-component') || '{}'); if (payload.session === dragSession && payload.path === documentJSON(path.value) && payload.id === dragged) { selectedComponent.value = payload.id; move(row) } } catch { /* Unrelated drag payloads do not edit the draft. */ } finally { dragged = ''; dropRow.value = '' } }
function commit() {
  if (props.disabled || !draft.value) return
  error.value = invalid.value
  if (props.document !== sourceDocument) error.value = 'The notebook was reloaded. Close and reopen the designer before updating it.'
  if (dialog.value?.querySelector('input:invalid')) error.value ||= 'Correct the invalid numeric setting before updating the draft.'
  if (error.value) return
  emit('commit', cloneBoard(draft.value), original.value); close()
}
function shortcut(event: KeyboardEvent) {
  if (!(event.metaKey || event.ctrlKey)) return
  if (event.key.toLowerCase() === 's') { event.preventDefault(); event.stopPropagation(); commit() }
  if (!['INPUT', 'TEXTAREA', 'SELECT'].includes((event.target as HTMLElement).tagName) && ['z', 'y'].includes(event.key.toLowerCase())) { event.preventDefault(); restore(event.key.toLowerCase() === 'z' && !event.shiftKey) }
}
onUnmounted(() => emit('dirty', false))
defineExpose({ show, isOpen: () => !!dialog.value?.open })
</script>
<template>
  <dialog ref="dialog" class="notebook-dialog board-designer" aria-labelledby="board-designer-title" @cancel.prevent="close" @keydown="shortcut" @focusin="focusKey = ($event.target as HTMLElement).getAttribute('aria-label') || ''">
    <template v-if="draft">
      <header class="board-designer-header"><div><h2 id="board-designer-title">Board Designer</h2><p>12 columns per row · Changes join your notebook draft</p></div><label>Board title<input v-model="draft.title" aria-label="Board title" maxlength="200" :disabled="disabled"></label><label>Controller sheet<select v-model="draft.sheet" aria-label="Controller sheet" :disabled="disabled"><option v-for="sheet in document.sheets" :key="sheet.id" :value="sheet.id">{{ sheet.title }}</option></select></label></header>
      <div class="board-designer-palette"><div class="board-palette-toolbar"><div role="tablist" aria-label="Component categories"><button v-for="name in ['Controls', 'Display', 'Layout', 'Services']" :key="name" role="tab" :aria-selected="category === name" @click="category = name; query = ''">{{ name }}</button></div><input v-model="query" type="search" aria-label="Search components" placeholder="Search components…"><label>Insert width<select v-model.number="span" aria-label="Insert width"><option v-for="width in 12" :key="width" :value="width">{{ width }} / 12</option></select></label></div><div class="component-palette"><button v-for="tool in tools" :key="tool.kind" type="button" :disabled="disabled || (tool.kind === 'periodic_work' && !!path.length)" @click="add(tool.kind)">Add {{ tool.title }}</button><p v-if="!tools.length" class="source-note">No matching components</p></div></div>
      <div class="board-designer-viewbar"><nav aria-label="Designer panels"><button class="plain" @click="navigate(0)">{{ draft.title || 'Board' }}</button><template v-for="(title, index) in crumbs" :key="index"><span aria-hidden="true">›</span><button class="plain" @click="navigate(index + 1)">{{ title }}</button></template></nav><button @click="preview = !preview">{{ preview ? 'Edit layout' : 'Preview layout' }}</button></div>
      <div v-if="preview" class="board-designer-preview"><p class="source-note">Layout preview · runtime controls are disabled</p><NotebookBoardView :key="draft.id" :board="draft" :context="previewContext" passive /></div>
      <div v-else class="board-designer-body">
        <div class="board-designer-canvas" aria-label="Board layout" data-testid="board-designer-canvas">
          <article v-for="(row, index) in grid.rows" :key="row.id" class="designer-row" :class="{ selected: selectedRow === row.id, 'drop-target': dropRow === row.id }" :data-designer-row="row.id" @dragover="dragOver($event, row.id)" @drop="drop($event, row.id)" @dragleave="dropRow = ''">
            <div class="designer-row-header"><button class="plain" :aria-label="`Select row ${index + 1}`" @click="selectRow(row.id)">Row {{ index + 1 }} · {{ freeColumns(grid, row.id) }} / 12 free</button><div><button :disabled="disabled || index === 0" :aria-label="`Move row ${index + 1} up`" @click="moveRow(row.id, -1)">↑</button><button :disabled="disabled || index + 1 === grid.rows.length" :aria-label="`Move row ${index + 1} down`" @click="moveRow(row.id, 1)">↓</button><button :disabled="disabled" :aria-label="`Delete row ${index + 1}`" @click="removeRow(row.id)">×</button></div></div>
            <div class="designer-row-grid" :style="{ minHeight: Math.min(row.height || 96, 240) + 'px' }"><button v-for="item in grid.components.filter(component => component.row === row.id && component.kind !== 'periodic_work')" :key="item.id" class="designer-component" :class="{ selected: selectedComponent === item.id }" :style="{ gridColumn: `span ${item.span || 12}` }" :aria-pressed="selectedComponent === item.id" :aria-label="`Select ${item.title}`" :data-designer-component="item.id" :draggable="!disabled" @click="selectComponent(item)" @dragstart="dragStart($event, item.id)" @dragend="dragged = ''; dropRow = ''"><strong>{{ item.title }}</strong><span>{{ item.kind }} · {{ item.span || 12 }} / 12</span><small v-if="item.panels">{{ item.panels.length }} panels</small></button><button v-if="!grid.components.some(component => component.row === row.id)" class="designer-empty-row plain" @click="selectRow(row.id)">Choose a component from the palette</button></div>
          </article>
          <button :disabled="disabled || counts.rows >= 256" @click="appendRow">Add row</button>
          <section v-if="!path.length && draft.components.some(component => component.kind === 'periodic_work')" class="designer-services"><h3>Services</h3><button v-for="service in draft.components.filter(component => component.kind === 'periodic_work')" :key="service.id" class="designer-component" :aria-label="`Select ${service.title}`" @click="selectComponent(service)"><strong>{{ service.title }}</strong><span>Saved service settings</span></button></section>
        </div>
        <aside class="board-designer-inspector" aria-label="Object Inspector"><NotebookBoardInspector v-if="component" :key="component.id" :component="component" :board="draft" :grid="grid" :document="document" :disabled="disabled" @move="move" @width="width" @reorder="reorder" @duplicate="duplicate" @remove="removeComponent" @enter="enter" @add-panel="appendPanel" @remove-panel="removePanel" @move-panel="movePanel" /><fieldset v-else class="board-inspector-fields" :disabled="disabled"><legend>Row Inspector</legend><template v-if="row"><label>Row height<input type="number" :value="row.height" aria-label="Row height" min="48" max="4096" step="any" placeholder="Automatic" @input="height"></label><p class="source-note">48–4096 points, or empty for automatic height.</p><p>{{ freeColumns(grid, row.id) }} of 12 columns available</p></template><p v-else class="source-note">Add a row, then choose a component from the palette.</p></fieldset></aside>
      </div>
      <footer class="board-designer-footer"><p v-if="error || invalid" class="parameter-error" role="alert">{{ error || invalid }}</p><p v-else class="source-note">{{ counts.rows }} rows · {{ counts.components }} components · Save notebook after updating this draft</p><div class="board-inspector-actions"><button :disabled="disabled || !history.undo.length" @click="restore(true)">Undo</button><button :disabled="disabled || !history.redo.length" @click="restore(false)">Redo</button><button @click="close">Cancel</button><button class="primary" :disabled="disabled" @click="commit">Update notebook draft</button></div></footer>
    </template>
  </dialog>
</template>
