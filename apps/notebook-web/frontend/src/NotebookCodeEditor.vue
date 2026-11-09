<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'
import { sputnikTokens } from './sputnik-syntax'
import { markdownTokens } from './markdown-syntax'
import { diagnosticSelection, sourceLines, type CodeDiagnostic } from './diagnostics'
const props = defineProps<{ modelValue: string; label: string; sourceId?: string; rows?: number; readonly?: boolean; disabled?: boolean; diagnostics?: CodeDiagnostic[]; stale?: boolean; diagnosticsTruncated?: boolean; placeholder?: string; sputnik?: boolean; markdown?: boolean; maxBytes?: number; revealDiagnostic?: CodeDiagnostic }>()
const emit = defineEmits<{ 'update:modelValue': [value: string]; keydown: [event: KeyboardEvent] }>()
const rowHeight = 20, topPadding = 14
const normalize = (source: string) => source.replace(/\r\n?/g, '\n')
const input = ref<HTMLTextAreaElement>(), highlight = ref<HTMLPreElement>(), buffer = ref(normalize(props.modelValue)), composing = ref(false)
const viewport = ref({ top: 0, width: 0, height: 0 })
const error = ref('')
const lines = computed(() => sourceLines(buffer.value))
const lineCount = computed(() => lines.value.starts.length)
const sizeBounded = computed(() => buffer.value.length <= 262144 && lineCount.value <= 4000)
const highlighting = computed(() => props.markdown || props.sputnik !== false)
const tokens = computed<{ start: number; end: number; kind: string; limited?: boolean }[]>(() =>
  sizeBounded.value && highlighting.value ? (props.markdown ? markdownTokens(buffer.value) : sputnikTokens(buffer.value)) : [])
