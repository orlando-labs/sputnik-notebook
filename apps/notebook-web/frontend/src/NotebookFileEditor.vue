<script setup lang="ts">
import { ref } from 'vue'
import type { FileView } from './sources'
import NotebookCodeEditor from './NotebookCodeEditor.vue'
const props = defineProps<{ file: FileView | null; path: string; moduleId?: string; autoImport: boolean; loading: boolean; writable: boolean; disabled: boolean; changed: boolean }>()
const emit = defineEmits<{ text: [value: string]; autoImport: [value: boolean]; download: []; remove: []; relocate: [] }>()
const error = ref('')
function text(value: string) { if (!props.writable || props.disabled) return; error.value = ''; emit('text', value) }
</script>

<template>
  <section class="project-file-editor" aria-label="Project file" data-testid="project-file-editor">
    <div class="file-editor-heading"><div><span class="subtle-label">{{ moduleId ? 'Module source' : 'Bundled file' }}</span><p>{{ path }}</p></div><span v-if="changed" class="file-draft-label">Draft</span></div>
    <p v-if="loading && !file" class="source-note">Opening saved file…</p>
    <template v-else-if="file">
      <p v-if="error" class="source-error" role="alert">{{ error }}</p>
      <label class="sr-only" for="project-file-source">{{ moduleId ? `Module ${moduleId}` : `File ${path}` }}</label>
      <NotebookCodeEditor v-if="file.editable" source-id="project-file-source" class="module-source" :label="moduleId ? `Module ${moduleId}` : `File ${path}`" :model-value="file.text || ''" :rows="20" :readonly="!writable" :disabled="disabled" :sputnik="!!moduleId || path.endsWith('.s')" :max-bytes="1048576" @update:model-value="text($event)" />
      <pre v-else-if="file.preview !== null" class="file-preview">{{ file.preview }}<span v-if="file.truncated">… Preview limited to 64 KiB</span></pre>
      <div v-else class="file-binary"><p>Binary file · {{ file.size.toLocaleString() }} bytes</p><p>Download the original file to open it.</p></div>
      <div class="file-editor-actions">
        <label v-if="moduleId" class="auto-import-option"><input type="checkbox" :checked="autoImport" :disabled="!writable || disabled" @change="emit('autoImport', ($event.target as HTMLInputElement).checked)">Auto-import into sheets</label>
        <span v-else class="source-note">{{ file.size.toLocaleString() }} bytes{{ file.editable ? ' · UTF-8' : '' }}</span>
        <button :disabled="disabled" @click="emit('download')">Download file</button>
        <button v-if="writable" :disabled="disabled || loading" @click="emit('relocate')">Rename or move…</button>
        <button v-if="writable" :disabled="disabled" @click="emit('remove')">{{ moduleId ? 'Delete module…' : 'Delete file…' }}</button>
      </div>
      <p class="source-note">{{ moduleId ? 'Save the notebook, then restart its sheet worker to use changed modules.' : 'File changes are saved together with the notebook.' }}</p>
    </template>
    <p v-else class="source-note">Select a saved file or retry opening it.</p>
  </section>
</template>
