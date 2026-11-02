<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import { api, APIError } from './api'
import type { BoardComponent } from './boards'
import type { MediaRuntime } from './media-inputs'
import { documentJSON } from './document-json'
import { parseSourceTable, publicTable, selectedRow, selectionError, type SourceTable, type SharedSelection } from './shared-selection'
import NotebookTable from './NotebookTable.vue'
const props = defineProps<{ component: BoardComponent; boardId: string; runtime: MediaRuntime; disabled: boolean; sourceKey: string }>()
const emit = defineEmits<{ dirty: [value: boolean] }>()
const table = ref<SourceTable | null>(null), source = ref(''), selected = ref(''), clear = ref(false), loading = ref(false), busy = ref(false), error = ref('')
const unavailable = ref(false)
const accepted = computed(() => props.component.selection as SharedSelection | null)
const preview = computed(() => table.value ? publicTable(table.value) : null)
const invalid = computed(() => table.value ? selectionError(table.value, String(props.component.selection_key || '')) : 'No completed table.')
const dirty = computed(() => clear.value || !!selected.value)
const revision = ref(''), version = ref(''), fingerprint = ref('')
let generation = 0, disposed = false
const stale = computed(() => dirty.value && (revision.value !== props.runtime.revision || version.value !== props.runtime.version || fingerprint.value !== props.sourceKey))
watch(dirty, value => emit('dirty', value), { flush: 'sync' })
function reset() { selected.value = ''; clear.value = false; error.value = ''; revision.value = props.runtime.revision; version.value = props.runtime.version }
function select(id: string) { if (props.disabled || loading.value || busy.value) return; if (!dirty.value) { revision.value = props.runtime.revision; version.value = props.runtime.version; fingerprint.value = props.sourceKey }; selected.value = id; clear.value = false }
async function load() {
  if (dirty.value) return
  const own = ++generation; loading.value = true; error.value = ''; unavailable.value = false; table.value = null
  if (!props.runtime.readable) { loading.value = false; return }
  try { const result = await api<{ source: string; table: string }>(`/api/projects/${encodeURIComponent(props.runtime.projectId)}/media-inputs/source?revision=${encodeURIComponent(props.runtime.revision)}&board=${encodeURIComponent(props.boardId)}&component=${encodeURIComponent(props.component.id)}`)
    if (!disposed && own === generation && props.runtime.readable) { table.value = parseSourceTable(result.table); source.value = result.source; reset() }
  } catch (cause) { if (own === generation) { unavailable.value = cause instanceof APIError && cause.status === 422; error.value = unavailable.value ? 'Run the saved source cell to publish a table.' : (cause as Error).message } } finally { if (own === generation) loading.value = false }
}
watch([() => props.runtime.revision, () => props.runtime.readable, () => props.sourceKey], () => { if (!props.runtime.readable) { generation++; table.value = null; reset() } else void load() }, { immediate: true })
async function apply() {
  if (!dirty.value || props.disabled || !props.runtime.canApply || busy.value || stale.value || !clear.value && invalid.value) return
  busy.value = true; error.value = ''
  try {
    const value = clear.value ? null : selectedRow(table.value!, source.value, String(props.component.selection_key || ''), selected.value), bytes = new TextEncoder().encode(documentJSON(value)); let binary = ''; for (let i = 0; i < bytes.length; i += 16384) binary += String.fromCharCode(...bytes.subarray(i, i + 16384))
    if (await props.runtime.apply({ board_id: props.boardId, component_id: props.component.id, operation: 'annotations', extension: 'json', name: 'selection.json', data: btoa(binary) }, { revision: revision.value, version: version.value })) { reset(); void load() } else error.value = 'Selection was not confirmed. Your draft is kept; check media command status.'
  } catch (cause) { error.value = (cause as Error).message } finally { busy.value = false }
}
onBeforeUnmount(() => { disposed = true; generation++; emit('dirty', false) })
</script>
<template>
  <section class="shared-table" :aria-label="component.title + ' shared selection'"><h3>{{ component.title }}</h3>
    <NotebookTable v-if="preview" :table="preview" :selected-id="selected" @select="select" />
    <p v-if="loading" role="status">Loading completed table…</p><p v-if="accepted" class="source-note">Accepted key: {{ documentJSON(accepted.key) }}{{ accepted.source !== source ? ' · source changed; select again' : '' }}</p>
    <p v-if="dirty" class="source-note">{{ clear ? 'Clear selection on Apply' : 'Draft selection · not applied' }}</p><p v-if="invalid && table" class="source-error">{{ invalid }}</p><p v-if="stale" class="source-error">Parameters or source changed. Reset before applying this selection.</p><p v-if="error" :class="unavailable ? 'source-note' : 'source-error'" role="status">{{ error }}</p>
    <div class="parameter-actions"><button :disabled="busy || loading" @click="reset(); load()">Reset selection</button><button :disabled="disabled || busy" @click="if (!dirty) { revision = runtime.revision; version = runtime.version; fingerprint = sourceKey }; selected = ''; clear = true">Clear selection</button><button class="primary" :disabled="disabled || busy || !runtime.canApply || !dirty || stale || !clear && !!invalid" @click="apply">{{ busy ? 'Applying…' : 'Apply selection' }}</button></div>
    <p class="source-note">Selection uses the original typed key. Apply saves a snapshot; Run explicitly to consume it.</p>
  </section>
</template>
