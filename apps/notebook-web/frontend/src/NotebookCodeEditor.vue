<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import { sputnikTokens } from './sputnik-syntax'
import { diagnosticSelection, type CodeDiagnostic } from './diagnostics'
const props = defineProps<{ modelValue: string; label: string; sourceId?: string; rows?: number; readonly?: boolean; disabled?: boolean; diagnostics?: CodeDiagnostic[]; stale?: boolean; diagnosticsTruncated?: boolean; placeholder?: string; sputnik?: boolean; maxBytes?: number }>()
const emit = defineEmits<{ 'update:modelValue': [value: string]; keydown: [event: KeyboardEvent] }>()
const input = ref<HTMLTextAreaElement>(), highlight = ref<HTMLPreElement>(), gutter = ref<HTMLDivElement>(), buffer = ref(props.modelValue), composing = ref(false)
const error = ref('')
const sizeBounded = computed(() => buffer.value.length <= 262144 && buffer.value.split(/\r\n|[\r\n]/).length <= 4000)
const tokens = computed(() => sizeBounded.value && props.sputnik !== false ? sputnikTokens(buffer.value) : [])
const bounded = computed(() => sizeBounded.value && !tokens.value.some(token => token.limited))
const lines = computed(() => bounded.value ? buffer.value.split(/\r\n|[\r\n]/).length : 0)
const annotations = computed(() => bounded.value && !props.stale && buffer.value === props.modelValue ? (props.diagnostics || []).map((diagnostic, index) => ({ index, diagnostic, selection: diagnosticSelection(buffer.value, diagnostic.range) })).filter(item => item.selection !== null) : [])
const segments = computed(() => {
  if (!bounded.value || props.sputnik === false) return []
  const points = [...new Set(annotations.value.flatMap(item => [item.selection!.start, item.selection!.end]))].sort((a, b) => a - b)
  const result: { text: string; kind: string; error: boolean }[] = []; let boundary = 0
  for (const token of tokens.value) {
    let at = token.start
    while (points[boundary] !== undefined && points[boundary]! <= at) boundary++
    while (at < token.end) { const end = Math.min(token.end, points[boundary] ?? token.end); result.push({ text: buffer.value.slice(at, end), kind: token.kind, error: annotations.value.some(item => item.selection!.start < end && item.selection!.end > at) }); at = end; if (points[boundary] === end) boundary++ }
  }
  return result
})
watch(() => props.modelValue, value => { if (!composing.value && value !== buffer.value) buffer.value = value; void nextTick(syncScroll) })
function syncScroll() { if (input.value && highlight.value) { highlight.value.scrollTop = input.value.scrollTop; highlight.value.scrollLeft = input.value.scrollLeft } if (input.value && gutter.value) gutter.value.style.transform = `translateY(${-input.value.scrollTop}px)` }
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
  if (props.stale) return
  const selection = diagnosticSelection(buffer.value, diagnostic.range)
  if (!selection || !input.value) return
  input.value.focus(); input.value.setSelectionRange(selection.start, selection.end)
  const row = diagnostic.range!.start_line; input.value.scrollTop = Math.max(0, row * 20 - input.value.clientHeight / 2); syncScroll()
}
defineExpose({ focus: () => input.value?.focus() })
</script>
<template>
  <div class="sputnik-editor-host">
    <div class="sputnik-code-editor" :class="{ 'syntax-plain': !bounded || sputnik === false }" data-testid="sputnik-editor">
      <div v-if="bounded" class="code-gutter" aria-hidden="true"><div ref="gutter"><span v-for="line in lines" :key="line" :class="{ 'code-line-error': annotations.some(item => item.diagnostic.range!.start_line <= line - 1 && item.diagnostic.range!.end_line >= line - 1) }">{{ line }}</span></div></div>
      <div class="code-editor-surface"><pre v-if="bounded && sputnik !== false" ref="highlight" class="code-highlight" aria-hidden="true"><span v-for="(segment, index) in segments" :key="index" :class="['syntax-' + segment.kind, { 'code-error-range': segment.error }]">{{ segment.text }}</span>{{ buffer.endsWith('\n') ? ' ' : '' }}</pre><textarea :id="sourceId" ref="input" class="code-input" :value="buffer" :aria-label="label" :rows="rows || Math.min(24, Math.max(3, buffer.split('\n').length + 1))" :readonly="readonly" :disabled="disabled" :placeholder="placeholder" spellcheck="false" autocapitalize="off" autocomplete="off" autocorrect="off" wrap="off" @input="edit" @scroll="syncScroll" @keydown="key" @compositionstart="composing = true" @compositionend="composing = false; edit($event)" /></div>
    </div>
    <p v-if="!bounded" class="source-note code-editor-notice">Syntax preview is limited to 256 Ki UTF-16 units, 4000 lines and 20000 tokens. Complete source remains editable and is saved intact.</p>
    <p v-if="error" class="source-error code-editor-notice" role="alert">{{ error }}</p>
    <div v-if="diagnostics?.length" class="code-diagnostics" :aria-label="label + ' diagnostics'" data-testid="code-diagnostics"><p v-if="stale" class="source-note">Previous diagnostics · source or worker changed</p><ul><li v-for="(diagnostic, index) in diagnostics" :key="index"><button type="button" class="plain text-button" :disabled="stale || !diagnostic.range" @click="go(diagnostic)"><span v-if="diagnostic.range">Line {{ diagnostic.range.start_line + 1 }}, column {{ diagnostic.range.start_column + 1 }} · </span>{{ diagnostic.message }}{{ diagnostic.truncated ? '…' : '' }}</button></li></ul><p v-if="diagnosticsTruncated" class="source-note">Only the first 100 diagnostics are shown.</p></div>
  </div>
</template>
