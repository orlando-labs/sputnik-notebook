<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import { defaultJSON, editingText, type InputDefinition, type InputState } from './inputs'
import { localTime, timeCandidates, validDate, validZone } from './date-input'
import type { BoardComponent } from './boards'
const props = defineProps<{ component: BoardComponent; input?: InputDefinition; state?: InputState; disabled: boolean; onApply: (values: Record<string, string>, version: string) => Promise<boolean> }>()
const emit = defineEmits<{ dirty: [value: boolean] }>()
const draft = ref(''), edited = ref(false), base = ref(''), choice = ref(''), busy = ref(false), error = ref('')
const zone = computed(() => String(props.component.date_time_zone || 'UTC')), calendar = computed(() => props.component.date_mode === 'date')
const current = computed(() => props.input ? editingText(props.state?.values[props.input.id] ?? defaultJSON(props.input), 'string') : '')
const candidates = computed(() => { try { return calendar.value ? validDate(draft.value) ? [draft.value] : [] : timeCandidates(draft.value, zone.value) } catch { return [] } })
const invalid = computed(() => { if (!props.input || props.input.type !== 'string') return 'Choose a String project parameter.'; if (!validZone(zone.value)) return 'Unknown IANA time zone.'; if (!edited.value) return ''; try { if (calendar.value && !validDate(draft.value)) throw new Error('Enter a valid calendar date.'); if (!calendar.value) timeCandidates(draft.value, zone.value); return candidates.value.length > 1 && !candidates.value.includes(choice.value) ? 'This time occurs twice. Choose its UTC occurrence.' : '' } catch (cause) { return (cause as Error).message } })
const stale = computed(() => edited.value && base.value !== props.state?.version)
watch(edited, value => emit('dirty', value), { flush: 'sync' })
function reset() { draft.value = calendar.value ? current.value : localTime(current.value, zone.value); edited.value = false; choice.value = ''; base.value = props.state?.version || ''; error.value = '' }
watch([current, zone, calendar], () => { if (!edited.value) reset() }, { immediate: true })
function edit(event: Event) { if (!edited.value) base.value = props.state?.version || ''; draft.value = (event.target as HTMLInputElement).value; choice.value = ''; edited.value = true; error.value = '' }
async function apply() {
  if (props.disabled || !props.state || !props.input || !edited.value || stale.value || invalid.value || !candidates.value.length || busy.value) return
  busy.value = true; error.value = ''
  try { const value = candidates.value.length > 1 ? choice.value : candidates.value[0]!; if (await props.onApply({ [props.input.id]: JSON.stringify(value) }, base.value)) { edited.value = false; reset() } else error.value = 'Date was not confirmed. Your draft is kept.' } catch (cause) { error.value = (cause as Error).message } finally { busy.value = false }
}
onBeforeUnmount(() => emit('dirty', false))
</script>
<template><section class="parameter-form" :aria-label="component.title + ' date control'"><h3>{{ component.title }}</h3><label>{{ input?.title || 'Date' }}<input :type="calendar ? 'date' : 'datetime-local'" :value="draft" :aria-label="component.title + ' value'" step="1" :disabled="disabled || busy || !validZone(zone)" @input="edit"></label><p class="source-note">{{ calendar ? 'Calendar date' : 'Local display; stored in UTC' }} · {{ zone }}</p><label v-if="candidates.length > 1 && edited">UTC occurrence<select v-model="choice" aria-label="UTC occurrence"><option value="">Choose…</option><option v-for="value in candidates" :key="value" :value="value">{{ value }}</option></select></label><p>Current: <span class="exact-value">{{ current }}</span></p><p v-if="edited && candidates.length === 1">Draft: {{ candidates[0] }}</p><p v-if="invalid || error || stale" class="parameter-error" role="status">{{ stale ? 'Parameters changed. Reset before applying this date.' : invalid || error }}</p><div class="parameter-actions"><button :disabled="busy" @click="reset">Reset draft</button><button class="primary" :disabled="disabled || busy || !state || !edited || !!invalid || stale || !candidates.length" @click="apply">{{ busy ? 'Applying…' : 'Apply' }}</button></div></section></template>
