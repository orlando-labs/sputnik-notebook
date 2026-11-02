<script setup lang="ts">
import type { BoardContext, BoardRow, BoardComponent } from './boards'
import NotebookBoardCard from './NotebookBoardCard.vue'
defineProps<{ rows: BoardRow[]; components: BoardComponent[]; context: BoardContext; depth?: number }>()
</script>
<template>
  <div class="board-grid" data-testid="board-grid">
    <div v-for="row in rows" :key="row.id" class="board-row" :class="{ 'board-row-fixed': row.height !== undefined }" :style="{ '--row-height': row.height ? row.height + 'px' : 'auto' }" :data-row="row.id">
      <NotebookBoardCard v-for="component in components.filter(item => item.kind !== 'periodic_work' && item.row === row.id)" :key="component.id" :component="component" :context="context" :depth="depth || 0" :style="{ '--component-span': component.span || 12 }" />
      <p v-if="!components.some(item => item.kind !== 'periodic_work' && item.row === row.id)" class="board-empty-row">Empty row</p>
    </div>
  </div>
</template>
