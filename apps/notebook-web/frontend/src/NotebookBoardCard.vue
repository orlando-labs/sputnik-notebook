<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { boardPresentation, referenceID, type BoardComponent, type BoardContext } from './boards'
import { displayKinds } from './displays'
import NotebookBoardGrid from './NotebookBoardGrid.vue'
import NotebookCellDisplay from './NotebookCellDisplay.vue'
import NotebookParameterForm from './NotebookParameterForm.vue'
import NotebookRichOutput from './NotebookRichOutput.vue'
import NotebookTelemetry from './NotebookTelemetry.vue'
import { emptyPresentation } from './boards'
import NotebookBoardCommand from './NotebookBoardCommand.vue'
import NotebookTextPreview from './NotebookTextPreview.vue'
import NotebookMarkdown from './NotebookMarkdown.vue'
import NotebookMediaInput from './NotebookMediaInput.vue'
import NotebookAudioAnnotator from './NotebookAudioAnnotator.vue'
import NotebookDateInput from './NotebookDateInput.vue'
import NotebookParameterPresets from './NotebookParameterPresets.vue'
import NotebookSharedTable from './NotebookSharedTable.vue'
import { selectionOwner } from './shared-selection'
import { variableDisplay } from './text-variables'
import NotebookStatus from './NotebookStatus.vue'
import NotebookTaskMonitor from './NotebookTaskMonitor.vue'
import NotebookArtifacts from './NotebookArtifacts.vue'
import NotebookResultInspector from './NotebookResultInspector.vue'
import NotebookLogViewer from './NotebookLogViewer.vue'
const props = defineProps<{ component: BoardComponent; context: BoardContext; depth: number }>()
const presentation = computed(() => boardPresentation(props.component, props.context))
const source = computed(() => props.context.sheet?.cells.find(cell => cell.id === referenceID(props.component.cell) && cell.kind === 'code'))
const selected = ref(props.component.panels?.[0]?.id || '')
const expanded = ref(props.component.p1?.collapsed !== true)
const split = ref(props.component.split_fraction ?? .5)
const splitContainer = ref<HTMLElement | null>(null), splitWidth = ref(0)
let splitObserver: ResizeObserver | undefined
const splitLength = computed(() => props.component.split_axis === 'vertical' ? 408 : Math.max(0, splitWidth.value - 12))
const splitMinimum = computed(() => props.component.split_min || 120)
const splitStacked = computed(() => splitLength.value < splitMinimum.value * 2)
const splitRatio = computed(() => splitStacked.value ? .5 : Math.max(splitMinimum.value / splitLength.value, Math.min(1 - splitMinimum.value / splitLength.value, split.value)))
onMounted(() => {
  if (splitContainer.value) { splitObserver = new ResizeObserver(entries => { splitWidth.value = entries[0]?.contentRect.width || 0 }); splitObserver.observe(splitContainer.value) }
})
onUnmounted(() => splitObserver?.disconnect())
const panelPrefix = 'board-panel-' + crypto.randomUUID()
watch(() => props.component.panels?.map(panel => panel.id).join('\0'), () => { if (!props.component.panels?.some(panel => panel.id === selected.value)) selected.value = props.component.panels?.[0]?.id || '' })
const effectiveComponent = computed(() => props.component.kind === 'image_carousel' ? { ...props.component, kind: 'image', image_allow_save: props.component.image_allow_save === true } : props.component.kind === 'image' ? { ...props.component, image_allow_save: props.component.image_allow_save === true } : props.component)
const isDisplay = computed(() => displayKinds.includes(effectiveComponent.value.kind as typeof displayKinds[number]))
const missingSource = computed(() => ['metric', 'table', 'result', 'progress', 'plot', 'log', 'artifacts', 'text', 'run', 'audio'].includes(props.component.kind) && !source.value)
const controlFields = computed(() => props.component.kind === 'parameter_form' ? props.component.fields || [] : [{ input: props.component.input || '', control: props.component.control }])
const scopedRich = computed(() => {
  const rich = { ...emptyPresentation().rich }, value = presentation.value.rich
  rich.rich_stale = value.rich_stale; rich.telemetry_stale = value.telemetry_stale
  if (props.component.kind === 'progress') rich.progress = value.progress.filter(item => !props.component.progress_id || item.id === props.component.progress_id)
  if (props.component.kind === 'stopwatch') rich.stopwatches = value.stopwatches
  if (props.component.kind === 'plot') rich.displays = value.displays.filter(item => !item.table)
  return rich
})
const hasTelemetry = computed(() => scopedRich.value.progress.length || scopedRich.value.stopwatches.length)
const boundAsset = computed(() => { if (!props.component.selection_id) return undefined; const value = selectionOwner(props.context.components || [], String(props.component.selection_id)); const asset = value?.row[String(props.component.selection_asset || 'asset_id')]; return typeof asset === 'string' && /^[a-f0-9]{64}$/.test(asset) ? asset : null })
const boundText = computed(() => {
  const name = props.component.binding || '', local = presentation.value.text_values?.find(item => item.name === name)
  return variableDisplay(name, local ? { ...local, cellID: referenceID(props.component.cell), cellNumber: 0, stale: presentation.value.stale || !presentation.value.ok } : undefined)
})
function tabKey(event: KeyboardEvent, index: number) {
  const panels = props.component.panels || []
  let next = index
  if (event.key === 'ArrowRight') next = (index + 1) % panels.length
  else if (event.key === 'ArrowLeft') next = (index + panels.length - 1) % panels.length
  else if (event.key === 'Home') next = 0
  else if (event.key === 'End') next = panels.length - 1
  else return
  event.preventDefault(); selected.value = panels[next]!.id
  ;(event.currentTarget as HTMLElement).parentElement?.querySelectorAll<HTMLButtonElement>('[role="tab"]')[next]?.focus()
}
</script>
<template>
  <section class="board-card" :class="{ 'board-container-card': ['group', 'tabs', 'split'].includes(component.kind) }" :style="{ textAlign: component.h_align === 'center' ? 'center' : component.h_align === 'trailing' ? 'right' : 'left' }" :aria-label="component.title" :data-h-align="component.h_align || 'stretch'" :data-v-align="component.v_align || 'top'" :data-board-component="component.id" :data-kind="component.kind" data-testid="board-card">
    <template v-if="depth < 8 && component.panels && ['group', 'tabs', 'split'].includes(component.kind)">
      <template v-if="component.kind === 'group'"><button class="plain board-group-toggle" :aria-expanded="expanded" @click="expanded = !expanded">{{ expanded ? '▾' : '▸' }} {{ component.title }}</button><div v-show="expanded"><NotebookBoardGrid v-if="component.panels[0]" :rows="component.panels[0].rows" :components="component.panels[0].components" :context="context" :depth="depth + 1" /></div></template>
      <template v-else-if="component.kind === 'tabs'">
        <h3 class="board-card-title">{{ component.title }}</h3>
        <div class="board-tabs" role="tablist" :aria-label="component.title"><button v-for="(panel, index) in component.panels" :id="panelPrefix + '-tab-' + index" :key="panel.id" role="tab" :aria-selected="selected === panel.id" :aria-controls="panelPrefix + '-panel-' + index" :tabindex="selected === panel.id ? 0 : -1" @click="selected = panel.id" @keydown="tabKey($event, index)">{{ panel.title }}</button></div>
        <div v-for="(panel, index) in component.panels" v-show="selected === panel.id" :id="panelPrefix + '-panel-' + index" :key="panel.id" role="tabpanel" :aria-labelledby="panelPrefix + '-tab-' + index" class="board-tab-panel"><NotebookBoardGrid :rows="panel.rows" :components="panel.components" :context="context" :depth="depth + 1" /></div>
      </template>
      <template v-else>
        <h3 class="board-card-title">{{ component.title }}</h3>
        <div ref="splitContainer" class="board-split" :class="{ 'board-split-vertical': component.split_axis === 'vertical', 'board-split-stacked': splitStacked }" :style="{ '--split-fraction': splitRatio, '--split-min': splitMinimum + 'px' }"><div v-for="panel in component.panels" :key="panel.id" class="board-split-panel"><h4>{{ panel.title }}</h4><NotebookBoardGrid :rows="panel.rows" :components="panel.components" :context="context" :depth="depth + 1" /></div></div>
        <label class="board-split-control">Panel ratio<input v-model.number="split" type="range" min="0.1" max="0.9" step="0.05" :aria-label="`Resize ${component.title} panels`"><button class="plain" @click="split = component.split_fraction ?? .5">Reset</button></label>
      </template>
    </template>
    <NotebookMediaInput v-else-if="context.media && (['file_input','audio_input'].includes(component.kind) || component.kind === 'audio_annotator' && (!component.audio_source || component.audio_source === 'file') || ['image','image_carousel'].includes(component.kind) && (component.image_allow_load || component.image_items?.length || component.image_annotator))" :component="component" :board-id="context.media.boardId" :runtime="context.media" :presentation="presentation" :selected-asset="boundAsset" :disabled="context.disabled" @dirty="context.media.onDirty(component.id, $event)" />
    <template v-else-if="component.kind === 'audio_annotator' && context.media"><h3>{{ component.title }}</h3><p class="source-note">{{ component.audio_source === 'cell' ? 'Completed cell publication' : 'Audio Input' }} · {{ component.audio_id || component.id }}</p><NotebookAudioAnnotator :component="component" :board-id="context.media.boardId" :runtime="context.media" :source-key="presentation.identity" :disabled="context.disabled || presentation.active" @dirty="context.media.onDirty(component.id,$event)" /></template>
    <NotebookSharedTable v-else-if="component.kind === 'table' && component.selection_id && context.media" :component="component" :board-id="context.media.boardId" :runtime="context.media" :source-key="presentation.identity + String(presentation.active)" :disabled="context.disabled" @dirty="context.media.onDirty(component.id,$event)" />
    <section v-else-if="['run_history','experiment_compare'].includes(component.kind)" :aria-label="component.title"><h3>{{ component.title }}</h3><p class="source-note">Inspect retained runs and accepted scalar parameters.</p><button @click="context.onHistory?.(component.kind === 'experiment_compare')">{{ component.kind === 'experiment_compare' ? 'Compare experiments…' : 'Open run snapshots…' }}</button></section>
    <NotebookDateInput v-else-if="component.kind === 'date_input'" :component="component" :input="context.definitions.find(input => input.id === component.input)" :state="context.state" :disabled="context.disabled" :on-apply="context.onApply" @dirty="context.onDirty(component.id,$event)" />
    <NotebookParameterPresets v-else-if="component.kind === 'parameter_presets'" :component="component" :context="context" :can-configure="context.canConfigure === true" @configure="context.onConfigure?.(component.id,$event)" />
    <template v-else-if="['input', 'range_input', 'parameter_form'].includes(component.kind)"><NotebookParameterForm :title="component.title" :definitions="context.definitions" :fields="controlFields" :state="context.state" :disabled="context.disabled" :on-apply="context.onApply" @dirty="context.onDirty(component.id, $event)" /></template>
    <NotebookBoardCommand v-else-if="['action', 'execution_controls'].includes(component.kind)" :component="component" :context="context" />
    <template v-else-if="missingSource"><h3 class="board-card-title">{{ component.title }}</h3><p class="rich-unavailable">Source cell unavailable</p></template>
    <template v-else-if="isDisplay && !(['image', 'image_carousel'].includes(component.kind) && component.image_items?.length)"><NotebookCellDisplay :component="effectiveComponent" :presentation="presentation" :selected-asset="boundAsset" /></template>
    <template v-else>
      <h3 class="board-card-title">{{ component.title }}</h3>
      <template v-if="component.kind === 'rich_text'"><NotebookMarkdown v-if="component.text_mode === 'markdown'" :source="component.text_content?.source || ''" :variables="context.textVariables" :label="component.title + ' preview'" /><NotebookTextPreview v-else :content="component.text_content || { source: '' }" :variables="context.textVariables" :label="component.title + ' preview'" /></template>
      <template v-else-if="component.kind === 'text'"><output class="board-scalar" :class="boundText.state ? 'text-variable-' + boundText.state : ''">{{ component.binding ? boundText.text : presentation.ok && presentation.result ? presentation.result : 'Unavailable' }}</output></template>
      <NotebookStatus v-else-if="component.kind === 'status'" :component="component" :context="context" />
      <NotebookTaskMonitor v-else-if="component.kind === 'task_monitor'" :context="context" />
      <NotebookArtifacts v-else-if="component.kind === 'artifacts'" :presentation="presentation" :context="context" />
      <NotebookResultInspector v-else-if="component.kind === 'result'" :presentation="presentation" />
      <template v-else-if="component.kind === 'plot'"><NotebookRichOutput :rich="scopedRich" :identity="presentation.identity" /><p v-if="!scopedRich.displays.length" class="rich-unavailable">Figure unavailable</p></template>
      <template v-else-if="component.kind === 'progress' || component.kind === 'stopwatch'"><NotebookTelemetry v-if="hasTelemetry" :rich="scopedRich" :active="presentation.active" :identity="presentation.identity" /><p v-else class="rich-unavailable">{{ component.kind === 'stopwatch' ? 'Waiting for stopwatch measurements' : 'Waiting for progress' }}</p></template>
      <NotebookLogViewer v-else-if="component.kind === 'log'" :presentation="presentation" />
      <template v-else-if="component.kind === 'run'"><button v-if="context.canExecute" :disabled="!context.canRun" @click="context.onRun(source!.id)">{{ component.title }}</button><p class="source-note">{{ context.canExecute ? 'Runs the saved source cell explicitly.' : 'Read-only runtime' }}</p></template>
      <p v-else class="rich-unavailable">This component is not available in the web board yet. Its saved settings are preserved.</p>
      <p v-if="['text', 'result', 'log'].includes(component.kind) && presentation.stale" class="rich-stale-note">Previous data · stale</p>
    </template>
    <p v-if="presentation.error" class="board-source-error" role="status">{{ presentation.error }}</p>
  </section>
</template>
