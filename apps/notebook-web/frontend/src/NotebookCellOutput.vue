<script setup lang="ts">
import NotebookRichOutput from './NotebookRichOutput.vue'
import NotebookTelemetry from './NotebookTelemetry.vue'
import { computed } from 'vue'
import type { CellPresentation } from './execution'
import type { CellComponent } from './inputs'
import { automaticRich } from './displays'
import type { CodeDiagnostic } from './diagnostics'
const props = defineProps<{ presentation: CellPresentation; components?: CellComponent[] }>()
const emit = defineEmits<{ revealError: [diagnostic: CodeDiagnostic] }>()
const diagnostics = computed(() => props.presentation.diagnostics || [])
const automatic = computed(() => automaticRich(props.presentation.rich, props.components || []))
</script>

<template>
  <div class="cell-presentation" :class="{ 'previous-result': presentation.stale }" data-testid="cell-presentation">
    <div v-if="presentation.running || presentation.stale" class="cell-result-status">
      <span v-if="presentation.running" class="cell-running"><span class="running-dot"></span>Running</span>
      <span v-if="presentation.stale">Previous result · source or worker changed</span>
    </div>
    <pre v-if="presentation.output.length" class="cell-console" aria-label="Cell output"><span v-for="(chunk, index) in presentation.output" :key="index" :class="{ 'stderr-output': chunk.stream === 'stderr' }">{{ chunk.text }}</span></pre>
    <pre v-if="presentation.error || diagnostics.length" class="cell-output-error" aria-label="Cell error"><template v-if="diagnostics.length"><template v-for="(diagnostic, index) in diagnostics" :key="index">{{ index ? '\n' : '' }}<button v-if="diagnostic.range && !(presentation.diagnostics_stale ?? presentation.stale)" type="button" class="plain text-button" @click="emit('revealError', diagnostic)">{{ diagnostic.message }}{{ diagnostic.truncated ? '…' : '' }}</button><template v-else>{{ diagnostic.message }}{{ diagnostic.truncated ? '…' : '' }}</template></template></template><template v-else>{{ presentation.error }}</template></pre>
    <NotebookTelemetry :rich="automatic" :identity="presentation.identity" :active="presentation.active" />
    <NotebookRichOutput :rich="automatic" :identity="presentation.identity" />
    <details v-if="presentation.result && presentation.rich.table" class="result-text"><summary>Text result</summary><pre class="cell-value" aria-label="Cell result">{{ presentation.result }}</pre></details>
    <pre v-else-if="presentation.result" class="cell-value" aria-label="Cell result">{{ presentation.result }}</pre>
    <div v-if="!presentation.result && !presentation.error && !diagnostics.length && !presentation.output.length && !presentation.running && !presentation.rich.table && !presentation.rich.displays.length && !presentation.rich.images.length && !presentation.rich.audio?.length && !presentation.rich.audio_limited && !presentation.rich.progress.length && !presentation.rich.stopwatches.length && !presentation.rich.charts.length && !presentation.rich.rich_unsupported && presentation.rich.elapsed_ms === null" class="cell-result-empty">No output loaded</div>
  </div>
</template>
