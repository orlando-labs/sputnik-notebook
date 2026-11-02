<script setup lang="ts">
import { computed, onUnmounted, ref, watch } from 'vue'
import { api, APIError } from './api'
import { newId } from './notebook'
const props = defineProps<{ projectId: string; accountId: string; revision: string; sheets: { id: string; title: string }[]; sheetId: string; writable: boolean; disabled: boolean }>()
const emit = defineEmits<{ changed: [] }>()
interface Environment { id: string; state: string; created_at: number; python: boolean; ruby: boolean; message: string }
interface Status { revision: string; can_manage: boolean; preparation_allowed: boolean; environments: Environment[] }
interface Settings { revision: string; sheet_id: string; version: string; runtime_epoch: string | null; grants: string[]; allowed_grants: string[]; preserved_grants: number; environment_id: string | null; custom_environment: boolean; can_manage: boolean }
interface Command { kind: 'environment' | 'worker'; body: Record<string, unknown> & { command_id: string } }
const base = `/api/projects/${encodeURIComponent(props.projectId)}`
const key = `sputnik.runtime-settings.pending.v1:${props.accountId}:${props.projectId}`
const dialog = ref<HTMLDialogElement>(), status = ref<Status | null>(null), settings = ref<Settings | null>(null)
const sheet = ref(''), grants = ref<string[]>([]), environment = ref('keep'), error = ref(''), note = ref(''), busy = ref(false), loading = ref(false), confirming = ref(false)
const diagnostics = ref<{ id: string; lines: string[] } | null>(null), pending = ref<Command | null>(null), unknown = ref(false)
let disposed = false, generation = 0, timer: ReturnType<typeof setTimeout> | undefined, controller: AbortController | undefined
try { const value = JSON.parse(sessionStorage.getItem(key) || 'null'); if (['worker', 'environment'].includes(value?.kind) && typeof value.body?.command_id === 'string') pending.value = value } catch { /* Server receipts remain authoritative. */ }
const allowed = computed(() => props.writable && status.value?.can_manage && settings.value?.can_manage && !props.disabled && !busy.value && !loading.value && !pending.value && status.value.revision === props.revision && settings.value.revision === props.revision)
const preparing = computed(() => status.value?.environments.some(item => ['queued', 'installing'].includes(item.state)))
function remember(command: Command | null) { pending.value = command; unknown.value = false; try { if (command) sessionStorage.setItem(key, JSON.stringify(command)); else sessionStorage.removeItem(key) } catch { /* Optional local recovery. */ } }
function close() { dialog.value?.close(); controller?.abort(); generation++; clearTimeout(timer); loading.value = false; confirming.value = false; diagnostics.value = null }
function denied(cause: unknown) { if (cause instanceof APIError && [401, 403, 404].includes(cause.status)) { status.value = null; settings.value = null; close() } }
async function check() {
  if (!pending.value) return
  const result = await api<{ command: { state: string; kind: string } }>(`${base}/runtime-commands/${encodeURIComponent(pending.value.body.command_id)}`)
  if (disposed) return
  if (result.command.state === 'accepted' && result.command.kind === pending.value?.kind) { remember(null); note.value = 'Command accepted. Refresh settings to review the server state.'; emit('changed') }
  else unknown.value = true
}
async function refresh(reset = false) {
  const stamp = ++generation
  controller?.abort(); controller = new AbortController(); clearTimeout(timer); loading.value = reset || !settings.value
  try {
    const value = await api<Status>(`${base}/environments`, 'GET', undefined, controller.signal)
    const worker = await api<Settings>(`${base}/worker-settings?sheet=${encodeURIComponent(sheet.value)}`, 'GET', undefined, controller.signal)
    if (disposed || stamp !== generation) return
    status.value = value
    // Polling never rebases a local draft over another owner's changes.
    if (reset || !settings.value) { settings.value = worker; grants.value = [...worker.grants]; environment.value = 'keep'; confirming.value = false }
    if (!worker.can_manage) confirming.value = false
    await check()
  } catch (cause) { if (!disposed && stamp === generation) { error.value = cause instanceof Error ? cause.message : 'Could not read environments.'; denied(cause) } }
  finally { if (stamp === generation) loading.value = false; if (!disposed && dialog.value?.open && stamp === generation) timer = setTimeout(() => void refresh(), preparing.value || pending.value ? 1000 : 4000) }
}
async function act(action: () => Promise<void>) {
  if (busy.value) return
  busy.value = true; error.value = ''; note.value = ''
  try { await action() } catch (cause) { error.value = cause instanceof Error ? cause.message : 'The server request failed.'; denied(cause) }
  finally { busy.value = false }
}
async function send(command: Command) {
  try {
    await api(`${base}/${command.kind === 'worker' ? 'worker-settings' : 'environments'}`, command.kind === 'worker' ? 'PUT' : 'POST', command.body)
    if (disposed) return
    remember(null); confirming.value = false; emit('changed'); note.value = command.kind === 'worker' ? 'Worker reset. Its next explicit Run will start with the saved settings.' : 'Preparation requested. Existing workers keep their current environment.'
    await refresh(true)
  } catch (cause) {
    if (cause instanceof APIError && cause.status >= 400 && cause.status < 500) remember(null)
    else { try { await check(); if (!pending.value) { await refresh(true); return } } catch { /* Keep the exact command for explicit recovery. */ } }
    throw cause
  }
}
function prepare(retry: boolean) {
  if (!allowed.value || !status.value?.preparation_allowed || preparing.value) return
  const command: Command = { kind: 'environment', body: { command_id: newId('environment'), revision: props.revision, retry } }
  remember(command); void act(() => send(command))
}
function apply() {
  if (!allowed.value || !settings.value || !confirming.value) return
  const command: Command = { kind: 'worker', body: { command_id: newId('worker'), revision: settings.value.revision, sheet_id: settings.value.sheet_id, base_version: settings.value.version, runtime_epoch: settings.value.runtime_epoch, grants: [...grants.value], environment_id: environment.value } }
  remember(command); void act(() => send(command))
}
async function inspect(item: Environment) {
  await act(async () => { const result = await api<{ diagnostics: string[] }>(`${base}/environments/${encodeURIComponent(item.id)}`); if (!disposed && dialog.value?.open) diagnostics.value = { id: item.id, lines: result.diagnostics } })
}
function selectSheet() { settings.value = null; diagnostics.value = null; confirming.value = false; void refresh(true) }
function show(native = false) { sheet.value = props.sheetId || props.sheets[0]?.id || ''; status.value = null; settings.value = null; error.value = ''; note.value = native ? 'Native execution requires explicit ffi.call and ffi.load grants. Select the permitted grants below, then review and apply the worker reset.' : ''; dialog.value?.showModal(); void refresh(true) }
watch(() => props.writable, value => { if (!value) close() })
watch(() => props.revision, () => { confirming.value = false })
onUnmounted(() => { disposed = true; close() })
defineExpose({ show })
</script>
<template>
  <dialog ref="dialog" class="notebook-dialog environments-dialog" aria-labelledby="environments-title" @cancel.prevent="close" @close="close">
    <div class="dialog-heading"><div><h2 id="environments-title">Environments and worker settings</h2><p>Saved generations and settings for each sheet</p></div><button class="plain icon-button" aria-label="Close environments" @click="close">×</button></div>
    <p v-if="error" class="source-error" role="alert">{{ error }}</p><p v-if="note" role="status">{{ note }}</p>
    <div v-if="pending" class="execution-message" role="status"><p>Checking the command. Retry uses the original command ID.</p><button :disabled="busy" @click="act(check)">Check runtime command</button><button v-if="unknown && writable" :disabled="busy || disabled" @click="act(() => send(pending!))">Retry pending runtime command</button></div>
    <template v-if="status">
      <p v-if="!status.can_manage" class="source-note">Only the project owner can change environments and worker settings.</p>
      <p v-if="status.revision !== revision" role="alert">The saved notebook changed. Reload it before changing runtime settings.</p>
      <section aria-label="Prepared environments">
        <h3>Python and Ruby environments</h3><p class="source-note">Preparation uses manifests in the saved notebook. It may install packages on the server. It never runs cells or resets an existing worker.</p>
        <p v-if="!status.preparation_allowed" class="source-note">Preparation is disabled by the server operator.</p>
        <button v-if="status.can_manage && status.preparation_allowed" :disabled="!allowed || preparing" @click="prepare(false)">Prepare saved environment</button>
        <button v-if="status.can_manage && status.preparation_allowed && status.environments.some(item => ['failed','interrupted'].includes(item.state))" :disabled="!allowed || preparing" @click="prepare(true)">Retry saved environment</button>
        <p v-if="!status.environments.length" class="source-note">No prepared environment generations.</p>
        <ul class="environment-list"><li v-for="item in status.environments" :key="item.id"><div><strong>{{ item.python ? 'Python' : '' }}{{ item.python && item.ruby ? ' + ' : '' }}{{ item.ruby ? 'Ruby' : '' }}</strong> · {{ item.state }}<code>{{ item.id }}</code><p>{{ item.message }}</p></div><button :disabled="busy" :aria-label="`Inspect environment ${item.id}`" @click="inspect(item)">Inspect</button></li></ul>
        <div v-if="diagnostics" class="execution-message" aria-label="Environment diagnostics"><p v-for="line in diagnostics.lines" :key="line">{{ line }}</p><p class="source-note">Detailed installer logs are available to the server operator.</p></div>
      </section>
      <section aria-label="Worker settings"><h3>Worker settings</h3><label for="environment-sheet">Sheet</label><select id="environment-sheet" v-model="sheet" :disabled="busy || !!pending" @change="selectSheet"><option v-for="item in sheets" :key="item.id" :value="item.id">{{ item.title }}</option></select>
        <template v-if="settings">
          <label for="worker-environment">Environment for next worker</label><select id="worker-environment" v-model="environment" :disabled="!allowed || confirming"><option value="keep">Keep current setting{{ settings.custom_environment ? ' (configured by operator)' : settings.environment_id ? ' (prepared generation)' : ' (saved manifests)' }}</option><option value="default">Resolve saved notebook manifests</option><option v-for="item in status.environments.filter(item => item.state === 'ready')" :key="item.id" :value="item.id">{{ item.python ? 'Python' : '' }}{{ item.ruby ? ' Ruby' : '' }} · {{ item.id }}</option></select>
          <fieldset :disabled="!allowed || confirming"><legend>Worker grants allowed by the operator</legend><p v-if="!settings.allowed_grants.length" class="source-note">No grants can be changed through the web app.</p><label v-for="grant in settings.allowed_grants" :key="grant"><input v-model="grants" type="checkbox" :value="grant">{{ grant }}</label></fieldset>
          <p v-if="settings.preserved_grants" class="source-note">{{ settings.preserved_grants }} operator-configured grant(s) will be preserved.</p>
          <p class="source-note">Applying discards worker variables and pauses its services. Active runs must finish or be stopped first. The next Run is explicit.</p>
          <div v-if="confirming" class="execution-message" role="status"><p>Reset the worker for {{ sheets.find(item => item.id === sheet)?.title }} with these settings?</p><button :disabled="!allowed" @click="apply">Confirm settings and reset</button><button :disabled="busy" @click="confirming = false">Keep editing settings</button></div>
          <button v-else-if="status.can_manage" :disabled="!allowed" @click="confirming = true">Review settings and reset…</button>
        </template>
      </section>
    </template>
    <p v-if="loading && !status" role="status">Reading environments…</p><div class="dialog-actions"><button :disabled="busy || loading || !!pending" @click="error = ''; refresh(true)">Reload settings</button><button @click="close">Done</button></div>
  </dialog>
</template>
