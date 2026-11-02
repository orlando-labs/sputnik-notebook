<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { assetID } from './shared-selection'
import type { CellComponent } from './inputs'
import type { CellPresentation } from './execution'
import { displayError, displayTables, metricValue, numberSetting } from './displays'
import { documentJSON } from './document-json'
import NotebookTable from './NotebookTable.vue'
import NotebookImages from './NotebookImages.vue'
import NotebookAuthoredChart from './NotebookAuthoredChart.vue'
import NotebookAudio from './NotebookAudio.vue'
const props = defineProps<{ component: CellComponent; presentation: CellPresentation; selectedAsset?: string | null }>()
const matchingImages = ref<string[]>([]), matchingAudio = ref<string[]>([])
let generation = 0
watch([() => props.selectedAsset, () => props.presentation.rich.images.flatMap(s => s.images).map(i => i.data || '').join('\0'), () => (props.presentation.rich.audio || []).filter(a => a.kind === 'file').map(a => a.data).join('\0')], async () => {
  const own = ++generation; matchingImages.value = []; matchingAudio.value = []
  if (!props.selectedAsset) return
  const images = props.presentation.rich.images.flatMap(s => s.images), audio = (props.presentation.rich.audio || []).filter(a => a.kind === 'file')
  const [ii, aa] = await Promise.all([Promise.all(images.map(async value => await assetID(value.data || '') === props.selectedAsset ? value.data! : '')), Promise.all(audio.map(async value => await assetID(value.data) === props.selectedAsset ? value.data : ''))])
  if (own === generation) { matchingImages.value = ii.filter(Boolean); matchingAudio.value = aa.filter(Boolean) }
}, { immediate: true })
const invalid = computed(() => displayError(props.component))
const tables = computed(() => displayTables(props.component, props.presentation.rich))
const image = computed(() => { const series = props.presentation.rich.images.find(series => series.id === (props.component.image_id || props.component.id)); return series && props.selectedAsset !== undefined ? { ...series, images: series.images.filter(i => matchingImages.value.includes(i.data || '')) } : series })
const audio = computed(() => (props.presentation.rich.audio || []).filter(asset => (!props.component.audio_id || asset.id === props.component.audio_id) && (props.selectedAsset === undefined || matchingAudio.value.includes(asset.data))))
const metric = computed(() => metricValue(props.component.binding ? props.presentation.metrics.find(value => value.name === props.component.binding)?.value : props.presentation.ok ? props.presentation.result : null, props.component.p1))
const target = computed(() => props.component.p1?.target === undefined ? undefined : metricValue(documentJSON(props.component.p1.target), props.component.p1).text)
const delta = computed(() => {
  const baseline = numberSetting(props.component.p1?.baseline), value = metric.value.number
  if (baseline === undefined || value === undefined || !Number.isFinite(value - baseline)) return undefined
  const difference = value - baseline, improvement = props.component.p1?.improvement
  return { text: `${difference >= 0 ? '+' : ''}${metricValue(String(difference), props.component.p1).text}`, state: improvement === 'neutral' ? 'neutral' : (improvement === 'lower' ? difference < 0 : difference > 0) ? 'better' : 'worse' }
})
const stale = computed(() => props.component.kind === 'metric' ? props.presentation.stale : props.component.kind === 'live_chart' ? props.presentation.rich.telemetry_stale : props.presentation.rich.rich_stale && !props.presentation.running)
</script>
<template>
  <section class="cell-display-component" :class="{ 'component-stale': stale }" :aria-label="component.title" :data-kind="component.kind" :data-component-id="component.id" data-testid="cell-display-component">
    <h3 v-if="component.kind !== 'live_chart' || invalid" class="component-title">{{ component.title }}</h3>
    <p v-if="invalid" class="rich-unavailable" role="status">{{ invalid }}</p>
    <template v-else-if="component.kind === 'metric'">
      <output class="metric-value" :aria-label="component.title + ' value'">{{ metric.text }}</output>
      <p v-if="target !== undefined" class="metric-target">Target: {{ target }}</p>
      <p v-if="delta" class="metric-delta" :class="'delta-' + delta.state">Δ {{ delta.text }}</p>
    </template>
    <template v-else-if="component.kind === 'table'"><NotebookTable v-for="table in tables" :key="`${presentation.identity}:${table.id}`" :table="table.table" :caption="table.caption" /><p v-if="!tables.length" class="rich-unavailable">Table unavailable · publish a matching DataTableView or run the saved cell.</p></template>
    <NotebookAuthoredChart v-else-if="component.kind === 'live_chart'" :key="presentation.identity" :component="component" :rich="presentation.rich" />
    <template v-else-if="component.kind === 'image'"><NotebookImages v-if="image?.images.length" :key="`${presentation.identity}:${image.id}`" :series="image" :mode="component.image_mode || 'fit'" :allow-save="component.image_allow_save !== false" /><p v-else class="rich-unavailable">{{ selectedAsset !== undefined ? 'No image matches the accepted selection.' : 'Image channel unavailable · run the saved cell to publish images.' }}</p><p v-if="component.caption" class="image-caption">{{ component.caption }}</p></template>
    <template v-else-if="component.kind === 'audio'"><NotebookAudio v-for="(asset, index) in audio" :key="`${presentation.identity}:${asset.id || index}`" :asset="asset" :stale="presentation.rich.audio_stale ?? presentation.rich.rich_stale" :show-waveform="component.show_waveform" :controls="presentation.rich.audio_controls?.filter(control => control.channel && control.channel === asset.id || !control.channel && presentation.rich.audio?.length === 1 && !presentation.rich.audio_limited)" /><p v-if="!audio.length" class="rich-unavailable">{{ selectedAsset !== undefined ? 'No audio matches the accepted selection.' : 'Audio channel unavailable · run the saved cell to publish audio.' }}</p><p v-if="presentation.rich.audio_limited" class="rich-unavailable">Some audio exceeds the web result limits.</p><p v-if="presentation.rich.audio_controls?.some(control => !control.channel) && (presentation.rich.audio?.length || 0) > 1" class="rich-unavailable">Choose an audio channel before sending player commands.</p><p v-if="component.caption" class="audio-caption">{{ component.caption }}</p></template>
    <p v-if="stale" class="rich-stale-note">{{ component.kind === 'metric' ? 'Previous value · stale' : 'Previous data · stale' }}</p>
  </section>
</template>
