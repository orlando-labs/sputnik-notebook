<script setup lang="ts">
import { computed, ref } from 'vue'
import type { NotebookCell, NotebookDocument } from './notebook'
import { newId } from './notebook'
import { documentJSON, parseDocumentJSON } from './document-json'
import { defaultJSON, editingText, initialText, inputError, inputJSON, inputTypes, typeTitles, type CellUI, type CellComponent, type InputDefinition, type InputType } from './inputs'
import NotebookControlSettings from './NotebookControlSettings.vue'
import NotebookDisplaySettings from './NotebookDisplaySettings.vue'
import { displayKinds, displayTitles, displayError } from './displays'
const props = defineProps<{ document: NotebookDocument; disabled: boolean }>()
const emit = defineEmits<{ changed: [] }>()
const dialog = ref<HTMLDialogElement>(), target = ref<NotebookCell | null>(null), definitions = ref<InputDefinition[]>([]), ui = ref<CellUI>({ inputs: [], pre: [], post: [] }), selected = ref(0), error = ref(''), originals = ref<Set<string>>(new Set())
const current = computed(() => definitions.value[selected.value])
const defaults = ref<Record<string, string>>({})
const allComponents = computed(() => [...ui.value.pre, ...ui.value.post])
function show(cell?: NotebookCell) {
  target.value = cell || null; selected.value = 0; error.value = ''
  ui.value = parseDocumentJSON(documentJSON(cell?.cell_ui || { inputs: [], pre: [], post: [] })) as CellUI
  definitions.value = cell ? ui.value.inputs : parseDocumentJSON(documentJSON(props.document.inputs || [])) as InputDefinition[]
  originals.value = new Set(definitions.value.map(input => input.id)); defaults.value = {}
  for (const input of definitions.value) defaults.value[input.id] = editingText(defaultJSON(input), input.type)
  dialog.value?.showModal()
}
function addParameter() {
  let number = definitions.value.length + 1
  while (definitions.value.some(input => input.id === `parameter${number}`)) number++
  const id = `parameter${number}`
  definitions.value.push({ id, title: `Parameter ${number}`, type: 'number', ...(target.value ? { default_json: '0.0' } : { default: 0 }) }); defaults.value[id] = '0'; selected.value = definitions.value.length - 1
}
function rename(id: string) {
  if (!current.value || originals.value.has(current.value.id)) return
  const old = current.value.id; current.value.id = id
  defaults.value[id] = defaults.value[old] || ''; delete defaults.value[old]
  for (const component of allComponents.value) { if (component.input === old) component.input = id; for (const field of component.fields || []) if (field.input === old) field.input = id }
}
function changeType() { if (current.value) { defaults.value[current.value.id] = initialText(current.value.type); delete current.value.minimum; delete current.value.maximum } }
function removeParameter() {
  const input = current.value
  if (!input) return
  if (allComponents.value.some(component => component.input === input.id || component.fields?.some(field => field.input === input.id))) { error.value = 'Remove this parameter from its cell controls first.'; return }
  if (!target.value && JSON.stringify(props.document.boards || []).includes(JSON.stringify(input.id))) { error.value = 'Remove board bindings to this parameter before deleting it.'; return }
  if (!window.confirm(`Delete parameter ${input.title}? Update code that reads it before running again.`)) return
  definitions.value.splice(selected.value, 1); selected.value = Math.max(0, selected.value - 1); error.value = ''
}
function addComponent(kind: string) {
  if (allComponents.value.length >= 64) { error.value = 'A cell permits at most 64 components.'; return }
  if (['input', 'parameter_form'].includes(kind) && !definitions.value.length) addParameter()
  const component: CellComponent = { id: newId('component'), kind, title: kind === 'input' ? 'Input' : kind === 'parameter_form' ? 'Parameter Form' : displayTitles[kind]! }
  if (kind === 'input') { component.input = current.value?.id || definitions.value[0]!.id; component.control = { style: 'automatic' } }
  else if (kind === 'parameter_form') component.fields = definitions.value.map(input => ({ input: input.id, control: { style: 'automatic' } }))
  if (kind === 'live_chart') { component.chart_id = 'loss'; component.stroke = '#86505f' }
  if (kind === 'image') { component.image_id = 'image'; component.image_mode = 'fit' }
  ;(['input', 'parameter_form'].includes(kind) ? ui.value.pre : ui.value.post).push(component)
}
function position(component: CellComponent, after: boolean) { ui.value.pre = ui.value.pre.filter(item => item.id !== component.id); ui.value.post = ui.value.post.filter(item => item.id !== component.id); (after ? ui.value.post : ui.value.pre).push(component) }
function move(component: CellComponent, direction: number) { const list = ui.value.pre.includes(component) ? ui.value.pre : ui.value.post; const index = list.indexOf(component), next = index + direction; if (next < 0 || next >= list.length) return; list.splice(index, 1); list.splice(next, 0, component) }
function deleteComponent(component: CellComponent) { ui.value.pre = ui.value.pre.filter(item => item.id !== component.id); ui.value.post = ui.value.post.filter(item => item.id !== component.id) }
function bound(key: 'minimum' | 'maximum', event: Event) { if (!current.value) return; const value = (event.target as HTMLInputElement).value; if (!value) delete current.value[key]; else current.value[key] = Number(value) }
function save() {
  error.value = ''
  try {
    if (dialog.value?.querySelector('input:invalid')) throw new Error('Correct the invalid numeric setting before updating the draft.')
    if (allComponents.value.length > 64) throw new Error('A cell permits at most 64 components.')
    if (definitions.value.length > (target.value ? 128 : 1024)) throw new Error('Too many parameter definitions.')
    const ids = new Set<string>()
    for (const input of definitions.value) {
      if (!input.id.trim() || new TextEncoder().encode(input.id).length > 256 || input.id.includes('\0') || ids.has(input.id)) throw new Error('Parameter names must be unique and fit 256 bytes.')
      ids.add(input.id)
      if (!input.title.trim()) throw new Error('Every parameter needs a display title.')
      const json = inputJSON(defaults.value[input.id] || '', input)
      if (target.value) input.default_json = json
      else input.default = parseDocumentJSON(json)
    }
    for (const component of allComponents.value) {
      if (!component.title.trim()) throw new Error('Every component needs a title.')
      const invalidDisplay = displayError(component)
      if (invalidDisplay) throw new Error(`${component.title}: ${invalidDisplay}`)
      const fields = component.kind === 'input' ? [{ input: component.input || '', control: component.control }] : component.kind === 'parameter_form' ? component.fields || [] : []
      const used = new Set<string>()
      if (fields.length > 128) throw new Error('A form accepts up to 128 fields.')
      for (const field of fields) {
        const input = definitions.value.find(value => value.id === field.input)
        if (!input || used.has(field.input)) throw new Error('Choose a different local parameter for each form field.')
        used.add(field.input)
        const invalid = inputError(defaults.value[input.id] || '', input, field.control)
        if (invalid) throw new Error(`${input.title}: ${invalid}`)
      }
    }
    if (target.value) { ui.value.inputs = definitions.value; target.value.cell_ui = ui.value; props.document.version = 4 }
    else { props.document.inputs = definitions.value; props.document.version = Math.max(props.document.version, 2) as NotebookDocument['version'] }
    props.document.inputs ||= []; props.document.boards ||= []; if (props.document.version >= 3) props.document.dependencies ||= []
    emit('changed'); dialog.value?.close()
  } catch (cause) { error.value = cause instanceof Error ? cause.message : 'Could not update definitions.' }
}
defineExpose({ show })
</script>
<template>
  <dialog ref="dialog" class="notebook-dialog input-designer" aria-labelledby="input-designer-title">
    <div class="dialog-heading"><div><h2 id="input-designer-title">{{ target ? 'Cell Components & Parameters' : 'Project Inputs' }}</h2><p>{{ target ? 'Local parameters: notebook.cell_input("name")' : 'Shared parameters: notebook.input("name")' }}</p></div><button class="plain icon-button" aria-label="Close input designer" @click="dialog?.close()">×</button></div>
    <p class="source-note">Definitions and defaults join your notebook draft. Save notebook to commit them. This does not run code or apply runtime values.</p>
    <div class="input-designer-layout"><div class="definition-list"><div class="sidebar-section-title"><h3>{{ target ? 'Local parameters' : 'Project parameters' }}</h3><button type="button" :disabled="disabled" @click="addParameter">Add parameter</button></div><button v-for="(input, index) in definitions" :key="index" class="plain definition-link" :class="{ active: selected === index }" @click="selected = index">{{ input.title || input.id }}</button><p v-if="!definitions.length" class="source-note">No parameters yet.</p></div>
      <div v-if="current" class="definition-editor"><label>Parameter name<input :value="current.id" :readonly="originals.has(current.id)" aria-label="Parameter name" maxlength="256" @input="rename(($event.target as HTMLInputElement).value)"></label><label>Display title<input v-model="current.title" aria-label="Parameter title" maxlength="200"></label><label>Type<select v-model="current.type" aria-label="Parameter type" @change="changeType"><option v-for="type in inputTypes" :key="type" :value="type">{{ typeTitles[type] }}</option></select></label><label>Default value<textarea v-if="current.type === 'string'" v-model="defaults[current.id]" aria-label="Parameter default" rows="5" /><input v-else v-model="defaults[current.id]" aria-label="Parameter default"></label><div v-if="['number', 'integer'].includes(current.type)" class="input-definition-grid"><label>Minimum<input type="number" :value="current.minimum" aria-label="Parameter minimum" @input="bound('minimum', $event)"></label><label>Maximum<input type="number" :value="current.maximum" aria-label="Parameter maximum" @input="bound('maximum', $event)"></label></div><p v-if="inputError(defaults[current.id] || '', current)" class="parameter-error">{{ inputError(defaults[current.id] || '', current) }}</p><button type="button" :disabled="disabled" @click="removeParameter">Delete parameter…</button></div>
    </div>
    <section v-if="target" class="component-designer"><div class="panel-heading"><h3>Cell components</h3><div class="component-palette"><button type="button" :disabled="disabled" @click="addComponent('input')">Add Input</button><button type="button" :disabled="disabled" @click="addComponent('parameter_form')">Add Parameter Form</button><button v-for="kind in displayKinds" :key="kind" type="button" :disabled="disabled" @click="addComponent(kind)">Add {{ displayTitles[kind] }}</button></div></div>
      <article v-for="component in allComponents" :key="component.id" class="component-settings"><div class="component-settings-heading"><strong>{{ component.kind === 'parameter_form' ? 'Parameter Form' : component.kind === 'input' ? 'Input' : component.kind }}</strong><select :value="ui.post.includes(component) ? 'post' : 'pre'" :aria-label="`${component.title} placement`" @change="position(component, ($event.target as HTMLSelectElement).value === 'post')"><option value="pre">Before code</option><option value="post">After code</option></select><button type="button" :aria-label="`Move ${component.title} up`" @click="move(component, -1)">↑</button><button type="button" :aria-label="`Move ${component.title} down`" @click="move(component, 1)">↓</button><button type="button" :aria-label="`Delete component ${component.title}`" @click="deleteComponent(component)">×</button></div><label>Component title<input v-model="component.title" :aria-label="`${component.kind} title`"></label>
        <template v-if="component.kind === 'input'"><label>Local parameter<select v-model="component.input" aria-label="Input parameter"><option v-for="input in definitions" :key="input.id" :value="input.id">{{ input.title }}</option></select></label><NotebookControlSettings v-if="definitions.find(input => input.id === component.input)" :input="definitions.find(input => input.id === component.input)!" :control="component.control ||= { style: 'automatic' }" :prefix="component.title" /></template>
        <template v-else-if="component.kind === 'parameter_form'"><div v-for="(field, index) in component.fields || []" :key="index" class="form-field-designer"><label>Local parameter<select v-model="field.input" :aria-label="`Form field ${index + 1}`"><option v-for="input in definitions" :key="input.id" :value="input.id">{{ input.title }}</option></select></label><NotebookControlSettings v-if="definitions.find(input => input.id === field.input)" :input="definitions.find(input => input.id === field.input)!" :control="field.control ||= { style: 'automatic' }" :prefix="`${component.title} field ${index + 1}`" /><button type="button" :aria-label="`Delete form field ${index + 1}`" @click="component.fields?.splice(index, 1)">Remove field</button></div><button type="button" :disabled="!definitions.length" @click="(component.fields ||= []).push({ input: definitions[0]!.id, control: { style: 'automatic' } })">Add form field</button></template>
        <NotebookDisplaySettings v-else-if="displayKinds.includes(component.kind as typeof displayKinds[number])" :component="component" :disabled="disabled" />
        <p v-else class="source-note">Display settings are preserved. Open the desktop app to use this display.</p>
      </article>
    </section>
    <p v-if="error" class="parameter-error" role="alert">{{ error }}</p><div class="dialog-actions"><button @click="dialog?.close()">Cancel</button><button class="primary" :disabled="disabled" @click="save">Update notebook draft</button></div>
  </dialog>
</template>
