<script setup lang="ts">
import { computed, onUnmounted, ref, watch } from 'vue'
import { api, APIError } from './api'
import { newId } from './notebook'
const props = defineProps<{ projectId: string; accountId: string }>()
const emit = defineEmits<{ changed: []; permissions: [grants: string[]] }>()
interface Job { id: string; action: string; state: string; message: string }
interface Package { name: string; display_name?: string; version: string; variant: string | null; digest: string; scope?: 'shared' | 'local' }
interface Status { can_manage: boolean; native_allowed: boolean; package_scopes?: string[]; packages: Package[]; jobs: Job[] }
interface Build { variant: string; size?: number; native_mode?: string; shared_installed?: boolean; runtime_grants?: string[] | null; target: { os?: string; arch?: string }; host_selection: { compatible: boolean; reason: string; allow_native: boolean; build_from_source: boolean } }
interface Command { command_id: string; action: string; name: string; version: string; variant: string; scope?: 'shared' | 'local'; allow_native: boolean; build_from_source: boolean; allow_native_large: boolean }
const base = `/api/projects/${encodeURIComponent(props.projectId)}/dependencies`
const key = `sputnik.packages.pending.v1:${props.accountId}:${props.projectId}`
const dialog = ref<HTMLDialogElement>(), status = ref<Status | null>(null), busy = ref(false), error = ref('')
const name = ref(''), version = ref(''), variant = ref(''), releases = ref<{ version: string; yanked: boolean; shared_installed?: boolean }[]>([]), builds = ref<Build[]>([])
const scope = ref<'shared' | 'local'>('shared')
const native = ref(false), build = ref(false), large = ref(false), pending = ref<Command | null>(null), unknown = ref(false)
watch(variant, () => { native.value = false; build.value = false; large.value = false })
const selectedBuild = computed(() => builds.value.find(item => item.variant === variant.value))
const requiredGrants = computed(() => selectedBuild.value?.runtime_grants ?? (selectedBuild.value?.host_selection.allow_native ? ['ffi.call=*', 'ffi.load=*'] : []))
const reusesShared = computed(() => scope.value === 'shared' && selectedBuild.value?.shared_installed === true)
const missingPermissions = computed(() => {
  const item = selectedBuild.value
  if (!item) return 'Choose a compatible build.'
  if (!item.host_selection.compatible) return item.host_selection.reason
  const missing: string[] = []
  if (item.host_selection.allow_native && !native.value) missing.push('native code')
  if (!reusesShared.value && item.host_selection.build_from_source && !build.value) missing.push('building from source')
  if (!reusesShared.value && (item.size || 0) > 67_108_864 && !large.value) missing.push('packages larger than 64 MiB')
  return missing.length ? `This package requires explicit permission for: ${missing.join(', ')}.` : ''
})
let disposed = false, timer: ReturnType<typeof setTimeout> | undefined
try { const value = JSON.parse(sessionStorage.getItem(key) || 'null'); if (value && typeof value.command_id === 'string' && ['install_sputnik', 'remove_sputnik'].includes(value.action) && typeof value.name === 'string') pending.value = value } catch { /* A command can still be inspected in server job history. */ }
function remember(value: Command | null) { pending.value = value; unknown.value = false; try { if (value) sessionStorage.setItem(key, JSON.stringify(value)); else sessionStorage.removeItem(key) } catch { /* Optional recovery cache. */ } }
const running = () => status.value?.jobs.some(job => ['queued', 'running'].includes(job.state)) || false
async function refresh() {
  if (disposed) return
  if (timer) clearTimeout(timer)
  try {
    status.value = await api<Status>(base)
    if (pending.value) {
      const result = await api<{ command: { state: string; job?: Job } }>(`${base}/commands/${pending.value.command_id}`)
      if (result.command.state === 'accepted') { remember(null); emit('changed') }
      else unknown.value = true
    }
  } catch (cause) { if (!disposed) error.value = cause instanceof Error ? cause.message : 'Could not load dependencies.' }
  finally { if (!disposed && dialog.value?.open) timer = setTimeout(() => { void refresh() }, running() || pending.value ? 1000 : 4000) }
}
async function act(action: () => Promise<void>) {
  if (busy.value) return
  busy.value = true; error.value = ''
  try { await action() } catch (cause) { error.value = cause instanceof Error ? cause.message : 'The package request failed.' }
  finally { busy.value = false }
}
function lookup() { void act(async () => {
  releases.value = []; builds.value = []; version.value = ''; variant.value = ''
  const result = await api<{ versions: typeof releases.value }>(`${base}/catalog?name=${encodeURIComponent(name.value.trim())}`)
  releases.value = result.versions
  version.value = releases.value.find(release => !release.yanked)?.version || ''
  if (version.value) await loadBuilds()
}) }
async function loadBuilds() {
  builds.value = []; variant.value = ''; native.value = false; build.value = false; large.value = false
  if (!version.value) return
  const result = await api<{ recommended_variant: string | null; artifacts: Build[] }>(`${base}/catalog?name=${encodeURIComponent(name.value.trim())}&version=${encodeURIComponent(version.value)}`)
  builds.value = result.artifacts
  const shared = scope.value === 'shared' && result.artifacts.find(item => item.shared_installed && item.host_selection.compatible)
  variant.value = (shared && shared.variant) || result.recommended_variant || result.artifacts.find(item => item.host_selection.compatible)?.variant || ''
}
async function send(command: Command) {
  try {
    await api(base, 'POST', command); remember(null); emit('changed'); await refresh()
  } catch (cause) {
    // A definite rejection is safe to clear. Uncertain outcomes keep the exact command.
    if (cause instanceof APIError && cause.status >= 400 && cause.status < 500) remember(null)
    else { await refresh(); if (!pending.value) return }
    throw cause
  }
}
function install() { void act(async () => {
  if (!status.value?.can_manage || pending.value || running() || !version.value || missingPermissions.value) return
  const command: Command = { command_id: newId('package'), action: 'install_sputnik', name: name.value.trim(), version: version.value, variant: variant.value, scope: scope.value, allow_native: native.value, build_from_source: build.value, allow_native_large: large.value }
  remember(command); await send(command)
}) }
function remove(item: Package) {
  if (!window.confirm(`Remove ${item.name} ${item.version} from this notebook?`)) return
  void act(async () => {
    const command: Command = { command_id: newId('package'), action: 'remove_sputnik', name: item.name, version: item.version, variant: '', allow_native: false, build_from_source: false, allow_native_large: false }
    remember(command); await send(command)
  })
}
function show() { dialog.value?.showModal(); error.value = ''; void refresh() }
function close() { dialog.value?.close(); if (timer) clearTimeout(timer) }
onUnmounted(() => { disposed = true; if (timer) clearTimeout(timer) })
defineExpose({ show })
</script>
<template>
  <dialog ref="dialog" class="notebook-dialog dependencies-dialog" aria-labelledby="dependencies-title" @close="close">
    <div class="dialog-heading"><div><h2 id="dependencies-title">Dependencies</h2><p>Sputnik packages for this notebook</p></div><button class="plain icon-button" aria-label="Close dependencies" @click="close">×</button></div>
    <p v-if="error" class="source-error" role="alert">{{ error }}</p>
    <div v-if="pending" class="execution-message" role="status"><p>Checking the package command. An explicit retry uses the same command ID.</p><button :disabled="busy" @click="refresh">Check command</button><button v-if="unknown && status?.can_manage" :disabled="busy" @click="act(() => send(pending!))">Retry pending package command</button></div>
    <template v-if="status">
      <p v-if="!status.can_manage" class="source-note">Only the project owner can change dependencies.</p>
      <ul class="package-list" aria-label="Installed packages"><li v-for="item in status.packages" :key="`${item.name}@${item.version}/${item.variant}`"><div><strong :title="item.name">{{ item.display_name || item.name.split('/').at(-1) }}</strong><span>{{ item.version }}<template v-if="item.variant"> · {{ item.variant }}</template><template v-if="item.scope"> · {{ item.scope === 'shared' ? 'Shared' : 'This notebook' }}</template></span></div><button v-if="status.can_manage" :disabled="busy || !!pending || running()" :aria-label="`Remove package ${item.name}`" @click="remove(item)">Remove…</button></li></ul>
      <p v-if="!status.packages.length" class="source-note">No Sputnik packages installed.</p>
      <form v-if="status.can_manage" class="package-search" @submit.prevent="lookup"><label for="package-name">Registry package</label><div class="fields"><input id="package-name" v-model="name" @input="releases = []; builds = []; version = ''; variant = ''" required placeholder="notebook.ui" maxlength="257" :disabled="busy || !!pending"><button :disabled="busy || !!pending || !name.trim()">Find package</button></div></form>
      <div v-if="releases.length" class="package-selection"><label for="package-scope">Package storage</label><select id="package-scope" v-model="scope" :disabled="busy || !!pending"><option value="shared">Shared on server</option><option v-if="status.package_scopes?.includes('local')" value="local">This notebook only</option></select>
        <label for="package-version">Version</label><select id="package-version" v-model="version" :disabled="busy || !!pending" @change="act(loadBuilds)"><option v-for="release in releases" :key="release.version" :value="release.version" :disabled="release.yanked">{{ release.version }}{{ release.yanked ? ' (yanked)' : '' }}{{ release.shared_installed ? ' · Installed in shared store' : '' }}</option></select>
        <label for="package-variant">Build</label><select id="package-variant" v-model="variant" :disabled="busy || !!pending"><option value="">Automatic selection</option><option v-for="item in builds" :key="item.variant" :value="item.variant" :disabled="!item.host_selection.compatible">{{ item.variant }} · {{ item.target.os || 'portable' }} {{ item.target.arch || '' }}{{ item.host_selection.compatible ? '' : ' · incompatible' }}{{ item.shared_installed ? ' · Installed in shared store' : '' }}</option></select>
        <p v-if="reusesShared" class="source-note">This build is already installed in the shared store. No download is needed.</p>
        <div v-if="selectedBuild" aria-label="Required worker grants">
          <strong>Required worker grants</strong>
          <ul v-if="requiredGrants.length"><li v-for="grant in requiredGrants" :key="grant"><code>{{ grant }}</code></li></ul>
          <p v-else class="source-note">No runtime grants declared.</p>
          <button v-if="status.can_manage && requiredGrants.length" :disabled="busy || !!pending || running()" @click="close(); emit('permissions', requiredGrants)">Add package grants…</button>
        </div>
        <template v-if="status.native_allowed"><label v-if="selectedBuild?.host_selection.allow_native" class="auto-import-option"><input v-model="native" type="checkbox" :disabled="busy || !!pending">Allow native package</label><label v-if="!reusesShared && selectedBuild?.host_selection.build_from_source" class="auto-import-option"><input v-model="build" type="checkbox" :disabled="busy || !!pending">Build from source on server</label><label v-if="!reusesShared && (selectedBuild?.size || 0) > 67_108_864" class="auto-import-option"><input v-model="large" type="checkbox" :disabled="busy || !!pending">Allow packages up to 2 GiB</label></template>
        <p v-else class="source-note">Native installation and source builds are disabled by the server operator.</p>
        <p v-if="missingPermissions" role="status">{{ missingPermissions }}</p>
        <p v-if="selectedBuild?.host_selection.allow_native" class="source-note">Installation permission does not grant execution. This sheet also needs explicit native worker grants (ffi.call and ffi.load).</p>
        <button class="primary" :disabled="busy || !!pending || running() || !version || !!missingPermissions" @click="install">{{ reusesShared ? 'Use installed package' : 'Install package' }}</button>
      </div>
      <button v-if="status.can_manage" :disabled="busy || !!pending || running()" @click="close(); emit('permissions', [])">Native execution permissions…</button>
      <p class="source-note">Save source changes before running. Changed packages may require a worker restart. Python and Ruby manifests can be edited in Files.</p>
      <details v-if="status.jobs.length" open class="package-jobs"><summary>Package operations</summary><ul><li v-for="job in status.jobs" :key="job.id"><span>{{ job.action === 'install_sputnik' ? 'Install' : 'Remove' }}</span><strong>{{ job.state }}</strong><p v-if="job.message">{{ job.message }}</p></li></ul></details>
    </template>
    <div class="dialog-actions"><button :disabled="busy" @click="refresh">Refresh dependencies</button><button @click="close">Done</button></div>
  </dialog>
</template>