const bounded = computed(() => sizeBounded.value && tokens.value.length <= 20000 && !tokens.value.some(token => token.limited))
const annotations = computed(() => {
  if (props.stale || composing.value || buffer.value !== normalize(props.modelValue)) return []
  return (props.diagnostics || []).flatMap(({ range }) => {
    if (!range) return []
    const selection = diagnosticSelection(buffer.value, range, lines.value)
    return selection ? [{ range, selection }] : []
  })
})
const visibleRows = computed(() => {
  const first = Math.max(0, Math.floor((viewport.value.top - topPadding) / rowHeight))
  const end = Math.min(lineCount.value, Math.ceil((viewport.value.top + viewport.value.height) / rowHeight))
  return Array.from({ length: Math.max(0, end - first) }, (_, index) => {
    const row = first + index
    return {
      number: row + 1,
      top: topPadding + row * rowHeight - viewport.value.top,
      error: annotations.value.some(({ range }) => {
        const last = range.whole_line || range.end_column > 0 ? range.end_line : Math.max(range.start_line, range.end_line - 1)
        return range.start_line <= row && row <= last
      }),
    }
  })
})
const errorSelections = computed(() => annotations.value.filter(({ range, selection }) => !range.whole_line && selection.start < selection.end).map(({ selection }) => selection))
const paintText = computed(() => (bounded.value && highlighting.value) || errorSelections.value.length > 0)
const segments = computed(() => {
  if (!paintText.value) return []
  const points = [...new Set(errorSelections.value.flatMap(({ start, end }) => [start, end]))].sort((a, b) => a - b)
  const result: { text: string; kind: string; error: boolean }[] = []
  const parts = bounded.value && highlighting.value ? tokens.value : [{ start: 0, end: buffer.value.length, kind: 'plain' }]
  let boundary = 0
  for (const token of parts) {
    let at = token.start
    while (points[boundary] !== undefined && points[boundary]! <= at) boundary++
    while (at < token.end) {
      const end = Math.min(token.end, points[boundary] ?? token.end)
      result.push({ text: buffer.value.slice(at, end), kind: token.kind, error: errorSelections.value.some(selection => selection.start < end && selection.end > at) })
      at = end
      if (points[boundary] === end) boundary++
    }
  }
  return result
})
watch(() => props.modelValue, value => { if (!composing.value) buffer.value = normalize(value) })
watch([buffer, paintText], () => { void nextTick(syncScroll) })
let resize: ResizeObserver
onMounted(() => {
  resize = new ResizeObserver(syncScroll)
  if (input.value) resize.observe(input.value)
  syncScroll()
})
onUnmounted(() => resize?.disconnect())
function syncScroll() {
  if (!input.value) return
  const { scrollTop, scrollLeft, clientWidth, clientHeight } = input.value
  if (viewport.value.top !== scrollTop || viewport.value.width !== clientWidth || viewport.value.height !== clientHeight) {
    viewport.value = { top: scrollTop, width: clientWidth, height: clientHeight }
    void nextTick(syncHighlight)
  }
  syncHighlight()
  function syncHighlight() {
    if (!highlight.value || !input.value) return
    highlight.value.scrollTop = input.value.scrollTop
    highlight.value.scrollLeft = input.value.scrollLeft
  }
}
function edit(event: Event) {
  const target = event.target as HTMLTextAreaElement; buffer.value = target.value
  if (composing.value) return
  if (props.maxBytes && new TextEncoder().encode(buffer.value).length > props.maxBytes) { error.value = 'Text files are limited to 1 MiB.'; target.value = buffer.value = props.modelValue; return }
  if (!props.disabled && !props.readonly) { error.value = ''; emit('update:modelValue', buffer.value) }
  void nextTick(syncScroll)
}
function key(event: KeyboardEvent) {
  emit('keydown', event)
  if (event.defaultPrevented || event.isComposing || composing.value || props.readonly || props.disabled) return
  if (event.key === 'Tab' && !event.shiftKey && !event.ctrlKey && !event.metaKey && !event.altKey && input.value) {
    event.preventDefault(); const target = input.value, at = target.selectionStart
    target.setRangeText('  ', at, target.selectionEnd, 'end'); edit({ target } as unknown as Event)
  }
}
function go(diagnostic: CodeDiagnostic) {
  if (props.stale || composing.value || buffer.value !== normalize(props.modelValue)) return
  const selection = diagnosticSelection(buffer.value, diagnostic.range, lines.value)
  if (!selection || !input.value) return
  input.value.focus({ preventScroll: true }); input.value.setSelectionRange(selection.start, selection.end)
  const row = diagnostic.range!.start_line; input.value.scrollTop = Math.max(0, topPadding + row * rowHeight - input.value.clientHeight / 2); syncScroll()
  void nextTick(() => {
    const line = input.value?.parentElement?.querySelector<HTMLElement>(`[data-error-line="${row + 1}"]`)
    line?.scrollIntoView({ block: 'center' })
  })
}
watch(() => props.revealDiagnostic, diagnostic => { if (diagnostic) void nextTick(() => go(diagnostic)) })
defineExpose({ focus: () => input.value?.focus() })
</script>
<template>
  <div class="sputnik-editor-host">
    <div class="sputnik-code-editor" :class="{ 'syntax-plain': !paintText }" data-testid="sputnik-editor">
      <div class="code-gutter" :style="{ '--line-digits': Math.max(3, String(lineCount).length) }" aria-hidden="true">
        <span v-for="row in visibleRows" :key="row.number" :class="{ 'code-line-error': row.error }" :style="{ top: row.top + 'px' }">{{ row.number }}</span>
      </div>
      <div class="code-editor-surface">
        <div v-if="annotations.length" class="code-error-lines" :style="{ height: viewport.height + 'px' }" aria-hidden="true">
          <div v-for="row in visibleRows.filter(row => row.error)" :key="row.number" class="code-line-error" :data-error-line="row.number" :style="{ top: row.top + 'px' }" />
        </div>
        <pre v-if="paintText" ref="highlight" class="code-highlight" :style="{ width: viewport.width + 'px', height: viewport.height + 'px' }" aria-hidden="true"><span v-for="(segment, index) in segments" :key="index" :class="['syntax-' + segment.kind, { 'code-error-range': segment.error }]">{{ segment.text }}</span>{{ buffer.endsWith('\n') ? ' ' : '' }}</pre>
        <textarea :id="sourceId" ref="input" class="code-input" :value="buffer" :aria-label="label" :rows="rows || Math.min(24, Math.max(3, lineCount + 1))" :readonly="readonly" :disabled="disabled" :placeholder="placeholder" spellcheck="false" autocapitalize="off" autocomplete="off" autocorrect="off" wrap="off" @input="edit" @scroll="syncScroll" @keydown="key" @compositionstart="composing = true" @compositionend="composing = false; edit($event)" />
      </div>
    </div>
    <p v-if="!bounded" class="source-note code-editor-notice">Syntax preview is limited to 256 Ki UTF-16 units, 4000 lines and 20000 tokens. Complete source remains editable and is saved intact.</p>
    <p v-if="error" class="source-error code-editor-notice" role="alert">{{ error }}</p>
    <div v-if="diagnostics?.length" class="code-diagnostics" :aria-label="label + ' diagnostics'" data-testid="code-diagnostics"><p v-if="stale" class="source-note">Previous diagnostics · source or worker changed</p><ul><li v-for="(diagnostic, index) in diagnostics" :key="index"><button type="button" class="plain text-button" :disabled="stale || composing || !diagnosticSelection(buffer, diagnostic.range, lines)" @click="go(diagnostic)"><span v-if="diagnostic.range">Line {{ diagnostic.range.start_line + 1 }}, column {{ diagnostic.range.start_column + 1 }} · </span>{{ diagnostic.message }}{{ diagnostic.truncated ? '…' : '' }}</button></li></ul><p v-if="diagnosticsTruncated" class="source-note">Only the first 100 diagnostics are shown.</p></div>
  </div>
</template>
