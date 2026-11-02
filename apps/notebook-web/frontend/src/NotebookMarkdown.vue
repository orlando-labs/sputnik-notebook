<script setup lang="ts">
import { computed, defineComponent, h, type VNodeChild } from 'vue'
import { markdownNodes, type MarkdownNode } from './markdown'
import type { TextVariable } from './text-variables'
const props = defineProps<{ source: string; variables?: TextVariable[]; label?: string }>()
const content = computed(() => { try { return { nodes: markdownNodes(props.source, props.variables), error: '' } } catch (cause) { return { nodes: [], error: (cause as Error).message } } })
function render(node: MarkdownNode): VNodeChild { return node.tag ? h(node.tag, node.attrs || {}, node.children ? node.children.map(render) : node.text) : node.text || '' }
const Preview = defineComponent(() => () => content.value.nodes.map(render))
</script>
<template>
  <div class="notebook-markdown" :aria-label="label || 'Markdown preview'" data-testid="markdown-preview"><template v-if="content.error"><p class="source-note" role="status">{{ content.error }}</p><pre class="text-fallback">{{ source.slice(0, 262144) }}</pre></template><Preview v-else /></div>
</template>
