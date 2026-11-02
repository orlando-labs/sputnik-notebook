<script setup lang="ts">
import { computed } from 'vue'
import type { BoardComponent, BoardContext } from './boards'
import { targetStatus } from './runtime-observation'
import { referenceID } from './boards'
import { duration } from './telemetry'
const props = defineProps<{ component: BoardComponent; context: BoardContext }>()
const state = computed(() => targetStatus({ ...props.component, cell: referenceID(props.component.cell) || undefined }, props.context))
const target = computed(() => props.context.runtime?.components.find(item => item.id === props.component.p1?.target_component))
const resources = computed(() => props.context.observation?.resources)
</script>
<template>
  <div class="board-status" :class="{ 'status-failed': state.failed, 'status-stale': state.stale }">
    <p role="status"><strong>{{ state.title }}</strong></p><p class="status-detail">{{ state.detail }}</p>
    <p v-if="component.p1?.target_kind === 'runtime' && resources" class="source-note">Execution: {{ duration(resources.spent_ms) }} used<span v-if="resources.remaining_ms != null"> · {{ duration(resources.remaining_ms) }} remaining</span><span v-if="resources.effective.run_seconds != null"> · One run: {{ resources.effective.run_seconds }} s</span></p>
    <button v-if="component.p1?.target_kind !== 'runtime' && context.onOpenSource" :disabled="state.title === 'Unavailable'" @click="context.onOpenSource?.(referenceID(component.cell) || undefined, target?.module_id)">Open source</button>
    <p v-if="state.stale" class="rich-stale-note">Previous state · stale</p>
  </div>
</template>
