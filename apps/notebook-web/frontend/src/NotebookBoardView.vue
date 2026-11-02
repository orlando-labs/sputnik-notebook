<script setup lang="ts">
import { computed } from 'vue'
import { boardLayout, type NotebookBoard, type BoardContext } from './boards'
import NotebookBoardGrid from './NotebookBoardGrid.vue'
import NotebookBoardCommand from './NotebookBoardCommand.vue'
defineEmits<{ openSheet: []; design: []; duplicate: []; remove: [] }>()
const props = defineProps<{ board: NotebookBoard; context: BoardContext; canDesign?: boolean; designDisabled?: boolean; passive?: boolean }>()
const layout = computed(() => boardLayout(props.board))
const services = computed(() => props.board.components.filter(item => item.kind === 'periodic_work'))
</script>
<template>
  <section class="notebook-board" aria-label="Notebook board" data-testid="notebook-board">
    <header class="board-heading"><div><h2>{{ board.title }}</h2><p>Controller sheet: {{ context.sheet?.title || board.sheet }}</p></div><div class="board-inspector-actions"><button v-if="canDesign" :disabled="designDisabled" :aria-label="`Design board ${board.title}`" @click="$emit('design')">Design…</button><details v-if="canDesign" class="result-menu"><summary aria-label="Board actions">Actions</summary><div><button :disabled="designDisabled" @click="$emit('duplicate')">Duplicate board…</button><button :disabled="designDisabled" @click="$emit('remove')">Delete board…</button></div></details><button :disabled="passive || !context.sheet" @click="$emit('openSheet')">Open Sheet</button></div></header>
    <p v-if="!context.sheet" class="execution-note" role="status">Controller sheet unavailable</p>
    <template v-else><NotebookBoardGrid v-if="board.components.some(item => item.kind !== 'periodic_work')" :rows="layout.rows" :components="layout.components" :context="context" /><p v-else class="board-empty">An empty canvas</p></template>
    <section v-if="services.length" class="board-services" aria-label="Services"><h3>Services</h3><article v-for="service in services" :key="service.id" class="board-service" :aria-label="service.title"><NotebookBoardCommand :component="service" :context="context" /></article></section>
  </section>
</template>
