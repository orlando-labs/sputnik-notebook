<script setup lang="ts">
import { computed, ref } from 'vue'
import type { NotebookBoard, BoardComponent } from './boards'
import type { BoardGrid } from './board-editor'
import { freeColumns } from './board-editor'
import type { NotebookDocument } from './notebook'
import { referenceID } from './boards'
import { displayKinds } from './displays'
import type { InputControl, FormField } from './inputs'
import NotebookDisplaySettings from './NotebookDisplaySettings.vue'
import NotebookControlSettings from './NotebookControlSettings.vue'
import NotebookCommandSettings from './NotebookCommandSettings.vue'
import NotebookTextEditor from './NotebookTextEditor.vue'
import NotebookMarkdown from './NotebookMarkdown.vue'
import { replaceSource } from './rich-text'
const props = defineProps<{ component: BoardComponent; board: NotebookBoard; grid: BoardGrid; document: NotebookDocument; disabled: boolean }>()
const emit = defineEmits<{ move: [row: string]; width: [span: number]; reorder: [direction: number]; duplicate: []; remove: []; enter: [panel: string]; addPanel: []; removePanel: [panel: string]; movePanel: [panel: string, direction: number] }>()
const cells = computed(() => props.document.sheets.find(sheet => sheet.id === props.board.sheet)?.cells.filter(cell => cell.kind === 'code') || [])
const isContainer = computed(() => ['group', 'tabs', 'split'].includes(props.component.kind))
const isDisplay = computed(() => props.component.kind === 'audio_annotator' || displayKinds.includes((props.component.kind === 'image_carousel' ? 'image' : props.component.kind) as typeof displayKinds[number]))
const siblings = computed(() => props.grid.components.filter(component => component.row === props.component.row && component.kind !== 'periodic_work'))
const siblingIndex = computed(() => siblings.value.findIndex(component => component.id === props.component.id))
const markdownError = ref('')
function editMarkdown(event: Event) {
  const input = event.target as HTMLTextAreaElement, content = props.component.text_content
  if (!content || props.disabled) return
  try { const value = replaceSource(content, input.value); props.component.text_content = { ...content, ...value, formatting: value.formatting }; markdownError.value = '' }
  catch (cause) { input.value = content.source; markdownError.value = (cause as Error).message }
}
function presetScope(id: string, checked: boolean) { const settings = props.component.p1 ||= {}, scope = (settings.preset_inputs ||= []) as string[]; settings.preset_inputs = checked ? [...scope,id] : scope.filter(value => value !== id) }
function numeric(key: string, event: Event) { const value = (event.target as HTMLInputElement).value; if (value === '') delete props.component[key]; else props.component[key] = Number(value) }
function control(field: { control?: InputControl }): InputControl {
  return new Proxy({}, { get: (_, key: string) => field.control?.[key] ?? (key === 'style' ? 'automatic' : undefined), set: (_, key: string, value: unknown) => { (field.control ||= {})[key] = value; return true }, deleteProperty: (_, key: string) => { if (field.control) delete field.control[key]; return true } })
}
function addField() {
  const input = props.document.inputs?.find(input => !props.component.fields?.some(field => field.input === input.id))
  if (input && (props.component.fields?.length || 0) < 128) (props.component.fields ||= []).push({ input: input.id })
}
function definition(field: FormField) { return props.document.inputs?.find(input => input.id === field.input) }
</script>
<template>
  <fieldset class="board-inspector-fields" :disabled="disabled">
    <legend>Object Inspector</legend>
    <p class="source-note">{{ component.kind }} · <code>{{ component.id }}</code></p>
    <label>Component title<input v-model="component.title" aria-label="Component title" maxlength="200"></label>
    <template v-if="component.kind !== 'periodic_work'">
      <label>Row<select :value="component.row" aria-label="Component row" @change="emit('move', ($event.target as HTMLSelectElement).value)"><option v-for="(row, index) in grid.rows" :key="row.id" :value="row.id" :disabled="freeColumns(grid, row.id, component.id) < (component.span || 12)">Row {{ index + 1 }} · {{ freeColumns(grid, row.id, component.id) }} columns available</option></select></label>
      <label>Width / 12 columns<input type="number" :value="component.span || 12" aria-label="Component width" min="1" :max="freeColumns(grid, component.row || '', component.id)" step="1" @change="emit('width', Number(($event.target as HTMLInputElement).value))"></label>
      <div class="input-definition-grid"><label>Horizontal alignment<select :value="component.h_align || 'stretch'" @change="component.h_align = ($event.target as HTMLSelectElement).value" aria-label="Horizontal alignment"><option value="leading">Left</option><option value="center">Center</option><option value="trailing">Right</option><option value="stretch">Stretch</option></select></label><label>Vertical alignment<select :value="component.v_align || 'top'" @change="component.v_align = ($event.target as HTMLSelectElement).value" aria-label="Vertical alignment"><option value="top">Top</option><option value="center">Center</option><option value="bottom">Bottom</option><option value="stretch">Stretch</option></select></label></div>
      <div class="board-inspector-actions"><button type="button" :disabled="siblingIndex <= 0" @click="emit('reorder', -1)">Move left</button><button type="button" :disabled="siblingIndex < 0 || siblingIndex + 1 >= siblings.length" @click="emit('reorder', 1)">Move right</button></div>
    </template>
    <NotebookCommandSettings v-if="['action', 'periodic_work', 'execution_controls', 'status'].includes(component.kind)" :component="component" :board="board" :document="document" />
    <template v-else-if="isContainer">
      <template v-if="component.kind === 'group'"><label class="auto-import-option"><input type="checkbox" :checked="component.p1?.collapsed === true" aria-label="Initially collapsed" @change="(component.p1 ||= {}).collapsed = ($event.target as HTMLInputElement).checked">Initially collapsed</label></template>
      <template v-if="component.kind === 'split'"><label>Direction<select :value="component.split_axis || 'horizontal'" @change="component.split_axis = ($event.target as HTMLSelectElement).value" aria-label="Split direction"><option value="horizontal">Side by side</option><option value="vertical">Stacked</option></select></label><label>Initial divider position<input type="number" :value="component.split_fraction ?? .5" aria-label="Initial divider position" min="0.1" max="0.9" step="any" @input="numeric('split_fraction', $event)"></label><label>Minimum panel size<input type="number" :value="component.split_min ?? 120" aria-label="Minimum panel size" min="48" max="1024" step="any" @input="numeric('split_min', $event)"></label></template>
      <article v-for="(panel, index) in component.panels || []" :key="panel.id" class="board-panel-settings"><label>Panel {{ index + 1 }} title<input v-model="panel.title" :aria-label="`Panel ${index + 1} title`" maxlength="200"></label><div class="board-inspector-actions"><button type="button" :aria-label="`Edit panel ${index + 1}`" @click="emit('enter', panel.id)">Edit contents…</button><template v-if="component.kind === 'tabs'"><button type="button" :disabled="index === 0" :aria-label="`Move panel ${index + 1} left`" @click="emit('movePanel', panel.id, -1)">←</button><button type="button" :disabled="index + 1 === component.panels!.length" :aria-label="`Move panel ${index + 1} right`" @click="emit('movePanel', panel.id, 1)">→</button><button type="button" :disabled="component.panels!.length <= 1" :aria-label="`Delete panel ${index + 1}`" @click="emit('removePanel', panel.id)">Delete</button></template></div></article>
      <button v-if="component.kind === 'tabs'" type="button" :disabled="(component.panels?.length || 0) >= 32" @click="emit('addPanel')">Add panel</button>
    </template>
    <template v-else-if="component.kind === 'file_input'">
      <label>File parameter<select v-model="component.input" aria-label="File parameter"><option value="">Choose…</option><option v-for="input in document.inputs?.filter(input => input.type === 'string') || []" :key="input.id" :value="input.id">{{ input.title }}</option></select></label>
      <label>Allowed extensions<input :value="component.p1?.extensions || ''" aria-label="Allowed extensions" maxlength="512" placeholder="csv,json,txt" @input="(component.p1 ||= {}).extensions = ($event.target as HTMLInputElement).value"></label>
    </template>
    <template v-else-if="component.kind === 'date_input'"><label>Date parameter<select v-model="component.input" aria-label="Date parameter"><option value="">Choose…</option><option v-for="input in document.inputs?.filter(input => input.type === 'string') || []" :key="input.id" :value="input.id">{{ input.title }}</option></select></label><label>Value<select :value="component.date_mode || 'date_time'" aria-label="Date mode" @change="component.date_mode = ($event.target as HTMLSelectElement).value"><option value="date_time">Date and time</option><option value="date">Calendar date</option></select></label><label>IANA time zone<input :value="component.date_time_zone || 'UTC'" aria-label="IANA time zone" @input="component.date_time_zone = ($event.target as HTMLInputElement).value"></label></template>
    <template v-else-if="component.kind === 'parameter_presets'"><p class="source-note">An empty scope includes all project parameters. Manage saved sets from the running board.</p><label v-for="input in document.inputs || []" :key="input.id"><input type="checkbox" :aria-label="'Preset scope ' + input.title" :checked="((component.p1?.preset_inputs || []) as string[]).includes(input.id)" @change="presetScope(input.id, ($event.target as HTMLInputElement).checked)">{{ input.title }}</label></template>
    <template v-else-if="component.kind === 'audio_input'">
      <label>Audio input channel<input v-model="component.audio_id" aria-label="Audio input channel" maxlength="256" :placeholder="component.id"></label>
      <label><input type="checkbox" :checked="component.show_waveform !== false" @change="component.show_waveform = ($event.target as HTMLInputElement).checked">Show waveform</label>
      <label><input type="checkbox" :checked="component.audio_recording !== false" aria-label="Allow microphone recording" @change="component.audio_recording = ($event.target as HTMLInputElement).checked">Allow microphone recording</label>
      <p class="source-note">Recording is explicit and creates a local WAV draft before Apply.</p>
    </template>
    <template v-else-if="component.kind === 'input' || component.kind === 'range_input'">
      <label>Project parameter<select v-model="component.input" aria-label="Project parameter"><option value="">Choose…</option><option v-for="input in document.inputs?.filter(input => component.kind !== 'range_input' || input.type === 'range') || []" :key="input.id" :value="input.id">{{ input.title }}</option></select></label>
      <NotebookControlSettings v-if="document.inputs?.find(input => input.id === component.input)" :input="document.inputs.find(input => input.id === component.input)!" :control="control(component)" :prefix="component.id" />
      <p v-if="!document.inputs?.length" class="source-note">Create project parameters in Project Inputs… before binding this control.</p>
    </template>
    <template v-else-if="component.kind === 'parameter_form'">
      <article v-for="(field, index) in component.fields || []" :key="index" class="board-panel-settings"><label>Parameter<select v-model="field.input" :aria-label="`Form field ${index + 1} parameter`"><option v-for="input in document.inputs || []" :key="input.id" :value="input.id">{{ input.title }}</option></select></label><NotebookControlSettings v-if="definition(field)" :input="definition(field)!" :control="control(field)" :prefix="component.id + '-field-' + (index + 1)" /><button type="button" :aria-label="`Delete form field ${index + 1}`" @click="component.fields?.splice(index, 1)">Remove field</button></article>
      <button type="button" :disabled="(component.fields?.length || 0) >= 128 || !document.inputs?.some(input => !component.fields?.some(field => field.input === input.id))" @click="addField">Add form field</button>
    </template>
    <template v-else>
      <label v-if="['metric', 'table', 'result', 'progress', 'plot', 'log', 'artifacts', 'run', 'text', 'audio'].includes(component.kind) || component.kind === 'audio_annotator' && component.audio_source === 'cell'">Source cell<select :value="referenceID(component.cell)" aria-label="Source cell" @change="component.cell = ($event.target as HTMLSelectElement).value"><option value="">Choose…</option><option v-if="referenceID(component.cell) && !cells.some(cell => cell.id === referenceID(component.cell))" :value="referenceID(component.cell)">Unavailable · {{ referenceID(component.cell) }}</option><option v-for="(cell, index) in cells" :key="cell.id" :value="cell.id">Cell {{ index + 1 }} · {{ cell.source.split('\n').find(line => line.trim())?.slice(0, 60) || 'Empty code' }}</option></select></label>
      <NotebookDisplaySettings v-if="isDisplay" :component="component" :disabled="disabled" />
      <label v-else-if="component.kind === 'progress'">Progress ID<input v-model="component.progress_id" aria-label="Progress ID" placeholder="Empty: all progress" maxlength="256"></label>
      <label v-else-if="component.kind === 'stopwatch'">Stopwatch ID<input v-model="component.stopwatch_id" aria-label="Stopwatch ID" placeholder="default" maxlength="256"></label>
      <template v-else-if="component.kind === 'rich_text'"><label>Text format<select :value="component.text_mode || 'richtext'" aria-label="Board text format" @change="component.text_mode = ($event.target as HTMLSelectElement).value"><option value="richtext">Portable rich text</option><option value="markdown">Markdown</option></select></label><NotebookTextEditor v-if="component.text_content && component.text_mode !== 'markdown'" :content="component.text_content" label="Board text source" :disabled="disabled" @change="component.text_content = { ...component.text_content, ...$event, formatting: $event.formatting }" /><template v-else><label>Markdown source<textarea v-if="component.text_content" :value="component.text_content.source" aria-label="Board text source" rows="7" @input="editMarkdown" /></label><p v-if="markdownError" class="source-error" role="alert">{{ markdownError }}</p><NotebookMarkdown :source="component.text_content?.source || ''" label="Board Markdown preview" /><p class="source-note">Preview uses literal values. Save the notebook and explicitly run its controller to publish new variable names. Portable formatting is remapped with source edits; use its table controls for structural changes.</p></template></template>
      <label v-else-if="component.kind === 'text'">Published variable<input v-model="component.binding" aria-label="Published text variable" maxlength="128" placeholder="Empty: cell result"></label>
      <p v-else-if="component.kind === 'task_monitor'" class="source-note">Shows bounded child-task telemetry from the controller sheet. Viewing does not start a worker.</p>
      <p v-else-if="component.kind === 'artifacts'" class="source-note">Return records with path, name and optional caption. Web reads only members of the run's immutable saved bundle.</p>
      <p v-else-if="!['result', 'plot', 'log', 'run'].includes(component.kind)" class="source-note">These saved settings are preserved. Component-specific editing is not available in the web designer yet.</p>
    </template>
    <div class="board-inspector-actions"><button type="button" @click="emit('duplicate')">Duplicate component</button><button type="button" @click="emit('remove')">Delete component</button></div>
  </fieldset>
</template>
