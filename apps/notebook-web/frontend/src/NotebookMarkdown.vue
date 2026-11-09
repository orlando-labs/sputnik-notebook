<script setup lang="ts">
import { computed, defineComponent, h, ref, shallowRef, type VNodeChild } from 'vue'
import { markdownNodes, type MarkdownNode } from './markdown'
import type { TextVariable } from './text-variables'
const props = defineProps<{ source: string; variables?: TextVariable[]; label?: string; document?: boolean }>()
const math = shallowRef<typeof import('./markdown-math')>()
const loadError = ref('')
if (props.document) void import('./markdown-math').then(value => { math.value = value }).catch(() => { loadError.value = 'Could not load Markdown preview.' })
const content = computed(() => {
  try { return { nodes: markdownNodes(props.source, props.variables, math.value?.documentParser), error: loadError.value } }
  catch (cause) { return { nodes: [], error: (cause as Error).message } }
})
function render(node: MarkdownNode): VNodeChild {
  if (node.formula && math.value) return h(math.value.Formula, node.formula)
  if (!node.tag) return node.text || ''
  const element = h(node.tag, node.attrs || {}, node.children ? node.children.map(render) : node.text)
  return props.document && node.tag === 'table' ? h('div', { class: 'markdown-table-scroll' }, [element]) : element
}
const Preview = defineComponent(() => () => content.value.nodes.map(render))
</script>
<template>
  <div class="notebook-markdown" :class="{ 'notebook-markdown-document': document }" :aria-label="label || 'Markdown preview'" data-testid="markdown-preview"><template v-if="content.error"><p class="source-note" role="status">{{ content.error }}</p><pre class="text-fallback">{{ source.slice(0, 262144) }}</pre></template><p v-else-if="document && !math" class="source-note" role="status">Loading Markdown preview…</p><Preview v-else /></div>
</template>
