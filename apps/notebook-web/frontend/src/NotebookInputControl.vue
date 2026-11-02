<script setup lang="ts">
import { computed, useId } from 'vue'
import { editingText, lowerBound, upperBound, stepped, rangeDomains, decimalJSON, type InputControl, type InputDefinition } from './inputs'
const props = defineProps<{ input: InputDefinition; control?: InputControl; modelValue: string; disabled: boolean }>()
const emit = defineEmits<{ 'update:modelValue': [value: string] }>()
const id = useId()
const config = computed(() => props.control || {})
const style = computed(() => config.value.style || 'automatic')
const minimum = computed(() => lowerBound(props.input, config.value)), maximum = computed(() => upperBound(props.input, config.value))
const options = computed(() => (config.value.options || []).map(option => ({ ...option, value: editingText(option.value_json, props.input.type) })))
const step = computed(() => config.value.step || (props.input.type === 'integer' ? 1 : ((maximum.value || 1) - (minimum.value || 0)) / 100))
const range = computed(() => { try { return props.input.type === 'range' && ['slider', 'range_sliders'].includes(style.value) ? rangeDomains(props.modelValue, config.value) : null } catch { return null } })
function slide(part: 'start' | 'finish', value: string) {
  const current = range.value
  if (!current) return
  let number = Number(value); if (current.whole) number = Math.round(number)
  const start = part === 'start' ? Math.min(number, current.finish) : current.start
  const finish = part === 'finish' ? Math.max(number, current.start) : current.finish
  const token = (value: number) => Object.is(value, -0) && !current.whole ? '-0.0' : !current.whole && Number.isInteger(value) ? value + '.0' : String(value)
  emit('update:modelValue', `(${token(start)}${current.inclusive ? '..' : '...'}${token(finish)}:${current.step})`)
}
function move(by: number) { const value = stepped(props.modelValue, by, props.input, config.value); if (value !== null) emit('update:modelValue', value) }
</script>
<template>
  <div class="parameter-control">
    <label v-if="input.type === 'boolean'" class="parameter-toggle" :for="id"><input :id="id" type="checkbox" :checked="modelValue === 'true'" :disabled="disabled" :aria-label="input.title" @change="emit('update:modelValue', ($event.target as HTMLInputElement).checked ? 'true' : 'false')">{{ input.title }}</label>
    <template v-else-if="style === 'radio' || style === 'segmented'"><div :class="['parameter-choices', { segmented: style === 'segmented' }]" role="radiogroup" :aria-label="input.title"><label v-for="(option, index) in options" :key="index"><input type="radio" :name="id" :value="option.value" :checked="modelValue === option.value" :disabled="disabled" @change="emit('update:modelValue', option.value)"><span>{{ option.label }}</span></label></div></template>
    <select v-else-if="style === 'select'" :id="id" :aria-label="input.title" :value="modelValue" :disabled="disabled" @change="emit('update:modelValue', ($event.target as HTMLSelectElement).value)"><option v-if="!options.some(option => option.value === modelValue)" :value="modelValue">Choose…</option><option v-for="(option, index) in options" :key="index" :value="option.value">{{ option.label }}</option></select>
    <template v-else-if="style === 'slider' && input.type !== 'range' && minimum != null && maximum != null"><input :id="id" type="range" :aria-label="input.title" :value="modelValue" :min="minimum" :max="maximum" :step="step" :disabled="disabled" @input="emit('update:modelValue', input.type === 'integer' ? String(Math.round(Number(($event.target as HTMLInputElement).value))) : decimalJSON(($event.target as HTMLInputElement).value))"><output :for="id">{{ modelValue }} {{ config.unit || '' }}</output></template>
    <div v-else-if="range" class="range-parameter"><label>Start<input type="range" :aria-label="`${input.title} start`" :value="range.start" :min="range.startMin" :max="Math.min(range.startMax, range.finish)" :step="range.increment" :disabled="disabled" @input="slide('start', ($event.target as HTMLInputElement).value)"></label><label>Finish<input type="range" :aria-label="`${input.title} finish`" :value="range.finish" :min="Math.max(range.finishMin, range.start)" :max="range.finishMax" :step="range.increment" :disabled="disabled" @input="slide('finish', ($event.target as HTMLInputElement).value)"></label><input type="text" :aria-label="input.title" :value="modelValue" :disabled="disabled" @input="emit('update:modelValue', ($event.target as HTMLInputElement).value)"></div>
    <textarea v-else-if="input.type === 'string'" :id="id" :class="{ 'config-source': style === 'json' }" :aria-label="input.title" :value="modelValue" :rows="style === 'json' ? 8 : Math.min(6, Math.max(2, modelValue.split('\n').length))" :disabled="disabled" :spellcheck="style !== 'json'" @input="emit('update:modelValue', ($event.target as HTMLTextAreaElement).value)" />
    <div v-else class="parameter-number"><input :id="id" type="text" :inputmode="input.type === 'integer' ? 'numeric' : input.type === 'number' ? 'decimal' : undefined" :aria-label="input.title" :value="modelValue" :disabled="disabled" autocomplete="off" spellcheck="false" @input="emit('update:modelValue', ($event.target as HTMLInputElement).value)"><template v-if="style === 'stepper'"><button type="button" :aria-label="`Decrease ${input.title}`" :disabled="disabled || stepped(modelValue, -1, input, config) === null" @click="move(-1)">−</button><button type="button" :aria-label="`Increase ${input.title}`" :disabled="disabled || stepped(modelValue, 1, input, config) === null" @click="move(1)">+</button></template><span v-if="config.unit" class="subtle-label">{{ config.unit }}</span></div>
    <p v-if="input.type === 'range'" class="source-note">Range: (start...finish:step), or (start..finish:step) to include the end.</p>
    <p v-if="style === 'json'" class="source-note">{{ (config.config_format as string || 'json').toUpperCase() }} · Apply validates the complete config on the server.</p>
  </div>
</template>
