<script setup lang="ts">
import { nextTick, onMounted, ref } from 'vue'
import { api, type Snapshot, type Project, type Membership } from './api'
import NotebookIcon from './NotebookIcon.vue'
import NotebookLibrary from './NotebookLibrary.vue'
import NotebookWorkspace from './NotebookWorkspace.vue'
import NotebookImport from './NotebookImport.vue'
import NotebookPreview from './NotebookPreview.vue'
import { formatDate, recordOpened } from './library'

const props = defineProps<{ initial: Snapshot }>()
const state = ref(props.initial)
const publicPreview = ref<InstanceType<typeof NotebookPreview> | null>(null), publicTemplate = ref('')
async function tryPublic(id: string) { publicTemplate.value = id; await nextTick(); publicPreview.value?.show() }
const busy = ref(false)
const error = ref(props.initial.auth_error ? 'GitHub sign-in was not completed. Please try again.' : '')
const notice = ref('')
const title = ref(state.value.project?.title || '')
const newTitle = ref('')
const accountId = ref('')
const role = ref<'editor' | 'viewer'>('viewer')
const members = ref<Membership[]>([])
const membersLoaded = ref(false)
const library = ref<InstanceType<typeof NotebookLibrary>>()
const createDialog = ref<HTMLDialogElement>()
const newTitleInput = ref<HTMLInputElement>()
const notebook = ref<InstanceType<typeof NotebookWorkspace>>()
const notebookDirty = ref(false)
const importer = ref<InstanceType<typeof NotebookImport>>()
function imported(project: Project) { location.assign(`/projects/${encodeURIComponent(project.id)}`) }
const endpoint = () => `/api/projects/${encodeURIComponent(state.value.project!.id)}`

async function act(action: () => Promise<void>) {
  if (busy.value) return
  busy.value = true
  error.value = ''
  notice.value = ''
  try { await action() } catch (cause) { error.value = cause instanceof Error ? cause.message : 'The request failed.' }
  finally { busy.value = false }
}
async function login() {
  await act(async () => {
    const result = await api<{ authorize_url: string }>('/auth/github', 'POST')
    location.assign(result.authorize_url)
  })
}
async function logout() {
  if (notebookDirty.value && !window.confirm('Discard unsaved notebook changes and sign out?')) return
  await act(async () => { await api('/auth/logout', 'POST'); notebook.value?.allowNavigation(); location.assign('/') })
}
async function showCreate() {
  newTitle.value = ''
  error.value = ''
  createDialog.value?.showModal()
  await nextTick()
  newTitleInput.value?.focus()
}
function closeCreate() {
  if (busy.value) return
  createDialog.value?.close()
  error.value = ''
}
async function create() {
  if (!newTitle.value.trim()) return
  await act(async () => {
    const result = await api<{ project: Project }>('/api/projects', 'POST', { title: newTitle.value.trim() })
    const path = `/projects/${encodeURIComponent(result.project.id)}`
    let setupPending = false
    try { await api(`/api${path}/notebook`, 'POST', {}) }
    catch { setupPending = true } // The catalog project remains recoverable if core is offline.
    location.assign(path + (setupPending ? '?notebook_setup=retry' : ''))
  })
}
async function refreshLibrary() {
  await act(async () => { state.value.projects = (await api<{ projects: Project[] }>('/api/projects')).projects })
}
async function rename() {
  if (!title.value.trim()) return
  await act(async () => {
    const result = await api<{ project: Project }>(endpoint(), 'PATCH', { title: title.value.trim() })
    state.value.project = result.project
    title.value = result.project.title
    notice.value = 'Project title saved.'
  })
}
async function loadMembers() {
  members.value = (await api<{ memberships: Membership[] }>(endpoint() + '/memberships')).memberships
  membersLoaded.value = true
}
async function grant() {
  await act(async () => {
    await api(endpoint() + '/memberships', 'POST', { account_id: accountId.value.trim(), role: role.value })
    accountId.value = ''
    await loadMembers()
    notice.value = 'Project access updated.'
  })
}
async function revoke(id: string) {
  await act(async () => {
    await api(endpoint() + '/memberships/' + encodeURIComponent(id), 'DELETE')
    await loadMembers()
    notice.value = 'Access removed.'
  })
}
async function copyAccountId() {
  await act(async () => {
    await navigator.clipboard.writeText(state.value.account!.id)
    notice.value = 'Account ID copied.'
  })
}
onMounted(() => {
  if (state.value.project && state.value.account) recordOpened(state.value.account.id, state.value.project.id)
  if (state.value.project?.permissions.manage) void act(loadMembers)
})
</script>

