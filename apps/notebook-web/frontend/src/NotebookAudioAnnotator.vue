<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, shallowRef, watch } from 'vue'
import { api } from './api'
import type { BoardComponent } from './boards'
import type { MediaRuntime } from './media-inputs'
import { audioBytes, pcm, sample, type PCM } from './audio'
import { audioAnnotationError, drawnSegment, type AudioAnnotations, type AudioSource } from './audio-annotations'
import { type AudioViewport } from './audio-analysis'
import { annotationNumber, type AnnotationClass } from './image-annotations'
import { documentJSON, parseDocumentJSON } from './document-json'
import { download } from './rich'
import NotebookAnnotationAttributes from './NotebookAnnotationAttributes.vue'
import analysisWorkerURL from './audio-analysis-worker.ts?worker&url'
const props = defineProps<{ component: BoardComponent; boardId: string; runtime: MediaRuntime; disabled: boolean; sourceKey: string }>()
const emit = defineEmits<{ dirty: [value: boolean]; active: [value: boolean] }>()
const dialog = ref<HTMLDialogElement>(), canvas = ref<HTMLCanvasElement>(), draft = ref<AudioAnnotations | null>(null), decoded = shallowRef<PCM | null>(null)
const selected = ref(''), open = ref(false), opening = ref(false), saving = ref(false), error = ref(''), analyzing = ref(false), playing = ref(false)
const spectral = ref(false), fft = ref(1024), range = ref(90), channel = ref(-1), viewport = ref<AudioViewport>({ start: 0, end: 1, low: 0, high: 4000 })
const history = ref<string[]>([]), redo = ref<string[]>([]), fieldErrors = ref<Record<string, boolean>>({})
const clone = <T,>(v: T) => parseDocumentJSON(documentJSON(v)) as T
const segment = computed(() => draft.value?.segments.find(s => s.id === selected.value))
const previewable = computed(() => !!draft.value && (!segment.value || Number.isInteger(segment.value.start_frame) && Number.isInteger(segment.value.end_frame) && segment.value.start_frame >= 0 && segment.value.start_frame < segment.value.end_frame && segment.value.end_frame <= draft.value.frames))
const invalid = computed(() => draft.value ? audioAnnotationError(draft.value, frozenComponent) : '')
const stale = computed(() => open.value && (props.runtime.revision !== frozenRevision || props.runtime.version !== frozenVersion || props.sourceKey !== frozenSource || documentJSON(props.component) !== frozenDefinition || !props.runtime.readable))
const dirty = computed(() => open.value && !!draft.value && (documentJSON(draft.value) !== baseline || Object.values(fieldErrors.value).some(Boolean)))
let frozenRevision = '', frozenVersion = '', frozenSource = '', frozenDefinition = '', baseline = '', generation = 0, disposed = false
let frozenComponent: BoardComponent = { id: '', kind: '', title: '' }, samples: Float32Array<ArrayBuffer>[] = [], worker: Worker | null = null, observer: ResizeObserver | null = null
let playback: AudioContext | null = null, node: AudioBufferSourceNode | null = null, timer: ReturnType<typeof setInterval> | undefined
let pointer: { frame: number; hz: number; id: number } | null = null
watch(dirty, v => emit('dirty', v), { flush: 'sync' })
watch(() => opening.value || open.value, value => emit('active', value), { flush: 'sync' })
function checkpoint() {
  if (!draft.value) return
  history.value.push(documentJSON(draft.value)); redo.value = []
  while (history.value.length > 30 || history.value.reduce((n, s) => n + s.length * 2, 0) > 8 * 1024 * 1024) history.value.shift()
}
function undo(back = true) {
  if (!draft.value) return
  const from = back ? history.value : redo.value, to = back ? redo.value : history.value
  if (!from.length) return
  to.push(documentJSON(draft.value)); draft.value = parseDocumentJSON(from.pop()!) as AudioAnnotations; fieldErrors.value = {}; stop()
}
function stop() {
  if (node) { node.onended = null; try { node.stop() } catch { /* Already finished. */ } node.disconnect(); node = null }
  playing.value = false
  const old = playback; playback = null; if (old) void old.close().catch(() => {})
}
async function play() {
  if (!draft.value || !samples.length || stale.value) return
  stop(); error.value = ''
  const own = generation, context = new AudioContext(); playback = context
  try {
    await context.resume()
    if (own !== generation || playback !== context || document.hidden || !dialog.value?.open) { stop(); return }
    const first = segment.value?.start_frame ?? 0, last = segment.value?.end_frame ?? draft.value.frames
    if (!Number.isInteger(first) || !Number.isInteger(last) || first < 0 || first >= last || last > draft.value.frames) throw new Error('Choose a valid temporal interval.')
    const buffer = context.createBuffer(samples.length, last - first, draft.value.sample_rate)
    samples.forEach((s, c) => buffer.copyToChannel(s.subarray(first, last), c))
    node = context.createBufferSource(); node.buffer = buffer; node.connect(context.destination); node.onended = stop; node.start(); playing.value = true
  } catch (cause) { stop(); error.value = (cause as Error).message }
}
function close() {
  if (saving.value) return
  generation++; stop(); worker?.terminate(); worker = null; observer?.disconnect(); observer = null
  if (timer) clearInterval(timer); timer = undefined
  dialog.value?.close(); open.value = false; opening.value = false; draft.value = null; decoded.value = null; samples = []; history.value = []; redo.value = []; fieldErrors.value = {}; pointer = null
}
async function show() {
  if (opening.value || props.disabled) return
  const own = ++generation; opening.value = true; error.value = ''
  frozenRevision = props.runtime.revision; frozenVersion = props.runtime.version; frozenSource = props.sourceKey; frozenDefinition = documentJSON(props.component); frozenComponent = clone(props.component)
  try {
    const result = await api<AudioSource & { data: string }>(`/api/projects/${encodeURIComponent(props.runtime.projectId)}/media-inputs/source?revision=${encodeURIComponent(frozenRevision)}&board=${encodeURIComponent(props.boardId)}&component=${encodeURIComponent(props.component.id)}`)
    if (disposed || own !== generation || !props.runtime.readable || props.runtime.revision !== frozenRevision || props.sourceKey !== frozenSource) return
    const value = pcm(audioBytes(result.data), 'f32le', result.sample_rate, result.channels)
    if (value.frames !== result.frames || value.bytes.length > 16 * 1024 * 1024 - 64) throw new Error('Decoded audio metadata mismatch.')
    const { data: _data, ...identity } = result, saved = frozenComponent.audio_annotations as AudioAnnotations | undefined
    identity.cell = parseDocumentJSON(String(identity.cell))
    const same = saved && ['asset', 'source', 'channel', 'cell', 'sample_rate', 'channels', 'frames'].every(key => documentJSON(saved[key]) === documentJSON(identity[key as keyof AudioSource]))
    const classes = clone((frozenComponent.annotation_classes ?? saved?.classes ?? []) as AnnotationClass[])
    const next: AudioAnnotations = { ...(same ? clone(saved) : {}), ...identity, version: 1, classes, segments: same ? clone(saved.segments) : [], transcript: same ? saved.transcript : '' }
    if (frozenComponent.audio_transcript_allowed === false) next.transcript = ''
    for (const s of next.segments) {
      if (frozenComponent.audio_segment_transcript_allowed === false) s.transcript = ''
      s.classes = s.classes.filter(id => classes.some(c => c.id === id)); const attributes: Record<string, Record<string, unknown>> = Object.create(null)
      for (const id of s.classes) {
        const values: Record<string, unknown> = Object.create(null)
        for (const a of classes.find(c => c.id === id)!.attributes) { const entry = s.attributes[id]?.[a.id]; if (a.type === 'text' && typeof entry === 'string' || a.type === 'number' && annotationNumber(entry) || a.type === 'boolean' && typeof entry === 'boolean' || a.type === 'choice' && typeof entry === 'string' && a.options.includes(entry)) values[a.id] = entry }
        attributes[id] = values
      }
      s.attributes = attributes
    }
    draft.value = next; decoded.value = value; samples = Array.from({ length: value.channels }, (_, c) => Float32Array.from({ length: value.frames }, (_, i) => sample(value, i, c)))
    baseline = documentJSON(next); selected.value = next.segments[0]?.id || ''; history.value = []; redo.value = []; fieldErrors.value = {}; spectral.value = frozenComponent.audio_view === 'spectrogram'; fft.value = Number(frozenComponent.audio_fft_size || 1024); channel.value = -1
    fit(); open.value = true; await nextTick(); dialog.value?.showModal(); if (dialog.value) dialog.value.scrollTop = 0
    observer = new ResizeObserver(render); if (canvas.value) observer.observe(canvas.value)
    timer = setInterval(() => { if (document.hidden || !dialog.value?.getClientRects().length) stop() }, 150)
    render()
  } catch (cause) { if (own === generation) error.value = (cause as Error).message } finally { if (own === generation) opening.value = false }
}
function render() {
  worker?.terminate(); worker = null
  if (!open.value || !draft.value || !canvas.value || !samples.length) return
  const target = canvas.value; analyzing.value = true
  const entry = new URL(analysisWorkerURL, window.location.href)
  const url = import.meta.env.DEV ? new URL('/audio-analysis-worker.js', window.location.origin) : entry
  if (import.meta.env.DEV) url.searchParams.set('source', entry.href)
  let own: Worker
  try { own = new Worker(url, { type: 'module' }) } catch { analyzing.value = false; error.value = 'Audio analysis Worker could not start.'; return }
  worker = own
  own.onmessage = event => {
    if (worker !== own || !open.value) return
    analyzing.value = false
    if (event.data.error) { error.value = event.data.error; return }
    const { columns, rows, rgba, waveform } = event.data
    target.width = columns; target.height = 260
    const context = target.getContext('2d')!; context.clearRect(0, 0, columns, 260)
    if (spectral.value) {
      const raster = document.createElement('canvas'); raster.width = columns; raster.height = rows
      raster.getContext('2d')!.putImageData(new ImageData(rgba, columns, rows), 0, 0); context.imageSmoothingEnabled = false; context.drawImage(raster, 0, 0, columns, 260)
    } else {
      context.strokeStyle = getComputedStyle(target).color; context.beginPath()
      for (let x = 0; x < columns; x++) { context.moveTo(x, 130 - Math.min(1, waveform[x * 2 + 1]) * 124); context.lineTo(x, 130 - Math.max(-1, waveform[x * 2]) * 124) } context.stroke()
    }
    own.terminate(); if (worker === own) worker = null
  }
  own.onerror = () => { if (worker === own) { analyzing.value = false; error.value = 'Audio analysis Worker failed.'; own.terminate(); worker = null } }
  own.postMessage({ samples, request: { rate: draft.value.sample_rate, channel: channel.value, viewport: { ...viewport.value }, fft: fft.value, range: range.value, spectral: spectral.value, columns: Math.max(1, Math.ceil(target.getBoundingClientRect().width)) } })
}
function fit() { if (draft.value) viewport.value = { start: 0, end: draft.value.frames, low: 0, high: draft.value.sample_rate / 2 } }
function zoom(factor: number) {
  if (!draft.value) return
  const v = viewport.value, length = Math.max(1, Math.min(draft.value.frames, Math.round((v.end - v.start) * factor))), center = (v.end + v.start) / 2
  const start = Math.max(0, Math.min(draft.value.frames - length, Math.round(center - length / 2))); viewport.value = { ...v, start, end: start + length }
}
function pan(factor: number) { if (!draft.value) return; const v = viewport.value, length = v.end - v.start, start = Math.max(0, Math.min(draft.value.frames - length, Math.round(v.start + length * factor))); viewport.value = { ...v, start, end: start + length } }
function zoomSelection() { if (segment.value) viewport.value = { start: segment.value.start_frame, end: segment.value.end_frame, low: segment.value.low_hz ?? 0, high: segment.value.high_hz ?? draft.value!.sample_rate / 2 } }
watch([viewport, spectral, fft, range, channel], () => { stop(); render() }, { deep: true })
watch(selected, () => { fieldErrors.value = {}; stop() })
function point(event: PointerEvent) { const box = (event.currentTarget as SVGElement).getBoundingClientRect(), v = viewport.value; return { frame: v.start + Math.max(0, Math.min(1, (event.clientX - box.left) / box.width)) * (v.end - v.start), hz: v.high - Math.max(0, Math.min(1, (event.clientY - box.top) / box.height)) * (v.high - v.low) } }
function down(event: PointerEvent) { if (event.button || stale.value || saving.value) return; event.preventDefault(); pointer = { ...point(event), id: event.pointerId }; (event.currentTarget as SVGElement).setPointerCapture(event.pointerId) }
function up(event: PointerEvent) { if (!pointer || pointer.id !== event.pointerId || !draft.value) return; const s = drawnSegment(pointer, point(event), draft.value.frames, draft.value.sample_rate, spectral.value); pointer = null; if (s && draft.value.segments.length < 1000) { checkpoint(); draft.value.segments.push(s); selected.value = s.id } }
function add() { if (!draft.value || draft.value.segments.length >= 1000) return; checkpoint(); const v = viewport.value, s = drawnSegment({ frame: v.start, hz: v.low }, { frame: v.end, hz: v.high }, draft.value.frames, draft.value.sample_rate, spectral.value)!; draft.value.segments.push(s); selected.value = s.id }
function change(key: string, value: unknown) { if (segment.value) { checkpoint(); segment.value[key] = value; stop() } }
function numeric(key: string, event: Event, seconds = false) {
  const text = (event.target as HTMLInputElement).value.replace(',', '.'), value = Number(text), valid = !!text.trim() && /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(text) && Number.isFinite(value) && (seconds || !key.endsWith('_frame') || Number.isInteger(value))
  fieldErrors.value[key] = !valid
  if (valid) change(key, seconds ? Math.round(value * draft.value!.sample_rate) : value)
}
function assign(id: string, checked: boolean) { if (!segment.value) return; checkpoint(); segment.value.classes = checked ? [...segment.value.classes, id] : segment.value.classes.filter(c => c !== id); if (!checked) { delete segment.value.attributes[id]; for (const key in fieldErrors.value) if (key.startsWith(id + ':')) delete fieldErrors.value[key] } }
function attribute(classId: string, id: string, value: unknown) { if (!segment.value) return; checkpoint(); const attributes = clone(segment.value.attributes), values = clone(attributes[classId] || {}); Object.defineProperty(values, id, { value, writable: true, configurable: true, enumerable: true }); Object.defineProperty(attributes, classId, { value: values, writable: true, configurable: true, enumerable: true }); segment.value.attributes = attributes }
function remove() { if (!draft.value || !segment.value) return; checkpoint(); draft.value.segments = draft.value.segments.filter(s => s.id !== selected.value); selected.value = draft.value.segments[0]?.id || ''; fieldErrors.value = {} }
function rect(s: AudioAnnotations['segments'][number]) { const v = viewport.value; return { x: (s.start_frame - v.start) / (v.end - v.start) * 1000, width: (s.end_frame - s.start_frame) / (v.end - v.start) * 1000, y: spectral.value && s.high_hz != null ? (v.high - s.high_hz) / (v.high - v.low) * 260 : 0, height: spectral.value && s.low_hz != null ? (s.high_hz! - s.low_hz) / (v.high - v.low) * 260 : 260 } }
function exportJSON() { if (draft.value) download(new Blob([documentJSON(draft.value)], { type: 'application/json' }), 'audio-annotations.json') }
async function apply() {
  if (!draft.value || invalid.value || stale.value || Object.values(fieldErrors.value).some(Boolean) || saving.value || props.disabled || !props.runtime.canApply) return
  stop(); saving.value = true; error.value = ''
  const bytes = new TextEncoder().encode(documentJSON(draft.value)); let binary = ''; for (let i = 0; i < bytes.length; i += 16384) binary += String.fromCharCode(...bytes.subarray(i, i + 16384))
  try { if (await props.runtime.apply({ board_id: props.boardId, component_id: props.component.id, operation: 'annotations', extension: 'json', name: 'audio-annotations.json', data: btoa(binary) }, { revision: frozenRevision, version: frozenVersion })) { saving.value = false; close() } else error.value = 'Annotations were not confirmed. Keep or export this draft; check media command status.' } catch (cause) { error.value = (cause as Error).message } finally { saving.value = false }
}
watch(() => props.runtime.readable, value => { if (!value) { saving.value = false; close() } })
watch(stale, value => { if (value) stop() })
const theme = window.matchMedia('(prefers-color-scheme: dark)')
theme.addEventListener('change', render)
onBeforeUnmount(() => { theme.removeEventListener('change', render); disposed = true; saving.value = false; close(); emit('dirty', false); emit('active', false) })
</script>
<template>
  <div><button :disabled="disabled || opening || !runtime.readable" @click="show">{{ opening ? 'Opening audio…' : 'Annotate audio…' }}</button><p v-if="error && !open" class="source-error" role="status">{{ error }}</p></div>
  <dialog ref="dialog" class="notebook-dialog audio-annotation-dialog" aria-label="Audio annotations" @cancel.prevent="close">
    <template v-if="draft"><header><h2>Audio annotations</h2><button :disabled="saving" aria-label="Close audio annotations" @click="close">Discard &amp; close</button></header>
      <p>{{ component.title }} · {{ draft.sample_rate }} Hz · {{ draft.channels }} channel(s) · {{ draft.frames }} frames · {{ (draft.frames / draft.sample_rate).toFixed(3) }} s</p>
      <p v-if="stale" class="source-error" role="status">The source or accepted inputs changed. This draft keeps its original audio. Export or discard it, then reopen before Apply.</p>
      <div class="annotation-toolbar"><label>Display<select v-model="spectral" aria-label="Audio annotation display"><option :value="false">Waveform</option><option :value="true">Spectrogram · plasma</option></select></label><label>Channel<select v-model.number="channel" aria-label="Analysis channel"><option :value="-1">Mono mix</option><option v-for="c in draft.channels" :key="c" :value="c - 1">Channel {{ c }}</option></select></label><label v-if="spectral">FFT<select v-model.number="fft" aria-label="FFT size"><option v-for="n in [256,512,1024,2048,4096]" :key="n" :value="n">{{ n }}</option></select></label><label v-if="spectral">Range<select v-model.number="range" aria-label="Spectrogram range"><option v-for="n in [60,90,120]" :key="n" :value="n">{{ n }} dBFS</option></select></label></div>
      <div class="annotation-toolbar"><button :disabled="saving || stale || draft.segments.length >= 1000" @click="add">Add segment</button><button :disabled="!history.length || saving" @click="undo()">Undo</button><button :disabled="!redo.length || saving" @click="undo(false)">Redo</button><button @click="zoom(.5)">Zoom in</button><button @click="zoom(2)">Zoom out</button><button @click="pan(-.5)">Pan earlier</button><button @click="pan(.5)">Pan later</button><button @click="fit">Fit</button><button :disabled="!segment || !!invalid" @click="zoomSelection">Zoom to selection</button><button :disabled="stale || !previewable" @click="playing ? stop() : play()">{{ playing ? 'Stop preview' : 'Play selection' }}</button></div>
      <p class="source-note" role="status">{{ analyzing ? 'Rendering…' : 'Drag to add a segment. Click a region to select it.' }} {{ spectral ? `Δf ${(draft.sample_rate / fft).toFixed(3)} Hz · 0 dBFS = full-scale sinusoid` : '' }} · Playback uses the temporal interval.</p>
      <div class="audio-annotation-plot"><canvas ref="canvas" aria-hidden="true" /><svg viewBox="0 0 1000 260" preserveAspectRatio="none" role="img" aria-label="Audio annotation canvas" @pointerdown="down" @pointerup="up" @pointercancel="pointer = null"><g v-for="s in draft.segments" :key="s.id" :class="{ selected: s.id === selected }" @pointerdown.stop="selected = s.id"><rect v-bind="rect(s)" vector-effect="non-scaling-stroke" /></g></svg></div>
      <p class="audio-annotation-axis">{{ (viewport.start / draft.sample_rate).toFixed(6) }} – {{ (viewport.end / draft.sample_rate).toFixed(6) }} s <span>{{ viewport.low.toFixed(3) }} – {{ viewport.high.toFixed(3) }} Hz</span></p>
      <div class="audio-annotation-metadata"><fieldset :disabled="saving || stale"><legend>Segments · {{ draft.segments.length }} / 1,000</legend><label>Selected segment<select v-model="selected" aria-label="Selected segment"><option value="">Choose…</option><option v-for="(s,i) in draft.segments" :key="s.id" :value="s.id">{{ i + 1 }} · {{ s.title || 'Segment' }}</option></select></label>
        <template v-if="segment"><label>Title<input :value="segment.title" aria-label="Segment title" @input="change('title', ($event.target as HTMLInputElement).value)"></label><div class="annotation-coordinates"><label v-for="key in ['start_frame','end_frame']" :key="key">{{ key === 'start_frame' ? 'Start frame' : 'End frame (exclusive)' }}<input type="number" step="1" :aria-label="key === 'start_frame' ? 'Start frame' : 'End frame'" :value="segment[key]" :aria-invalid="fieldErrors[key] || undefined" @input="numeric(key, $event)"></label><label v-for="key in ['start_frame','end_frame']" :key="key + 's'">{{ key === 'start_frame' ? 'Start seconds' : 'End seconds' }}<input :aria-label="key === 'start_frame' ? 'Start seconds' : 'End seconds'" :value="String(Number(segment[key]) / draft.sample_rate)" :aria-invalid="fieldErrors[key] || undefined" inputmode="decimal" @input="numeric(key, $event, true)"></label></div>
          <label><input type="checkbox" aria-label="Frequency bounds" :checked="segment.low_hz != null" @change="checkpoint(); segment.low_hz = ($event.target as HTMLInputElement).checked ? 0 : null; segment.high_hz = ($event.target as HTMLInputElement).checked ? draft.sample_rate / 2 : null">Frequency bounds</label><div v-if="segment.low_hz != null" class="annotation-coordinates"><label v-for="key in ['low_hz','high_hz']" :key="key">{{ key === 'low_hz' ? 'Low Hz' : 'High Hz' }}<input inputmode="decimal" :aria-label="key === 'low_hz' ? 'Low Hz' : 'High Hz'" :value="segment[key]" :aria-invalid="fieldErrors[key] || undefined" @input="numeric(key,$event)"></label></div>
          <label v-if="component.audio_segment_transcript_allowed !== false">Segment transcript{{ component.audio_segment_transcript_required ? ' *' : '' }}<textarea :value="segment.transcript" aria-label="Segment transcript" rows="3" @input="change('transcript', ($event.target as HTMLTextAreaElement).value)" /></label><button @click="remove">Delete segment</button>
        </template></fieldset><fieldset :disabled="saving || stale"><legend>Metadata</legend><label v-if="component.audio_transcript_allowed !== false">Whole-track transcript{{ component.audio_transcript_required ? ' *' : '' }}<textarea :value="draft.transcript" aria-label="Whole-track transcript" rows="4" @input="checkpoint(); draft.transcript = ($event.target as HTMLTextAreaElement).value" /></label><NotebookAnnotationAttributes v-if="segment" :definitions="draft.classes" :assigned="segment.classes" :attributes="segment.attributes" @assign="assign" @attribute="attribute" @invalid="(key,value) => fieldErrors[key] = value" /></fieldset></div>
      <p v-if="invalid" class="source-error" role="status">{{ invalid }}</p><p v-if="Object.values(fieldErrors).some(Boolean)" class="source-error">Enter complete finite numbers in the marked coordinate or attribute fields.</p><p v-if="error" class="source-error" role="status">{{ error }}</p>
      <footer class="dialog-actions"><button @click="exportJSON">Export JSON…</button><button :disabled="saving" @click="close">Discard</button><button class="primary" :disabled="saving || stale || !!invalid || Object.values(fieldErrors).some(Boolean) || disabled || !runtime.canApply" @click="apply">{{ saving ? 'Applying…' : 'Apply annotations' }}</button></footer>
    </template>
  </dialog>
</template>
