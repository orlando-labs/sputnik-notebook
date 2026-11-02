<script setup lang="ts">
import { computed, ref } from 'vue'
import type { BoardContext } from './boards'
import { taskDepth } from './runtime-observation'
import { duration } from './telemetry'
const props = defineProps<{ context: BoardContext }>()
const errorsOnly = ref(false)
const telemetry = computed(() => props.context.observation?.result?.task_telemetry)
const tasks = computed(() => (telemetry.value?.tasks || []).filter(task => !errorsOnly.value || task.state === 'failed'))
function sourceLabel(id: string) { return 'Cell ' + ((props.context.sheet?.cells.findIndex(cell => cell.id === id) ?? -1) + 1) }
</script>
<template>
  <div class="task-monitor">
    <template v-if="telemetry">
      <div class="observation-controls"><span>{{ telemetry.active }} active · {{ telemetry.total }} registered</span><label><input v-model="errorsOnly" type="checkbox">Errors only</label></div>
      <div class="task-list" aria-label="Tasks">
        <article v-for="task in tasks" :key="task.id" class="runtime-task" :class="{ 'task-failed': task.state === 'failed' }" :style="{ '--task-depth': taskDepth(task, telemetry.tasks) }">
          <p>Task {{ telemetry.tasks.findIndex(item => item.id === task.id) + 1 }} · {{ task.state }} <span>{{ duration(task.elapsed_ms) }}</span></p>
          <pre v-if="task.error">{{ task.error }}</pre>
          <button v-if="task.cell && context.sheet?.cells.some(cell => cell.id === task.cell)" class="plain" @click="context.onOpenSource?.(task.cell)">{{ sourceLabel(task.cell) }} · line {{ task.line }}</button>
        </article>
        <p v-if="!tasks.length" class="source-note">{{ errorsOnly ? 'No failed tasks' : 'No child tasks registered' }}</p>
      </div>
      <p v-if="telemetry.dropped !== '0'" class="rich-stale-note">{{ telemetry.dropped }} earlier task records omitted · bounded to 512 records</p>
      <p class="source-note">{{ telemetry.cpu_percent == null ? 'CPU unavailable' : 'CPU ' + telemetry.cpu_percent.toFixed(1) + '%' }} · {{ telemetry.resident_bytes == null ? 'Memory unavailable' : telemetry.resident_bytes + ' bytes resident' }}</p>
      <p v-if="context.observation?.stale || !context.observation?.connected" class="rich-stale-note">Previous telemetry · stale</p>
    </template>
    <p v-else class="rich-unavailable">Run the sheet to inspect child tasks. No task telemetry loaded.</p>
  </div>
</template>
