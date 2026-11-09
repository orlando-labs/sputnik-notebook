<script setup lang="ts">
import { computed, nextTick, ref } from 'vue'
import { attachment, type ProjectFile } from './sources'
const props = defineProps<{
  files: ProjectFile[]; writable: boolean; disabled: boolean
  moveFolder: (from: string, to: string) => Promise<void>; removeFolder: (path: string) => void
}>()
const emit = defineEmits<{ open: [path: string] }>()
const dialog = ref<HTMLDialogElement>(), folder = ref(''), revealed = ref('')
const moving = ref(false), destination = ref(''), busy = ref(false), error = ref('')
const parent = (path: string) => path.split('/').slice(0, -1).join('/')
const items = computed(() => {
  const prefix = folder.value ? folder.value + '/' : ''
  const children = new Map<string, { path: string; name: string; directory: boolean; size?: number }>()
  for (const file of props.files.filter(attachment)) {
    if (!file.path.startsWith(prefix)) continue
    const rest = file.path.slice(prefix.length), name = rest.split('/')[0]!
    children.set(name, rest.includes('/') ? { path: prefix + name, name, directory: true } : { path: file.path, name, directory: false, size: file.size })
  }
  return [...children.values()].sort((a, b) => Number(b.directory) - Number(a.directory) || a.name.localeCompare(b.name))
})
function browse(path: string) { folder.value = path; error.value = ''; moving.value = false }
function show(path = '') { browse(parent(path)); revealed.value = path; dialog.value?.showModal() }
function open(item: (typeof items.value)[number]) {
  if (item.directory) browse(item.path)
  else { dialog.value?.close(); emit('open', item.path) }
}
async function remove() {
  const previous = folder.value
  try {
    props.removeFolder(previous)
    await nextTick()
    if (!props.files.some(file => file.path.startsWith(previous + '/'))) browse(parent(previous))
  } catch (cause) { error.value = (cause as Error).message }
}
async function move() {
  if (busy.value || props.disabled) return
  busy.value = true; error.value = ''
  const path = destination.value.trim()
  try { await props.moveFolder(folder.value, path); browse(path) }
  catch (cause) { error.value = (cause as Error).message }
  finally { busy.value = false }
}
defineExpose({ show })
</script>

<template>
  <dialog ref="dialog" class="notebook-dialog" aria-labelledby="file-explorer-title" @cancel="busy && $event.preventDefault()">
    <div class="dialog-heading"><h2 id="file-explorer-title">File Explorer</h2><button class="plain icon-button" :disabled="busy" aria-label="Close file explorer" @click="dialog?.close()">×</button></div>
    <p><button v-if="folder" :disabled="busy" @click="browse(parent(folder))">Up one folder</button> <code>{{ folder || '/' }}</code></p>
    <nav class="project-file-list" aria-label="Folder contents">
      <button v-for="item in items" :key="item.path" class="plain sheet-link" :class="{ active: revealed === item.path }" :disabled="busy" @click="open(item)">
        <span>{{ item.name }}{{ item.directory ? '/' : '' }}</span><span v-if="item.size !== undefined" class="source-note">{{ item.size.toLocaleString() }} bytes</span>
      </button>
    </nav>
    <p v-if="!items.length" class="source-note">No attachments in this folder.</p>
    <p v-if="error" class="source-error" role="alert">{{ error }}</p>
    <form v-if="moving" @submit.prevent="move">
      <label for="folder-destination">Destination folder path</label><input id="folder-destination" v-model="destination" required :disabled="busy">
      <div class="dialog-actions"><button type="button" :disabled="busy" @click="moving = false">Cancel</button><button class="primary" :disabled="busy || disabled">Move folder</button></div>
    </form>
    <div v-else-if="folder && items.length && writable" class="dialog-actions">
      <button :disabled="disabled" @click="destination = folder; moving = true">Rename or move folder…</button>
      <button :disabled="disabled" @click="remove">Delete folder…</button>
    </div>
  </dialog>
</template>
