<script setup lang="ts">
import { computed, onUnmounted, ref } from 'vue'
import { api } from './api'

interface CellExport { binding: string; name: string }
interface Row { binding: string; alias: string; available: boolean; enabled: boolean }
type Target = { label: string; source: string; update: (source: string) => void }
type Analysis = { bindings: string[]; exports: CellExport[] }

const props = defineProps<{ projectId: string; disabled: boolean }>()
const dialog = ref<HTMLDialogElement>()
const rows = ref<Row[]>()
const target = ref<Target>()
const error = ref('')
const applying = ref(false)
let controller: AbortController | undefined
const selection = computed(() => (rows.value || []).filter(row => row.enabled))

async function analyze<T>(source: string, signal: AbortSignal, exports?: CellExport[]): Promise<T> {
  const result = await api<T & { error?: string }>(`/api/projects/${encodeURIComponent(props.projectId)}/notebook/cell-exports`,
    'POST', { source, exports }, signal)
  if (result.error) throw new Error(result.error)
  return result
}

async function show(cell: Target) {
  controller?.abort()
  const { signal } = controller = new AbortController()
  target.value = cell
  rows.value = undefined
  applying.value = false
  error.value = ''
  dialog.value?.showModal()
  try {
    const result = await analyze<Analysis>(cell.source, signal)
    if (signal.aborted) return
    const available = new Set(result.bindings)
    const declared = new Map<string, Row[]>()
    for (const { binding, name } of result.exports) {
      const row = { binding, alias: name === binding ? '' : name, available: available.has(binding), enabled: true }
      const previous = declared.get(binding)
      if (previous) previous.push(row)
      else declared.set(binding, [row])
    }
    rows.value = [...new Set([...available, ...declared.keys()])].sort().flatMap(binding =>
      declared.get(binding) || [{ binding, alias: '', available: true, enabled: false }])
  } catch (cause) {
    if (!signal.aborted) error.value = cause instanceof Error ? cause.message : 'Could not analyze cell exports.'
  }
}

async function apply() {
  const cell = target.value, signal = controller?.signal
  if (!cell || !signal || !rows.value || applying.value || props.disabled || selection.value.some(row => !row.available)) return
  applying.value = true
  error.value = ''
  try {
    const exports = selection.value.map(row => ({ binding: row.binding, name: row.alias.trim() || row.binding }))
    const updated = await analyze<{ source: string }>(cell.source, signal, exports)
    if (signal.aborted) return
    cell.update(updated.source)
    dialog.value?.close()
  } catch (cause) {
    if (!signal.aborted) error.value = cause instanceof Error ? cause.message : 'Could not update cell exports.'
  } finally {
    if (!signal.aborted) applying.value = false
  }
}

function close() { controller?.abort() }
onUnmounted(close)
defineExpose({ show })
</script>

<template>
  <dialog ref="dialog" class="notebook-dialog" aria-labelledby="cell-exports-title" @close="close" @cancel="close">
    <form @submit.prevent="apply">
      <h2 id="cell-exports-title">Exports · {{ target?.label }}</h2>
      <div v-if="rows?.length" class="export-bindings">
        <div v-for="(row, index) in rows" :key="index" class="export-binding">
          <label><input v-model="row.enabled" type="checkbox" :disabled="applying"> <code>{{ row.binding }}</code></label>
          <span v-if="!row.available" class="source-note">Binding missing</span>
          <input v-else-if="row.enabled" v-model="row.alias" :aria-label="`Export name for ${row.binding}`" :placeholder="`Export as ${row.binding}`" :disabled="applying">
        </div>
      </div>
      <p v-else-if="rows" class="source-note">This cell has no bindings to export.</p>
      <p v-else-if="!error" class="source-note" role="status">Analyzing cell…</p>
      <p v-if="error" class="source-error" role="alert">{{ error }}</p>
      <div class="dialog-actions">
        <button type="button" @click="dialog?.close()">Cancel</button>
        <button class="primary" :disabled="!rows || applying || disabled || selection.some(row => !row.available)">Apply</button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.export-bindings { display: grid; gap: 4px; max-height: 19rem; overflow-y: auto; margin-top: 12px; padding: 2px; }
.export-binding { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 10px; min-height: 34px; align-items: center; }
.export-binding label { display: flex; align-items: center; gap: 6px; margin: 0; overflow-wrap: anywhere; }
.export-binding input:not([type=checkbox]) { font-family: monospace; }
</style>