<template>
  <div class="workspace" data-testid="notebook-web" :aria-busy="busy">
    <header class="topbar">
      <a class="brand" href="/" aria-label="Sputnik Notebook home"><NotebookIcon name="book" /><span>Sputnik Notebook</span></a>
      <div v-if="state.account" class="identity">
        <span class="account-name"><NotebookIcon name="github" /><span data-testid="account-name">{{ state.account.name || state.account.login }}</span></span>
        <span class="topbar-divider" aria-hidden="true"></span>
        <button class="plain sign-out" :disabled="busy" @click="logout">Sign out</button>
      </div>
      <span v-else class="host-label">Server workspace</span>
    </header>

    <div v-if="error && !createDialog?.open" class="message error" role="alert">{{ error }}</div>
    <p v-if="notice" class="message notice" role="status">{{ notice }}</p>

    <div v-if="!state.project" class="welcome-screen">
      <section class="welcome" aria-labelledby="welcome-title">
        <div class="welcome-icon"><NotebookIcon name="book" /></div>
        <h1 id="welcome-title">Sputnik Notebook</h1>
        <p class="welcome-subtitle">A quiet workspace for interactive Sputnik programs.</p>
        <div v-if="state.account" class="welcome-actions">
          <button class="primary" :disabled="busy" @click="showCreate"><NotebookIcon name="plus" />New Notebook</button>
          <button :disabled="busy" @click="importer?.show()"><NotebookIcon name="folder" />Import Notebook…</button>
          <button :disabled="!state.projects.length" @click="library?.focusSearch()"><NotebookIcon name="folder" />Open Notebook</button>
        </div>
        <div v-else-if="state.sign_in_available !== false" class="welcome-actions">
          <button class="primary github-login" :disabled="busy" @click="login"><NotebookIcon name="github" />Continue with GitHub</button>
        </div>
      </section>

      <template v-if="state.account">
        <NotebookLibrary ref="library" :projects="state.projects" :account-id="state.account.id" :busy="busy" @refresh="refreshLibrary" />
        <p class="library-note">Your projects and the notebooks shared with you, together in one workspace.</p>
        <details class="account-details">
          <summary>Account details</summary>
          <div class="account-card"><span>Signed in as <strong>@{{ state.account.login }}</strong></span>
            <span class="account-id-label">Account ID for sharing</span>
            <div class="copy-field"><code data-testid="account-id">{{ state.account.id }}</code>
              <button class="icon-button plain" aria-label="Copy account ID" title="Copy account ID" :disabled="busy" @click="copyAccountId"><NotebookIcon name="copy" /></button></div>
          </div>
        </details>
      </template>
      <template v-else>
        <section v-if="state.public_templates?.length" class="public-welcome" aria-labelledby="public-title">
          <h2 id="public-title">Try Sputnik without signing in</h2>
          <p>Open a temporary notebook. This browser session shares 60 seconds of computation across copies. Your edits do not change the published template.</p>
          <div class="welcome-actions"><button v-for="template in state.public_templates" :key="template.id" @click="tryPublic(template.id)">Try {{ template.title }}</button></div>
        </section>
        <section v-if="state.sign_in_available !== false" class="guest-library">
          <NotebookIcon name="book" />
          <h2>Your notebooks, together.</h2>
          <p>Sign in to create projects and share access to your work.</p>
          <span class="guest-detail">A private library in your server workspace.</span>
        </section>
        <p class="library-note">Local notebooks stay in the desktop app. Sharing them is always your choice.</p>
      </template>
    </div>

    <div v-else class="project-screen">
      <a class="back" href="/"><NotebookIcon name="back" />Notebook Library</a>
      <section class="project-heading">
        <div class="heading-icon"><NotebookIcon name="book" /></div>
        <div><h1 data-testid="project-heading">{{ state.project.title }}</h1><p>Server workspace<span class="dot" aria-hidden="true">·</span>{{ state.project.permissions.write ? 'Can edit project details' : 'Read-only access' }}</p></div>
        <span class="role-badge">{{ state.project.role }}</span>
      </section>
      <NotebookWorkspace ref="notebook" :project="state.project" :account-id="state.account?.id || 'anonymous'" @dirty="notebookDirty = $event" @resume-import="importer?.show($event)" />
      <details class="project-settings">
        <summary>Project details &amp; access</summary>
      <section class="panel project-metadata" aria-labelledby="details-title" data-testid="project-metadata">
        <div class="panel-heading"><h2 id="details-title">Project details</h2><span class="subtle-label">Server project</span></div>
        <form v-if="state.project.permissions.write" class="rename-form" @submit.prevent="rename">
          <label for="project-title">Project title</label>
          <div class="fields"><input id="project-title" v-model="title" maxlength="200" required :disabled="busy">
            <button :disabled="busy || !title.trim() || title.trim() === state.project.title">Save title</button></div>
        </form>
        <dl class="metadata-grid">
          <div v-if="!state.project.permissions.write"><dt>Project title</dt><dd>{{ state.project.title }}</dd></div>
          <div><dt>Project ID</dt><dd><code>{{ state.project.id }}</code></dd></div>
          <div><dt>Owner account</dt><dd><code>{{ state.project.owner_account_id }}</code><span v-if="state.project.role === 'owner'" class="you-label">You</span></dd></div>
          <div><dt>Created</dt><dd><time :datetime="new Date(state.project.created_at * 1000).toISOString()">{{ formatDate(state.project.created_at) }}</time></dd></div>
          <div><dt>Updated</dt><dd><time :datetime="new Date(state.project.updated_at * 1000).toISOString()">{{ formatDate(state.project.updated_at) }}</time></dd></div>
        </dl>
      </section>
      <section v-if="state.project.permissions.manage" class="panel sharing" aria-labelledby="access-title">
        <div class="panel-heading"><h2 id="access-title">Project access</h2><span class="subtle-label">Owner controls</span></div>
        <p class="section-description">Share with an existing account using their account ID.</p>
        <p class="access-policy">Editors can edit project details. Viewers have read-only access.</p>
        <form class="sharing-form" @submit.prevent="grant">
          <div class="form-field"><label for="share-account">Account ID</label><input id="share-account" v-model="accountId" placeholder="Paste an account ID" required :disabled="busy"></div>
          <div class="form-field"><label for="share-role">Access role</label><select id="share-role" v-model="role" :disabled="busy"><option value="viewer">Viewer</option><option value="editor">Editor</option></select></div>
          <button :disabled="busy || !accountId.trim()">Grant access</button>
        </form>
        <ul v-if="members.length" class="members" aria-label="Shared access">
          <li v-for="member in members" :key="member.account_id"><code>{{ member.account_id }}</code><span class="role-badge">{{ member.role }}</span>
            <button class="plain text-button" :disabled="busy" :aria-label="`Remove access for ${member.account_id}`" @click="revoke(member.account_id)">Remove access</button>
          </li>
        </ul>
        <p v-else-if="membersLoaded" class="private-note">Only you have access to this project.</p>
        <p v-else class="private-note">{{ busy ? 'Loading project access…' : 'Could not load project access.' }} <button v-if="!busy" class="text-button" @click="act(loadMembers)">Try again</button></p>
      </section>
      </details>
    </div>
    <footer>Sputnik Notebook<span aria-hidden="true">·</span>Server workspace</footer>

    <NotebookImport v-if="state.account" ref="importer" :account-id="state.account.id" @complete="imported" />
    <NotebookPreview v-if="!state.account && publicTemplate" ref="publicPreview" :public-template="publicTemplate" :enabled="true" />
    <dialog v-if="state.account && !state.project" ref="createDialog" class="create-dialog" aria-labelledby="create-title" aria-describedby="create-description" @cancel.prevent="closeCreate">
      <form @submit.prevent="create">
        <div class="dialog-heading"><div class="heading-icon"><NotebookIcon name="book" /></div>
          <button type="button" class="icon-button plain" aria-label="Close new notebook" :disabled="busy" @click="closeCreate"><NotebookIcon name="close" /></button></div>
        <h2 id="create-title">New Notebook</h2>
        <p id="create-description">Create a notebook in your server workspace.</p>
        <label for="new-title">Notebook name</label>
        <input id="new-title" ref="newTitleInput" v-model="newTitle" placeholder="Untitled Notebook" maxlength="200" required :disabled="busy">
        <p v-if="error" class="dialog-error" role="alert">{{ error }}</p>
        <div class="dialog-actions"><button type="button" :disabled="busy" @click="closeCreate">Cancel</button>
          <button class="primary" :disabled="busy || !newTitle.trim()">{{ busy ? 'Creating…' : 'Create Notebook' }}</button></div>
      </form>
    </dialog>
  </div>
</template>
