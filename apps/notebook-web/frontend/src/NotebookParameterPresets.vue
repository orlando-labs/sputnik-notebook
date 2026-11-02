<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, watch } from 'vue'
import type { BoardComponent, BoardContext } from './boards'
import { capturePreset, presetError, presetListError, type ParameterPreset } from './parameter-presets'
import { documentJSON, parseDocumentJSON } from './document-json'
import { defaultJSON } from './inputs'
import { download } from './rich'
const props = defineProps<{ component: BoardComponent; context: BoardContext; canConfigure: boolean }>()
const emit = defineEmits<{ configure: [value: ParameterPreset[]] }>()
const selected = ref(''), draftID = ref(''), base = ref(''), busy = ref(false), error = ref(''), dialog = ref<HTMLDialogElement>(), open = ref(false), name = ref(''), file = ref<HTMLInputElement>(), sets = ref<ParameterPreset[]>([]), manageSelected = ref('')
const presets = computed(() => (props.component.p1?.presets || []) as ParameterPreset[]), scope = computed(() => (props.component.p1?.preset_inputs || []) as string[])
const preset = computed(() => presets.value.find(p => p.id === selected.value)), draft = computed(() => presets.value.find(p => p.id === draftID.value))
const validation = computed(() => draft.value ? presetError(draft.value, props.context.definitions, scope.value, props.context.components) : '')
const invalidSets = computed(() => presetListError(sets.value, props.context.definitions, scope.value, props.context.components))
const stale = computed(() => !!draftID.value && base.value !== props.context.state?.version)
const dirty = computed(() => !!draftID.value || open.value)
let definition = ''
watch(dirty, value => props.context.onDirty(props.component.id, value), { flush: 'sync' })
function choose() { draftID.value = ''; error.value = '' }
function review() { if (!preset.value) return; draftID.value = selected.value; base.value = props.context.state?.version || ''; error.value = '' }
function current(id: string) { const input = props.context.definitions.find(d => d.id === id); return props.context.state?.values[id] ?? (input ? defaultJSON(input) : 'Unavailable') }
async function apply() {
  if (!draft.value || validation.value || stale.value || busy.value || props.context.disabled || !props.context.state) return
  busy.value = true; error.value = ''
  try { if (await props.context.onApply(draft.value.values, base.value)) draftID.value = ''; else error.value = 'Preset values were not confirmed. Your review is kept.' } catch (cause) { error.value = (cause as Error).message } finally { busy.value = false }
}
async function manage() { if (!props.canConfigure) return; sets.value = parseDocumentJSON(documentJSON(presets.value)) as ParameterPreset[]; definition = documentJSON(props.component); manageSelected.value = ''; name.value = ''; error.value = ''; open.value = true; await nextTick(); dialog.value?.showModal() }
function close() { dialog.value?.close(); open.value = false; sets.value = []; error.value = '' }
function save() { if (invalidSets.value || !props.canConfigure || documentJSON(props.component) !== definition) { error.value = 'The component changed. Reopen before updating these sets.'; return }; const value = parseDocumentJSON(documentJSON(sets.value)) as ParameterPreset[]; close(); emit('configure', value) }
function capture() { const value = capturePreset(name.value, props.context.definitions, props.context.state?.values || {}, scope.value), invalid = presetError(value, props.context.definitions, scope.value, props.context.components); if (invalid) { error.value = invalid; return }; sets.value.push(value); manageSelected.value = value.id; error.value = '' }
function rename() { const value = sets.value.find(p => p.id === manageSelected.value); if (value) value.title = name.value }
function remove() { sets.value = sets.value.filter(p => p.id !== manageSelected.value); manageSelected.value = '' }
async function importFile(event: Event) {
  const value = (event.target as HTMLInputElement).files?.[0]; if (!value) return
  try { if (value.size > 1048576) throw new Error('Preset imports must fit 1 MiB.'); const imported = parseDocumentJSON(await value.text()) as ParameterPreset[]; const invalid = presetListError(imported, props.context.definitions, scope.value, props.context.components); if (invalid) throw new Error(invalid); if (sets.value.length + imported.length > 128) throw new Error('At most 128 presets per component.'); sets.value.push(...imported.map(p => ({ ...p, id: 'preset_' + crypto.randomUUID().replaceAll('-', '') }))); error.value = '' } catch (cause) { error.value = (cause as Error).message } finally { (event.target as HTMLInputElement).value = '' }
}
function exportSets() { download(new Blob([documentJSON(sets.value)], { type: 'application/json' }), 'parameter-presets.json') }
watch(() => props.context.media?.readable, value => { if (value === false) { draftID.value = ''; close() } })
onBeforeUnmount(() => props.context.onDirty(props.component.id, false))
</script>
<template><section class="parameter-form parameter-presets" :aria-label="component.title + ' presets'"><h3>{{ component.title }}</h3><label>Preset<select v-model="selected" aria-label="Preset" :disabled="busy || context.disabled" @change="choose"><option value="">Choose preset…</option><option v-for="p in presets" :key="p.id" :value="p.id">{{ p.title }}</option></select></label><div class="parameter-actions"><button :disabled="!preset || busy || context.disabled" @click="review">Review preset</button><button v-if="canConfigure" :disabled="busy || !!draftID" @click="manage">Manage presets…</button></div>
  <template v-if="draft"><p class="source-note">Review · {{ draft.title }} · {{ Object.keys(draft.values).length }} parameters applied together</p><div class="table-scroll"><table class="preset-comparison"><thead><tr><th>Parameter</th><th>Current JSON</th><th>Preset JSON</th></tr></thead><tbody><tr v-for="(value,id) in draft.values" :key="id"><th>{{ id }}</th><td><code>{{ current(String(id)) }}</code></td><td><code>{{ value }}</code></td></tr></tbody></table></div><p v-if="validation || stale" class="parameter-error">{{ stale ? 'Parameters changed. Reset the review before applying.' : validation }}</p><div class="parameter-actions"><button :disabled="busy" @click="draftID = ''">Reset review</button><button class="primary" :disabled="busy || context.disabled || !!validation || stale" @click="apply">{{ busy ? 'Applying…' : 'Apply preset' }}</button></div></template><p v-if="error && !open" class="parameter-error" role="status">{{ error }}</p><p class="source-note">Choosing or capturing a set does not change accepted values. Save authored sets explicitly; defaults stay separate.</p>
  <dialog ref="dialog" class="notebook-dialog preset-dialog" aria-label="Parameter presets" @cancel.prevent="close"><h2>Parameter presets</h2><label>Saved set<select v-model="manageSelected" aria-label="Saved preset" @change="name = sets.find(p => p.id === manageSelected)?.title || ''"><option value="">Choose…</option><option v-for="p in sets" :key="p.id" :value="p.id">{{ p.title }}</option></select></label><label>Name<input v-model="name" aria-label="Preset name" maxlength="256"></label><p class="source-note">Scope: {{ scope.length ? scope.join(', ') : 'All project parameters' }} · {{ sets.length }} / 128 sets</p><div class="parameter-actions"><button :disabled="sets.length >= 128 || !name.trim() || !context.state" @click="capture">Capture current</button><button :disabled="!manageSelected || !name.trim()" @click="rename">Rename preset</button><button :disabled="!manageSelected" @click="remove">Delete preset</button><button @click="file?.click()">Import presets…</button><input ref="file" type="file" accept=".json,application/json" aria-label="Import presets" hidden @change="importFile"><button :disabled="!sets.length" @click="exportSets">Export presets…</button></div><p v-if="invalidSets || error" class="source-error" role="status">{{ invalidSets || error }}</p><footer class="dialog-actions"><button @click="close">Cancel</button><button class="primary" :disabled="!!invalidSets || !canConfigure" @click="save">Update notebook draft</button></footer></dialog>
</section></template>
