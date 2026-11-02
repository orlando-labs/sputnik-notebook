<script setup lang="ts">
import { computed } from 'vue'
import { textBlocks, formattingError, type TextContent } from './rich-text'
import { interpolateInline, type TextVariable } from './text-variables'
const props = defineProps<{ content: TextContent; label?: string; variables?: TextVariable[] }>()
const error = computed(() => formattingError(props.content))
const tooLarge = computed(() => props.content.source.length > 262144 || props.content.source.split('\n').length > 4000)
const rendered = computed(() => {
  try {
    const budget = { remaining: 262144, tokens: 4096 }
    const blocks = !error.value && !tooLarge.value ? textBlocks(props.content).map(block => block.kind === 'table' ? { ...block, rows: block.rows.map(row => row.map(cell => interpolateInline(cell, props.variables || [], budget))) } : { ...block, spans: interpolateInline(block.spans, props.variables || [], budget) }) : []
    return { blocks, error: '' }
  } catch (cause) { return { blocks: [], error: (cause as Error).message } }
})
</script>
<template>
  <div class="notebook-text-preview" :aria-label="label || 'Text preview'" data-testid="text-preview">
    <template v-if="error || tooLarge || rendered.error"><p class="source-note" role="status">{{ error || rendered.error || 'Formatted preview is limited to 256 Ki UTF-16 units and 4000 lines. The complete source remains editable and is saved intact.' }}</p><pre class="text-fallback">{{ content.source.slice(0, 262144) }}</pre></template>
    <template v-else><template v-for="(block, index) in rendered.blocks" :key="index">
      <div v-if="block.kind === 'table'" class="text-table-scroll"><table class="text-table"><tbody><tr v-for="(row, r) in block.rows" :key="r"><td v-for="(cell, c) in row" :key="c"><span v-for="(span, s) in cell" :key="s" :title="span.variable" :class="['text-style-' + span.style, span.state ? 'text-variable-' + span.state : '', { 'text-bold': span.bold, 'text-italic': span.italic, 'text-underline': span.underline }]">{{ span.text }}</span></td></tr></tbody></table></div>
      <p v-else :class="['text-paragraph', 'text-paragraph-' + block.style, { 'text-list': block.list }]" :role="block.style.startsWith('heading') ? 'heading' : undefined" :aria-level="block.style.startsWith('heading') ? Number(block.style.slice(-1)) : undefined"><span v-for="(span, s) in block.spans" :key="s" :title="span.variable" :class="['text-style-' + span.style, span.state ? 'text-variable-' + span.state : '', { 'text-bold': span.bold, 'text-italic': span.italic, 'text-underline': span.underline }]">{{ span.text }}</span><br v-if="!block.spans.length"></p>
    </template><p v-if="!content.source" class="source-note">Empty text</p></template>
  </div>
</template>
