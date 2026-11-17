<script setup lang="ts">
import { computed, ref, shallowRef, watch } from 'vue'
import { api } from './api'
import { boardLayout, type BoardComponent, type BoardContext } from './boards'
import { parseNotebook, type NotebookDocument } from './notebook'
import NotebookBoardGrid from './NotebookBoardGrid.vue'
import { packageColor } from './package-components'

const props = defineProps<{ component: BoardComponent; context: BoardContext }>()
const document = shallowRef<NotebookDocument>()
const message = ref('')
const open = ref(false)
const reference = computed(() => props.component.package_component)
const board = computed(() => document.value?.boards?.[0])
const layout = computed(() => board.value && boardLayout(board.value))
const child = computed<BoardContext>(() => ({
  projectId: props.context.projectId,
  packageDepth: (props.context.packageDepth || 0) + 1,
  sheet: document.value?.sheets.find(sheet => sheet.id === board.value?.sheet),
  definitions: document.value?.inputs || [],
  presentations: {},
  disabled: true,
  canRun: false,
  canExecute: false,
  identity: `${props.context.identity}:package:${props.component.id}`,
  onApply: async () => false,
  onDirty: () => {},
  onRun: () => {},
}))

watch(() => [open.value, props.context.projectId, reference.value?.provider, reference.value?.type, reference.value?.enabled] as const,
  async ([expanded, project, provider, type, enabled], _, cleanup) => {
    const controller = new AbortController()
    cleanup(() => controller.abort())
    document.value = undefined
    if (!expanded) return
    if (enabled === false) { message.value = 'This embedded board is disabled.'; return }
    if (!project || !provider || !type) { message.value = 'This embedded board is unavailable in this workspace.'; return }
    if (child.value.packageDepth! > 8) { message.value = 'The embedded board nesting limit has been reached.'; return }
    message.value = 'Loading embedded board…'
    try {
      const params = new URLSearchParams({ provider, type })
      const result = await api<{ document: string }>(`/api/projects/${encodeURIComponent(project)}/dependencies/board?${params}`, 'GET', undefined, controller.signal)
      if (controller.signal.aborted) return
      const loaded = parseNotebook({ revision: '0'.repeat(64), document: result.document })
      if (!loaded.boards?.[0] || !Array.isArray(loaded.boards[0].components)) throw new Error('Invalid embedded board.')
      document.value = loaded
      message.value = ''
    } catch {
      if (!controller.signal.aborted) message.value = 'Could not load the embedded board. Check Dependencies for its package.'
    }
  })
</script>

<template>
  <details class="package-subboard" :style="packageColor(reference?.provider || '')" @toggle="open = ($event.currentTarget as HTMLDetailsElement).open">
    <summary><strong>{{ component.title }}</strong><span>{{ reference?.provider }}</span></summary>
    <p v-if="message" class="source-note" role="status">{{ message }}</p>
    <NotebookBoardGrid v-if="layout" :rows="layout.rows" :components="layout.components" :context="child" />
    <p v-if="board?.components.some(item => item.kind === 'package_service')" class="source-note">Package services require a local Notebook runtime.</p>
  </details>
</template>
