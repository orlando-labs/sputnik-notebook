<script setup lang="ts">
import { computed, onUnmounted, ref, watch } from 'vue'
import { api, APIError } from './api'
import { documentJSON, parseDocumentJSON } from './document-json'
import { bookPolicy, bytesLabel, integerToken, policyValue, resourceFields, scaledValue, secondsLabel, type ResourceKey, type ResourceStatus } from './resource-policy'
const props = defineProps<{ projectId: string; policy: unknown; writable: boolean; disabled: boolean }>()
const emit = defineEmits<{ change: [value: unknown]; dirty: [value: boolean] }>()
const dialog = ref<HTMLDialogElement>(), status = ref<ResourceStatus | null>(null), error = ref(''), unsupported = ref(''), loading = ref(false)
const fields = ref<Partial<Record<ResourceKey, { enabled: boolean; text: string; original: string | null }>>>({})
let baseline = '', disposed = false, generation = 0, controller: AbortController | undefined
const draftJSON = computed(() => JSON.stringify(fields.value))
watch(draftJSON, value => emit('dirty', !!dialog.value?.open && value !== baseline))
function initialize() {
  unsupported.value = ''; fields.value = {}
  try {
    const policy = bookPolicy(props.policy)
    for (const field of resourceFields) {
      const token = integerToken(policy[field.key])
      fields.value[field.key] = { enabled: token !== null, text: scaledValue(token, field.scale), original: token }
    }
  } catch (cause) { unsupported.value = (cause as Error).message }
  baseline = draftJSON.value
}
async function refresh() {
  const version = ++generation
  controller?.abort(); controller = new AbortController(); loading.value = true; error.value = ''
  try { const result = await api<{ resources: ResourceStatus }>(`/api/projects/${encodeURIComponent(props.projectId)}/resources`, 'GET', undefined, controller.signal); if (!disposed && version === generation) status.value = result.resources }
  catch (cause) { if (!disposed && version === generation) { status.value = null; error.value = cause instanceof Error ? cause.message : 'Could not read resource usage.'; if (cause instanceof APIError && [401, 403, 404].includes(cause.status)) close() } }
  finally { if (version === generation) loading.value = false }
}
function show() { status.value = null; initialize(); dialog.value?.showModal(); void refresh() }
function close() { dialog.value?.close(); emit('dirty', false); controller?.abort(); generation++; loading.value = false }
function toggle(key: ResourceKey) {
  const state = fields.value[key]!, field = resourceFields.find(item => item.key === key)!
  if (state.enabled && !state.text) state.text = scaledValue(status.value?.defaults[key] ?? (field.key.endsWith('seconds') ? '60' : field.scale.toString()), field.scale)
}
function apply() {
  if (!props.writable || props.disabled || unsupported.value || !status.value) return
  try {
    const result = parseDocumentJSON(documentJSON(bookPolicy(props.policy))) as Record<string, unknown>
    for (const field of resourceFields) {
      const state = fields.value[field.key]!
      if (!state.enabled) delete result[field.key]
      else result[field.key] = state.original !== null && state.text === scaledValue(state.original, field.scale) ? parseDocumentJSON(state.original) : policyValue(state.text, field)
    }
    emit('change', result); close()
  } catch (cause) { error.value = (cause as Error).message }
}
onUnmounted(() => { disposed = true; controller?.abort() })
defineExpose({ show, isOpen: () => !!dialog.value?.open })
</script>
<template>
  <dialog ref="dialog" class="notebook-dialog resource-dialog" aria-labelledby="resource-title" @cancel.prevent="close" @close="emit('dirty', false)" @keydown.meta.s.prevent.stop="apply" @keydown.ctrl.s.prevent.stop="apply">
    <form @submit.prevent="apply">
      <div class="dialog-heading"><div><h2 id="resource-title">Resource limits</h2><p>Overrides for this notebook</p></div><button type="button" class="plain icon-button" aria-label="Close resource limits" @click="close">×</button></div>
      <p class="source-note">Unchecked fields inherit server/app defaults. Update the notebook draft, then Save notebook to apply these settings. Changing limits does not run code or reset usage.</p>
      <p v-if="error || unsupported" class="source-error" role="alert">{{ error || unsupported }}</p>
      <p v-if="loading" role="status">Reading server resource policy…</p>
      <template v-if="status">
        <p class="source-note">{{ status.allow_book_policy_overrides ? 'Book values replace app defaults; explicit server, owner and public limits remain ceilings.' : 'This server combines book and app limits restrictively: smaller quotas and a larger disk reserve win.' }}</p>
        <div class="resource-usage" data-testid="resource-usage"><span>Execution used: <strong>{{ secondsLabel(status.spent_ms) }}</strong></span><span>Remaining: <strong>{{ secondsLabel(status.remaining_ms) }}</strong></span><template v-if="status.storage"><span>Stored: <strong>{{ bytesLabel(status.storage.project_bytes) }}</strong></span><span>Retained runs: <strong>{{ status.storage.retained_runs }}</strong></span></template></div>
        <p v-if="status.remaining_ms === '0'" class="source-error" role="status">The execution budget is exhausted. Stop and saved results remain available.</p>
        <div v-if="!unsupported" class="resource-fields"><div v-for="field in resourceFields" :key="field.key" class="resource-field">
          <label><input v-model="fields[field.key]!.enabled" type="checkbox" :disabled="!writable || disabled" :aria-label="'Override ' + field.title" @change="toggle(field.key)">{{ field.title }}</label>
          <div><input v-if="fields[field.key]!.enabled" v-model="fields[field.key]!.text" inputmode="decimal" :aria-label="field.title + ' limit'" :readonly="!writable" :disabled="disabled" maxlength="40"><span v-else class="source-note">Inherit</span> <span>{{ field.unit }}</span></div>
          <p class="source-note">Default: {{ status.defaults[field.key] === null ? 'Unlimited' : scaledValue(status.defaults[field.key], field.scale) }} · Saved effective: {{ status.effective[field.key] === null ? 'Unlimited' : scaledValue(status.effective[field.key], field.scale) }}</p>
        </div></div>
      </template>
      <div class="dialog-actions"><button type="button" :disabled="loading" @click="refresh">Refresh usage</button><button v-if="writable && !unsupported" type="button" :disabled="disabled" @click="Object.values(fields).forEach(field => field.enabled = false)">Reset overrides</button><button type="button" @click="close">Cancel</button><button v-if="writable" class="primary" :disabled="disabled || !!unsupported || !status || loading">Update notebook draft</button></div>
    </form>
  </dialog>
</template>
