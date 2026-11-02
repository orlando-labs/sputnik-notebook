<script setup lang="ts">
import { computed } from 'vue'
import type { RunResult, RunSummary } from './execution'
import { runLabel } from './execution'
import { invocationPresentation } from './board-execution'
import NotebookCellOutput from './NotebookCellOutput.vue'
const props = defineProps<{ run: RunSummary; result?: RunResult; stale: boolean }>()
defineEmits<{ close: [] }>()
const presentation = computed(() => invocationPresentation(props.run, props.result, props.stale))
</script>
<template>
  <section class="invocation-result" aria-label="Invocation result" data-testid="invocation-result">
    <header><div><h3>{{ run.action === 'periodic_run' ? 'Service invocation' : 'Action invocation' }} · {{ run.component_id }}</h3><p class="source-note">{{ runLabel(run.state) }} · Run {{ run.id.slice(0, 8) }} · revision {{ run.revision.slice(0, 8) }}</p></div><button @click="$emit('close')">Close output</button></header>
    <p v-if="result?.error || result?.environment_error || result?.rich_error" class="parameter-error" role="alert">{{ result.error || result.environment_error || result.rich_error }}</p>
    <pre v-for="(error, index) in result?.task_errors || []" :key="index" class="parameter-error">{{ error }}</pre>
    <NotebookCellOutput v-if="result" :presentation="presentation" /><p v-else class="source-note" role="status">Loading invocation output…</p>
  </section>
</template>
