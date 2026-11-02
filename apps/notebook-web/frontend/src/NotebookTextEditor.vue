<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import { documentJSON, parseDocumentJSON } from './document-json'
import { BoardHistory } from './board-editor'
import { formattingError, inlineFormat, insertTable, listFormat, paragraphFormat, readFormatting, renumberLists, replaceSource, replaceText, selectedParagraphs, tableAt, tableChange, type TextContent, type TextRange, type TextStyle } from './rich-text'
import NotebookTextPreview from './NotebookTextPreview.vue'
import type { TextVariable } from './text-variables'
const props = defineProps<{ content: TextContent; label: string; sourceId?: string; readonly?: boolean; disabled?: boolean; variables?: TextVariable[] }>()
const emit = defineEmits<{ change: [value: TextContent] }>()
const input = ref<HTMLTextAreaElement>(), preview = ref(false), selection = ref<TextRange>({ start: 0, length: 0 }), error = ref(''), history = ref(new BoardHistory()), expected = ref('')
const buffer = ref(props.content.source), composing = ref(false)
const variableName = ref('')
const invalid = computed(() => formattingError(props.content)), locked = computed(() => props.readonly || props.disabled || !!invalid.value)
const currentTable = computed(() => { try { return tableAt(props.content, selection.value.start) } catch { return undefined } })
const style = computed(() => { try { const range = selectedParagraphs(props.content.source, selection.value)[0]; return readFormatting(props.content).paragraphs?.find(item => range && range.start >= item.start && range.start < item.start + item.length)?.style || 'body' } catch { return 'body' } })
watch(() => documentJSON(props.content), value => { if (expected.value !== value) history.value = new BoardHistory(); if (!composing.value) buffer.value = props.content.source; expected.value = ''; error.value = '' })
function capture() { if (input.value) selection.value = { start: input.value.selectionStart, length: input.value.selectionEnd - input.value.selectionStart } }
function commit(value: TextContent, range = selection.value, key = '') {
  const normalized = renumberLists(value, range); value = normalized.content; range = normalized.selection
  const before = documentJSON(props.content), after = documentJSON(value)
  if (before === after) return
  history.value.remember(before, key); expected.value = after; error.value = ''; selection.value = range; buffer.value = value.source; emit('change', value)
  void nextTick(() => { if (input.value) { input.value.value = value.source; input.value.focus(); input.value.setSelectionRange(range.start, range.start + range.length) } })
}
function act(operation: () => TextContent | { content: TextContent; caret: number }) {
  if (locked.value) return
  try { const value = operation(); if ('content' in value) commit(value.content, { start: value.caret, length: 0 }); else commit(value) }
  catch (cause) { error.value = cause instanceof Error ? cause.message : 'Could not change text.'; void nextTick(() => input.value?.focus()) }
}
function edit(event: Event) {
  const element = event.target as HTMLTextAreaElement, value = element.value, range = { start: element.selectionStart, length: element.selectionEnd - element.selectionStart }
  buffer.value = value
  if (composing.value) return
  if (locked.value) { buffer.value = element.value = props.content.source; return }
  try { commit(replaceSource(props.content, value), range, 'typing') }
  catch (cause) { buffer.value = element.value = props.content.source; element.setSelectionRange(selection.value.start, selection.value.start + selection.value.length); error.value = cause instanceof Error ? cause.message : 'Could not change text.' }
}
function undo(backwards = true) {
  if (locked.value) return
  const value = history.value.restore(documentJSON(props.content), backwards)
  if (value) { expected.value = value; const content = parseDocumentJSON(value) as TextContent; buffer.value = content.source; emit('change', content); error.value = ''; void nextTick(() => { if (input.value) { input.value.focus(); const caret = Math.min(selection.value.start, content.source.length); input.value.setSelectionRange(caret, caret); capture() } }) }
}
function key(event: KeyboardEvent) {
  if (composing.value || event.isComposing) return
  if (event.metaKey || event.ctrlKey) {
    if (['b', 'i', 'u'].includes(event.key.toLowerCase())) { event.preventDefault(); act(() => inlineFormat(props.content, selection.value, ({ b: 'bold', i: 'italic', u: 'underline' } as const)[event.key.toLowerCase() as 'b' | 'i' | 'u'])) }
    if (['z', 'y'].includes(event.key.toLowerCase())) { event.preventDefault(); event.stopPropagation(); undo(event.key.toLowerCase() === 'z' && !event.shiftKey) }
    return
  }
  if (locked.value) return
  if (event.key === 'Tab' && currentTable.value) {
    event.preventDefault(); const table = currentTable.value, index = table.cells.findIndex(cell => selection.value.start >= cell.start && selection.value.start < cell.start + cell.length), next = table.cells[index + (event.shiftKey ? -1 : 1)]
    const caret = next?.start ?? (event.shiftKey ? table.start : table.start + table.length); input.value?.setSelectionRange(caret, caret); capture(); return
  }
  if (event.key === 'Enter' && !event.shiftKey && !currentTable.value) {
    const format = readFormatting(props.content), paragraph = format.paragraphs?.find(item => selection.value.start >= item.start && selection.value.start < item.start + item.length)
    if (paragraph?.list) {
      event.preventDefault(); const prefix = paragraph.list === 'bullet' ? '•\t' : '1.\t'
      act(() => ({ content: replaceText(props.content, selection.value, '\n' + prefix), caret: selection.value.start + prefix.length + 1 }))
    }
  }
}
function table(operation: Parameters<typeof tableChange>[2]) { act(() => tableChange(props.content, selection.value.start, operation)) }
function afterTable() { const value = currentTable.value; if (!value) return; const caret = value.start + value.length; preview.value = false; void nextTick(() => { input.value?.focus(); input.value?.setSelectionRange(caret, caret); capture() }) }
function insertVariable(name: string) { if (!name.trim() || /[{}\r\n]/.test(name)) return; const value = '{{' + name.trim() + '}}'; act(() => ({ content: replaceText(props.content, selection.value, value), caret: selection.value.start + value.length })) }
defineExpose({ focus: () => input.value?.focus() })
</script>
<template>
  <div class="notebook-text-editor" data-testid="text-editor">
    <div class="text-editor-toolbar" :aria-label="label + ' formatting'" @mousedown="($event.target as HTMLElement).closest('button') && $event.preventDefault()">
      <template v-if="!readonly"><select :value="style" :disabled="locked || preview" aria-label="Paragraph style" @change="act(() => paragraphFormat(content, selection, ($event.target as HTMLSelectElement).value as Exclude<TextStyle, 'code'>))"><option value="body">Body</option><option value="heading1">Heading 1</option><option value="heading2">Heading 2</option><option value="heading3">Heading 3</option></select>
        <button v-for="option in [{ key: 'bold', label: 'Bold', title: 'B' }, { key: 'italic', label: 'Italic', title: 'I' }, { key: 'underline', label: 'Underline', title: 'U' }, { key: 'code', label: 'Inline code', title: '&lt;/&gt;' }, { key: 'clear', label: 'Clear inline formatting', title: 'Clear' }] as const" :key="option.key" type="button" :aria-label="option.label" :disabled="locked || preview" @click="act(() => inlineFormat(content, selection, option.key))">{{ option.title }}</button>
        <button type="button" aria-label="Bullet list" :disabled="locked || preview" @click="act(() => listFormat(content, selection, 'bullet'))">• List</button><button type="button" aria-label="Numbered list" :disabled="locked || preview" @click="act(() => listFormat(content, selection, 'numbered'))">1. List</button>
        <details class="result-menu"><summary aria-label="Text table actions">Table</summary><div><button type="button" :disabled="locked || preview || !!currentTable" @click="act(() => insertTable(content, selection))">Insert 2 × 2 table</button><template v-for="item in [{ operation: 'addRow', title: 'Add table row' }, { operation: 'removeRow', title: 'Remove table row' }, { operation: 'addColumn', title: 'Add table column' }, { operation: 'removeColumn', title: 'Remove table column' }, { operation: 'remove', title: 'Remove table' }] as const" :key="item.operation"><button type="button" :disabled="locked || preview || !currentTable" @click="table(item.operation)">{{ item.title }}</button></template><button type="button" :disabled="!currentTable || preview" @click="afterTable">Continue after table</button></div></details>
        <button type="button" :disabled="locked || !history.undo.length" aria-label="Undo text edit" @click="undo()">Undo</button><button type="button" :disabled="locked || !history.redo.length" aria-label="Redo text edit" @click="undo(false)">Redo</button>
        <details class="result-menu text-variable-picker"><summary aria-label="Insert notebook variable">Variable…</summary><div><label>Variable name<input v-model="variableName" aria-label="Variable name" maxlength="128" :disabled="locked || preview" @keydown.enter.prevent="insertVariable(variableName)"></label><button type="button" :disabled="locked || preview || !variableName.trim()" @click="insertVariable(variableName)">Insert variable</button><button v-for="variable in variables || []" :key="variable.name" type="button" :disabled="locked || preview" @click="insertVariable(variable.name)">{{ variable.name }} · {{ variable.stale ? 'Stale · ' : '' }}Cell {{ variable.cellNumber }}</button><p class="source-note">Values come from names declared in saved text and an explicit run. New names need Save and Run.</p></div></details>
      </template>
      <button v-if="!readonly" type="button" :aria-pressed="preview" @click="preview = !preview">{{ preview ? 'Edit text' : 'Preview text' }}</button><span v-else class="source-note">Text preview · Read-only</span>
    </div>
    <NotebookTextPreview v-if="preview || readonly" :content="content" :label="label + ' preview'" :variables="variables" />
    <textarea v-else :id="sourceId" ref="input" :value="buffer" :aria-label="label" :rows="Math.min(24, Math.max(4, content.source.split('\n').length + 1))" :readonly="!!invalid" :disabled="disabled" spellcheck="true" @input="edit" @compositionstart="composing = true" @compositionend="composing = false; edit($event)" @select="capture" @click="capture" @keyup="capture" @keydown="key" @paste="capture" />
    <p v-if="error || invalid" class="parameter-error text-editor-note" role="alert">{{ error || invalid }}</p>
    <p class="source-note text-editor-note">Portable text · Select source text, then format it. Preview shows saved styles, lists and tables. Changes are saved with the notebook.</p>
  </div>
</template>
