<script setup lang="ts">
import NotebookParameterForm from './NotebookParameterForm.vue'
import type { CellComponent, InputDefinition, InputState } from './inputs'
import type { CellPresentation } from './execution'
import { displayKinds } from './displays'
import NotebookCellDisplay from './NotebookCellDisplay.vue'
defineProps<{ cellId: string; components: CellComponent[]; definitions: InputDefinition[]; state?: InputState; disabled: boolean; presentation: CellPresentation; onApply: (values: Record<string, string>, version: string) => Promise<boolean> }>()
const emit = defineEmits<{ dirty: [id: string, value: boolean] }>()
</script>
<template>
  <div v-if="components.length" class="cell-input-components">
    <template v-for="component in components" :key="component.id"><NotebookParameterForm v-if="component.kind === 'input' || component.kind === 'parameter_form'" :title="component.title" :definitions="definitions" :fields="component.kind === 'input' ? [{ input: component.input || '', control: component.control }] : component.fields || []" :state="state" :disabled="disabled" :on-apply="onApply" @dirty="emit('dirty', `${cellId}:${component.id}`, $event)" /><NotebookCellDisplay v-else-if="displayKinds.includes(component.kind as typeof displayKinds[number])" :component="component" :presentation="presentation" /><section v-else class="cell-unsupported-component" data-testid="unsupported-cell-component"><h3>{{ component.title || 'Component unavailable' }}</h3><p>This component is not available in the web app yet. Its saved settings are preserved. Open the desktop app to use it.</p></section></template>
  </div>
</template>
