<script setup lang="ts">
import type { CellComponent } from './inputs'
import NotebookAnnotationSettings from './NotebookAnnotationSettings.vue'
import { documentJSON, parseDocumentJSON } from './document-json'
import { decimalJSON } from './inputs'
const props = defineProps<{ component: CellComponent; disabled: boolean }>()
const text = (event: Event) => (event.target as HTMLInputElement).value
const numberText = (value: unknown) => value === undefined ? '' : documentJSON(value)
function setting(key: string, value: unknown) { (props.component.p1 ||= {})[key] = value }
function optional(key: string, event: Event) { const value = text(event); if (value) props.component[key] = value; else delete props.component[key] }
function number(key: string, event: Event, nested = false) {
  const target = nested ? (props.component.p1 ||= {}) : props.component, value = text(event)
  if (!value) delete target[key]
  else {
    try {
      const whole = /^[+-]?\d+$/.test(value) ? BigInt(value) : undefined
      const token = whole !== undefined && whole >= -9223372036854775808n && whole <= 9223372036854775807n ? whole.toString() : decimalJSON(value)
      target[key] = parseDocumentJSON(token)
    } catch { /* Browser validity blocks committing incomplete numbers. */ }
  }
}
function addSeries() {
  const series = (props.component.p1 ||= {}).series ||= []
  if (series.length >= 16) return
  let index = series.length + 1
  while (series.some(item => item.id === `series${index}`)) index++
  series.push({ id: `series${index}`, title: `Series ${index}`, stroke: ['#86505f', '#4c739e', '#568766', '#d97706'][series.length % 4]! })
}
function transcriptPolicy(prefix: string, event: Event) {
  const allowed = (event.target as HTMLInputElement).checked
  props.component[prefix + '_allowed'] = allowed
  if (!allowed) props.component[prefix + '_required'] = false
}
</script>
<template>
  <fieldset class="display-settings" :disabled="disabled">
    <template v-if="component.kind === 'audio_annotator'">
      <label>Audio source<select :value="component.audio_source || 'file'" aria-label="Audio annotation source" @change="component.audio_source = text($event)"><option value="file">Owned file</option><option value="input">Audio Input channel</option><option value="cell">Completed cell publication</option></select></label>
      <label>Audio channel<input v-model="component.audio_id" aria-label="Audio annotation channel" maxlength="256" :placeholder="component.id"></label>
      <label>Annotation channel<input v-model="component.annotation_id" aria-label="Annotation channel" maxlength="256" :placeholder="component.id + '_labels'"></label>
      <label>Initial display<select :value="component.audio_view || 'waveform'" aria-label="Initial audio display" @change="component.audio_view = text($event)"><option value="waveform">Waveform</option><option value="spectrogram">Spectrogram</option></select></label>
      <label>FFT size<select :value="Number(component.audio_fft_size || 1024)" aria-label="Initial FFT size" @change="component.audio_fft_size = Number(text($event))"><option v-for="n in [256,512,1024,2048,4096]" :key="n" :value="n">{{ n }}</option></select></label>
      <div v-for="item in [{prefix:'audio_transcript',title:'Whole-track'},{prefix:'audio_segment_transcript',title:'Segment'}]" :key="item.prefix"><label><input type="checkbox" :aria-label="'Allow ' + item.title.toLowerCase() + ' transcript'" :checked="component[item.prefix + '_allowed'] !== false" @change="transcriptPolicy(item.prefix,$event)">Allow {{ item.title.toLowerCase() }} transcript</label><label><input type="checkbox" :aria-label="'Require ' + item.title.toLowerCase() + ' transcript'" :checked="component[item.prefix + '_required'] === true" :disabled="component[item.prefix + '_allowed'] === false" @change="component[item.prefix + '_required'] = ($event.target as HTMLInputElement).checked">Require {{ item.title.toLowerCase() }} transcript</label></div>
      <NotebookAnnotationSettings :component="component" />
    </template>
    <template v-else-if="component.kind === 'metric'">
      <label>Published variable<input v-model="component.binding" aria-label="Published variable" placeholder="Empty: cell result" maxlength="65536"></label>
      <label>Unit<input :value="component.p1?.unit || ''" aria-label="Metric unit" maxlength="256" @input="setting('unit', text($event))"></label>
      <label>Decimal places<input type="number" :value="numberText(component.p1?.precision)" aria-label="Metric precision" min="0" max="12" step="1" placeholder="Automatic for Int64; otherwise 2" @input="number('precision', $event, true)"></label>
      <label class="auto-import-option"><input type="checkbox" :checked="component.p1?.percentage === true" aria-label="Metric percentage" @change="setting('percentage', ($event.target as HTMLInputElement).checked)">Show as percentage</label>
      <div class="input-definition-grid"><label>Target<input type="number" step="any" :value="numberText(component.p1?.target)" aria-label="Metric target" @input="number('target', $event, true)"></label><label>Baseline<input type="number" step="any" :value="numberText(component.p1?.baseline)" aria-label="Metric baseline" @input="number('baseline', $event, true)"></label></div>
      <label>Improvement<select :value="component.p1?.improvement || 'higher'" aria-label="Metric improvement" @change="setting('improvement', text($event))"><option value="higher">Higher is better</option><option value="lower">Lower is better</option><option value="neutral">Neutral</option></select></label>
    </template>
    <template v-else-if="component.kind === 'table'"><label>Table ID<input v-model="component.table_id" aria-label="Table ID" maxlength="256" placeholder="Empty: published tables or result"></label><label>Selection channel<input v-model="component.selection_id" aria-label="Selection channel" maxlength="256"></label><label v-if="component.selection_id">Unique key column<input v-model="component.selection_key" aria-label="Selection key column" placeholder="Column name or ID" maxlength="256"></label></template>
    <template v-else-if="component.kind === 'audio'"><label>Audio channel ID<input :value="component.audio_id || ''" aria-label="Audio channel ID" maxlength="256" placeholder="Empty: all published audio" @input="optional('audio_id', $event)"></label><label>Waveform<select :value="component.show_waveform === undefined ? 'published' : component.show_waveform ? 'show' : 'hide'" aria-label="Audio waveform" @change="text($event) === 'published' ? delete component.show_waveform : component.show_waveform = text($event) === 'show'"><option value="published">Published setting</option><option value="show">Show waveform</option><option value="hide">Hide waveform</option></select></label></template>
    <template v-else-if="component.kind === 'image' || component.kind === 'image_carousel'">
      <label>Image channel ID<input :value="component.image_id || ''" aria-label="Image channel ID" maxlength="256" :placeholder="component.id" @input="optional('image_id', $event)"></label>
      <label>Sizing<select :value="component.image_mode || 'fit'" aria-label="Image sizing" @change="component.image_mode = text($event)"><option value="fit">Fit</option><option value="fill">Fill</option><option value="auto-height">Auto height</option></select></label>
      <label class="auto-import-option"><input type="checkbox" :checked="component.image_allow_load === true" aria-label="Allow image load" @change="component.image_allow_load = ($event.target as HTMLInputElement).checked">Allow loading images</label>
      <label class="auto-import-option"><input type="checkbox" :checked="component.image_allow_read === true" aria-label="Allow image read" @change="component.image_allow_read = ($event.target as HTMLInputElement).checked">Allow runtime image reads</label>
      <label class="auto-import-option"><input type="checkbox" :checked="component.image_annotator === true" aria-label="Enable image annotations" @change="component.image_annotator = ($event.target as HTMLInputElement).checked">Enable image annotations</label>
      <template v-if="component.image_annotator"><label>Annotation channel<input :value="component.annotation_id || ''" aria-label="Annotation channel" :placeholder="component.id+'_labels'" maxlength="256" @input="optional('annotation_id',$event)"></label><NotebookAnnotationSettings :component="component" /></template>
      <label class="auto-import-option"><input type="checkbox" :checked="component.image_allow_save !== false" aria-label="Allow image save" @change="component.image_allow_save = ($event.target as HTMLInputElement).checked">Allow saving the image</label>
    </template>
    <template v-else-if="component.kind === 'live_chart'">
      <label>Chart channel ID<input :value="component.chart_id || ''" aria-label="Chart channel ID" maxlength="256" :placeholder="component.id" @input="optional('chart_id', $event)"></label>
      <div class="input-definition-grid"><label>X label<input v-model="component.x_label" aria-label="Chart X label" placeholder="X"></label><label>Y label<input v-model="component.y_label" aria-label="Chart Y label" placeholder="Y"></label></div>
      <label>Line color<input :value="component.stroke || ''" aria-label="Chart line color" placeholder="#86505f" maxlength="7" @input="optional('stroke', $event)"></label>
      <div v-for="axis in ['x', 'y']" :key="axis" class="input-definition-grid"><label>{{ axis.toUpperCase() }} minimum<input type="number" step="any" :value="numberText(component[axis + '_min'])" :aria-label="`Chart ${axis.toUpperCase()} minimum`" @input="number(axis + '_min', $event)"></label><label>{{ axis.toUpperCase() }} maximum<input type="number" step="any" :value="numberText(component[axis + '_max'])" :aria-label="`Chart ${axis.toUpperCase()} maximum`" @input="number(axis + '_max', $event)"></label></div>
      <div class="chart-series-settings"><p class="source-note">Configure series to combine channels in one chart. An empty series list uses the single channel above.</p><article v-for="(series, index) in component.p1?.series || []" :key="index" class="form-field-designer"><label>Channel<input v-model="series.id" :aria-label="`Series ${index + 1} channel`" maxlength="256"></label><label>Title<input v-model="series.title" :aria-label="`Series ${index + 1} title`" maxlength="256"></label><label>Color<input v-model="series.stroke" :aria-label="`Series ${index + 1} color`" maxlength="7"></label><button type="button" @click="component.p1?.series?.splice(index, 1)">Remove series</button></article><button type="button" :disabled="(component.p1?.series?.length || 0) >= 16" @click="addSeries">Add series</button></div>
    </template>
    <template v-if="['image','image_carousel','audio'].includes(component.kind)"><label>Selection channel<input v-model="component.selection_id" aria-label="Selection channel" maxlength="256" placeholder="Empty: show all assets"></label><label v-if="component.selection_id">Asset column<input v-model="component.selection_asset" aria-label="Selection asset column" maxlength="256" placeholder="asset_id"></label></template>
    <label v-if="component.kind !== 'metric'">Caption<textarea v-model="component.caption" aria-label="Display caption" rows="2" /></label>
  </fieldset>
</template>
