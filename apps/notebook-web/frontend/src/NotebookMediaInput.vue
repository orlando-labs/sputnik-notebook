<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import { apiBlob } from './api'
import type { BoardComponent } from './boards'
import { mediaFile, type MediaRuntime } from './media-inputs'
import NotebookAudio from './NotebookAudio.vue'
import NotebookAudioRecorder from './NotebookAudioRecorder.vue'
import NotebookImageAnnotator from './NotebookImageAnnotator.vue'
import NotebookAudioAnnotator from './NotebookAudioAnnotator.vue'
import NotebookCellDisplay from './NotebookCellDisplay.vue'
import type { CellPresentation } from './execution'
import type { PublishedAudio } from './audio'
import { download } from './rich'
import { assetID } from './shared-selection'
const props = defineProps<{ component: BoardComponent; boardId: string; runtime: MediaRuntime; disabled: boolean; presentation?: CellPresentation; selectedAsset?: string | null }>()
const emit = defineEmits<{ dirty: [value: boolean] }>()
const file = ref<HTMLInputElement>(), draft = ref<{ name: string; data: string; extension: string } | null>(null), clear = ref(false), busy = ref(false), error = ref(''), accepted = ref<{ name: string; data: string; extension: string }[]>([]), selected = ref(0), append = ref(false), recording = ref(false), annotating = ref(false)
const audio = computed(() => ['audio_input', 'audio_annotator'].includes(props.component.kind)), image = computed(() => ['image','image_carousel'].includes(props.component.kind))
const canEdit = computed(() => !props.disabled && (!image.value || props.component.image_allow_load === true))
const dirty = computed(() => draft.value !== null || clear.value || recording.value || annotating.value)
const boundAccepted = ref<{ name: string; data: string; extension: string } | null>(null)
const current = computed(() => !props.runtime.readable || clear.value ? null : draft.value || (props.selectedAsset === undefined ? accepted.value[selected.value] : boundAccepted.value) || null)
const filter = computed(() => audio.value ? 'audio/*' : image.value ? '.png,.jpg,.jpeg' : String(props.component.p1?.extensions || '').split(',').map(x => x.trim().replace(/^\./,'')).filter(Boolean).map(x => '.'+x).join(','))
const filePaths = computed(() => {
  try {
    const raw=props.runtime.values?.[props.component.input || ''], path=raw === undefined ? props.component.file_asset : JSON.parse(raw)
    return typeof path === 'string' && /^inputs\/web_[a-f0-9]{64}\.[a-z0-9]{1,16}$/.test(path) ? [{path,caption:path === props.component.file_asset ? String(props.component.file_name || 'Accepted file') : 'Accepted file'}] : []
  } catch { return [] }
})
const paths = computed(() => audio.value ? props.component.audio_asset ? [{path:String(props.component.audio_asset),caption:String(props.component.audio_name || 'Audio')}] : [] : image.value ? (props.component.image_items || []) as {path:string;caption:string}[] : filePaths.value)
const filePreview = computed(() => {
  if(audio.value || image.value || !current.value)return null
  const encoded=atob(current.value.data), truncated=encoded.length>65536
  const bytes=Uint8Array.from(encoded.slice(0,65536),c=>c.charCodeAt(0))
  try { const text=new TextDecoder('utf-8',{fatal:true}).decode(bytes,{stream:truncated}); return text.includes('\0') ? null : {text,truncated} } catch { return null }
})
const audioAsset = computed<PublishedAudio | null>(() => current.value && audio.value ? { id:'input-preview',caption:current.value.name,kind:'file',format:current.value.extension,data:current.value.data,position:0,volume:1,waveform:props.component.show_waveform !== false,loop:false,autoplay:false } : null)
const publishedIndex = ref(0)
const annotationOpen = ref(false)
const rawPublishedImages = computed(() => props.runtime.readable && !props.presentation?.active ? props.presentation?.rich.images.find(s => s.id === (props.component.image_id || props.component.id))?.images || [] : [])
const matchedPublished = ref<string[]>([])
watch([() => props.selectedAsset, () => rawPublishedImages.value.map(i => i.data || '').join('\0')], async () => { const expected = props.selectedAsset, values = rawPublishedImages.value; matchedPublished.value = []; if (!expected) return; const found = await Promise.all(values.map(async value => value.data && await assetID(value.data) === expected ? value.data : '')); if (expected === props.selectedAsset) matchedPublished.value = found.filter(Boolean) }, { immediate: true })
const publishedImages = computed(() => props.selectedAsset === undefined ? rawPublishedImages.value : rawPublishedImages.value.filter(value => matchedPublished.value.includes(value.data || '')))
watch(() => [props.selectedAsset, paths.value], () => { if (props.selectedAsset) { const index = paths.value.findIndex(p => p.path.includes('web_' + props.selectedAsset + '.')); if (index >= 0) selected.value = index } }, { immediate: true })
const annotationImage = computed(() => {
  if (draft.value || clear.value) return null
  const published = publishedImages.value[publishedIndex.value] || publishedImages.value[0]
  return published?.data ? { name: published.caption || 'Published image', extension: published.mime === 'image/png' ? 'png' : 'jpg', data: published.data } : current.value
})
let generation=0, disposed=false
function saveFile() { const item=current.value; if(item)download(new Blob([Uint8Array.from(atob(item.data),c=>c.charCodeAt(0))]),item.name) }
function reset() { draft.value=null; clear.value=false; error.value=''; if(file.value)file.value.value='' }
watch(dirty,value=>emit('dirty',value),{immediate:true})
watch([() => props.runtime.revision, () => JSON.stringify(paths.value), selected, () => props.runtime.readable, () => props.selectedAsset], async () => {
  const own=++generation; accepted.value=[]; boundAccepted.value=null
  if(!props.runtime.readable || props.selectedAsset === null)return
  if(selected.value >= paths.value.length)selected.value=0
  try {
    const expected=props.selectedAsset, direct=expected ? paths.value.findIndex(item => item.path.includes('web_'+expected+'.')) : -1
    const candidates=expected ? direct>=0?[direct]:paths.value.map((_,index)=>index) : [selected.value]
    for(const index of candidates) {
      if(disposed || own!==generation || !props.runtime.readable)return
      const item=paths.value[index]; if(!item)continue
      const blob=await apiBlob(`/api/projects/${encodeURIComponent(props.runtime.projectId)}/notebook/download?revision=${encodeURIComponent(props.runtime.revision)}&path=${encodeURIComponent(item.path)}`)
      const value=await mediaFile(new File([blob],item.path.split('/').at(-1)!))
      if(expected && await assetID(value.data)!==expected)continue
      if(!disposed && own===generation){ const entry={...value,name:item.caption||'Accepted media'};if(expected)boundAccepted.value=entry;else { const entries=[]; entries[index]=entry;accepted.value=entries } }
      break
    }
  }catch(cause){if(!disposed && own===generation)error.value=(cause as Error).message}
},{immediate:true})
async function chooseFile(value:File) {
  busy.value=true;error.value=''
  try {
    const item=await mediaFile(value)
    if(image.value && !['png','jpg','jpeg'].includes(item.extension))throw new Error('Choose a PNG or JPEG image.')
    if(!audio.value && !image.value && filter.value && !filter.value.split(',').includes('.'+item.extension))throw new Error('Choose a file with an allowed extension.')
    if(image.value){const bitmap=await createImageBitmap(value);bitmap.close()}
    draft.value={...item,name:value.name};clear.value=false
  }catch(cause){error.value=(cause as Error).message}
  finally{busy.value=false}
}
function choose(event:Event) { const value=(event.target as HTMLInputElement).files?.[0]; if(value)void chooseFile(value) }
async function apply() {
  if(!canEdit.value || !props.runtime.canApply || !dirty.value || busy.value || recording.value || annotating.value)return
  busy.value=true;error.value=''
  try {
    if(await props.runtime.apply({board_id:props.boardId,component_id:props.component.id,operation:clear.value?'clear':append.value&&image.value?'append':'replace',extension:draft.value?.extension||'bin',name:draft.value?.name||'',data:draft.value?.data||''}))reset()
    else error.value='The media update was not confirmed. Your draft is kept; check media command status.'
  }catch(cause){error.value=(cause as Error).message}
  finally{busy.value=false}
}
onBeforeUnmount(()=>{disposed=true;generation++;emit('dirty',false)})
</script>
<template>
  <section class="media-input" :aria-label="component.title + ' media input'" data-testid="media-input">
    <h3>{{ component.title }}</h3>
    <div class="media-input-actions"><button :disabled="!canEdit || busy || recording" @click="file?.click()">Choose {{ audio ? 'audio' : image ? 'image' : 'file' }}…</button><input ref="file" type="file" :accept="filter" :aria-label="'Choose ' + component.title" :disabled="!canEdit || busy || recording" hidden @change="choose"><button :disabled="!canEdit || busy || recording" @click="draft=null;clear=true">Clear</button></div>
    <NotebookAudioRecorder v-if="component.kind === 'audio_input' && component.audio_recording !== false" :disabled="!canEdit || busy || !runtime.readable" :identity="runtime.revision + boardId + component.id + String(component.audio_id)" @active="recording = $event" @captured="chooseFile" />
    <p class="source-note">{{ dirty ? 'Draft · not applied' : paths.length ? 'Accepted media' : 'No accepted media' }} · up to 16 MiB per file</p>
    <p v-if="clear">Clear on Apply</p><p v-else-if="current">{{ current.name }}</p>
    <details v-if="filePreview"><summary>Text preview{{ filePreview.truncated ? ' · first 64 KiB' : '' }}</summary><pre class="media-file-preview">{{ filePreview.text }}</pre></details>
    <NotebookAudio v-if="audioAsset && !recording && !annotationOpen" :asset="audioAsset" />
    <img v-else-if="image && current" class="media-input-image" :src="'data:image/' + (current.extension === 'png' ? 'png' : 'jpeg') + ';base64,' + current.data" :alt="current.name">
    <NotebookAudioAnnotator v-if="component.kind === 'audio_annotator'" :component="component" :board-id="boardId" :runtime="runtime" :source-key="paths.map(p => p.path).join()" :disabled="disabled || busy || !!draft || clear" @dirty="annotating=$event" @active="annotationOpen=$event" />
    <template v-if="image && component.image_annotator"><label v-if="publishedImages.length > 1">Published image to annotate<select v-model.number="publishedIndex" aria-label="Published image to annotate"><option v-for="(item,index) in publishedImages" :key="index" :value="index">{{ index + 1 }} · {{ item.caption }}</option></select></label><p v-if="publishedImages.length" class="source-note">Annotations use the latest completed publication.</p><NotebookImageAnnotator :component="component" :board-id="boardId" :runtime="runtime" :image="annotationImage" :disabled="disabled || busy || recording || !!draft || clear || !!presentation?.active" @dirty="annotating=$event" /></template>
    <NotebookCellDisplay v-if="image && !dirty && runtime.readable && presentation?.rich.images.length" :component="{ ...component, kind: 'image', title: 'Published ' + component.title }" :presentation="presentation" :selected-asset="selectedAsset" />
    <template v-if="component.kind === 'image_carousel'"><label v-if="paths.length>1 && selectedAsset === undefined">Accepted image<select v-model.number="selected" aria-label="Accepted image"><option v-for="(item,index) in paths" :key="index" :value="index">{{ index+1 }} · {{ item.caption }}</option></select></label><label><input v-model="append" type="checkbox" :disabled="!canEdit || busy || recording">Append to collection</label></template>
    <div class="media-input-actions"><button v-if="current && !audio && (!image || component.image_allow_save !== false)" @click="saveFile">Save file…</button><button :disabled="busy || recording || !dirty" @click="reset">Discard</button><button class="primary" :disabled="!canEdit || busy || recording || !dirty || !runtime.canApply" @click="apply">{{ busy ? 'Applying…' : 'Apply media' }}</button></div>
    <p class="source-note">Apply accepts a versioned input and keeps the original bytes. Run explicitly to use it.</p>
    <p v-if="dirty && !runtime.canApply" class="source-note">Save source changes and finish other parameter or media drafts before Apply. Wait for active work to finish.</p>
    <p v-if="error" class="source-error" role="status">{{ error }}</p>
  </section>
</template>
