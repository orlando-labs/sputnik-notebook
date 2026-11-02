<script setup lang="ts">
import { computed, onUnmounted, ref, watch } from 'vue'
import { api, apiBlob } from './api'
import type { BoardContext } from './boards'
import type { CellPresentation } from './execution'
import { artifactRows } from './runtime-observation'
import { download } from './rich'
const props = defineProps<{ presentation: CellPresentation; context: BoardContext }>()
const entries = computed(() => artifactRows(props.presentation.result_table))
const preview = ref<{ id: string; text: string; size: number; truncated: boolean } | null>(null), error = ref(''), busy = ref(false)
let generation = 0, controller = new AbortController()
const enabled = computed(() => !!props.context.projectId && !!props.presentation.revision && props.context.observation?.connected === true)
function reset() { generation++; controller.abort(); controller = new AbortController(); preview.value = null; error.value = ''; busy.value = false }
watch(() => [props.presentation.identity, props.presentation.revision, props.context.projectId, props.context.observation?.connected, props.presentation.result_table], reset)
onUnmounted(() => { generation++; controller.abort() })
function url(path: string, save = false) { return `/api/projects/${encodeURIComponent(props.context.projectId!)}/notebook/${save ? 'download' : 'file'}?revision=${encodeURIComponent(props.presentation.revision!)}&path=${encodeURIComponent(path)}` }
async function read(entry: ReturnType<typeof artifactRows>[number], save = false) {
  if (!entry.safe || !enabled.value || busy.value) return
  const version = generation; busy.value = true; error.value = ''
  try {
    if (save) { const blob = await apiBlob(url(entry.path,true)); if (version === generation) download(blob, entry.path.split('/').at(-1) || 'artifact') }
    else { const value = await api<{ preview: string | null; size: number; truncated: boolean }>(url(entry.path), 'GET', undefined, controller.signal); if (version === generation) preview.value = { id: entry.id, text: (value.preview || 'Binary file · no text preview').slice(0,16000).replace(/[\uD800-\uDBFF]$/, ''), size: value.size, truncated: value.truncated || (value.preview?.length || 0) > 16000 } }
  } catch (cause) { if (version === generation) { preview.value = null; error.value = cause instanceof Error ? cause.message : 'Could not read the saved artifact.' } }
  finally { if (version === generation) busy.value = false }
}
</script>
<template>
  <div class="artifact-browser">
    <p class="source-note">Files referenced by the captured result · saved revision {{ presentation.revision?.slice(0,12) || 'unavailable' }}</p>
    <p v-if="!entries.length" class="rich-unavailable">Return records with path, name and optional caption from the source cell.</p>
    <div class="artifact-list"><article v-for="entry in entries" :key="entry.id"><strong>{{ entry.title }}</strong><p v-if="entry.caption">{{ entry.caption }}</p><p class="source-note">{{ entry.safe ? 'Saved project file' : 'External or invalid path · unavailable in web' }}</p><div class="observation-controls"><button :disabled="!entry.safe || !enabled || busy" @click="read(entry)">Preview</button><button :disabled="!entry.safe || !enabled || busy" @click="read(entry,true)">Save copy…</button></div><template v-if="preview?.id === entry.id"><p class="source-note">{{ preview.size }} bytes<span v-if="preview.truncated"> · preview limited</span></p><pre class="observation-output">{{ preview.text }}</pre></template></article></div>
    <p v-if="entries.length === 128" class="source-note">Display limited to 128 file references.</p>
    <p class="source-note">Only files bundled in this run's saved revision are readable. External paths and files created outside that bundle are unavailable.</p>
    <p v-if="presentation.stale" class="rich-stale-note">Previous run · stale</p><p v-if="error" role="alert" class="source-error">{{ error }}</p>
  </div>
</template>
