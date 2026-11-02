<script setup lang="ts">
import { computed, onUnmounted, ref, watch } from 'vue'
import NotebookInputControl from './NotebookInputControl.vue'
import { defaultJSON, editingText, inputJSON, inputError, valueEqual, type InputDefinition, type FormField, type InputState } from './inputs'
const props = defineProps<{ title: string; definitions: InputDefinition[]; fields: FormField[]; state?: InputState; disabled: boolean; onApply: (values: Record<string, string>, version: string) => Promise<boolean> }>()
const emit = defineEmits<{ dirty: [value: boolean] }>()
const drafts = ref<Record<string, string>>({}), baseVersion = ref(''), busy = ref(false), error = ref('')
const fields = computed(() => props.fields.map(field => ({ ...field, definition: props.definitions.find(input => input.id === field.input) })))
const currentJSON = (input: InputDefinition) => props.state?.values[input.id] ?? defaultJSON(input)
const text = (input: InputDefinition) => drafts.value[input.id] ?? editingText(currentJSON(input), input.type)
const dirty = computed(() => fields.value.some(field => field.definition && drafts.value[field.input] !== undefined && (() => { try { return !valueEqual(inputJSON(drafts.value[field.input]!, field.definition, field.control), currentJSON(field.definition), field.definition.type) } catch { return true } })()))
const valid = computed(() => fields.value.length <= 128 && fields.value.every(field => field.definition && !inputError(text(field.definition), field.definition, field.control)))
const stale = computed(() => dirty.value && !!baseVersion.value && baseVersion.value !== props.state?.version)
watch(dirty, value => { emit('dirty', value); if (!value && Object.keys(drafts.value).length) { drafts.value = {}; baseVersion.value = '' } }, { immediate: true })
onUnmounted(() => emit('dirty', false))
function edit(id: string, value: string) { if (!Object.keys(drafts.value).length) baseVersion.value = props.state?.version || ''; drafts.value[id] = value; error.value = '' }
function reset() { drafts.value = {}; baseVersion.value = ''; error.value = '' }
function defaults() { baseVersion.value ||= props.state?.version || ''; for (const field of fields.value) if (field.definition) drafts.value[field.input] = editingText(defaultJSON(field.definition), field.definition.type); error.value = '' }
async function apply() {
  if (!valid.value || !dirty.value || !props.state || busy.value || props.disabled || stale.value) return
  busy.value = true; error.value = ''
  try {
    const values: Record<string, string> = Object.create(null)
    for (const field of fields.value) if (field.definition) values[field.input] = inputJSON(text(field.definition), field.definition, field.control)
    if (await props.onApply(values, baseVersion.value || props.state.version)) reset()
    else error.value = 'The values were not confirmed. Your draft is kept; check parameter status below.'
  } catch (cause) { error.value = cause instanceof Error ? cause.message : 'Could not apply these values.' }
  finally { busy.value = false }
}
</script>
<template>
  <section class="parameter-form" :aria-label="title" data-testid="parameter-form">
    <h3>{{ title }}</h3>
    <div v-for="field in fields" :key="field.input" class="parameter-field">
      <template v-if="field.definition"><span v-if="field.definition.type !== 'boolean'" class="parameter-label">{{ field.definition.title }}</span><NotebookInputControl :input="field.definition" :control="field.control" :model-value="text(field.definition)" :disabled="disabled || busy || !state" @update:model-value="edit(field.input, $event)" /><p v-if="inputError(text(field.definition), field.definition, field.control)" class="parameter-error">{{ inputError(text(field.definition), field.definition, field.control) }}</p><p v-if="state && state.values[field.input] !== undefined" class="parameter-current">Current: <span>{{ editingText(currentJSON(field.definition), field.definition.type) }}</span></p></template>
      <p v-else class="parameter-error">Parameter {{ field.input }} is unavailable.</p>
    </div>
    <p v-if="stale" class="parameter-error" role="status">Parameters changed on the server. Your draft is kept. Reset to current values before applying again.</p>
    <p v-if="error" class="parameter-error" role="alert">{{ error }}</p>
    <div class="parameter-actions"><button type="button" :disabled="busy || !state" @click="reset">Reset to current</button><button type="button" :disabled="disabled || busy || !state" @click="defaults">Defaults</button><button type="button" class="primary" :disabled="disabled || busy || !state || !dirty || !valid || stale" @click="apply">{{ busy ? 'Applying…' : 'Apply' }}</button></div>
  </section>
</template>
