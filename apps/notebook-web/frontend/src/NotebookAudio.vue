<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, shallowRef, watch } from 'vue'
import { audioBytes, audioMime, audioPeaks, controlActions, decodedPCM, streamPCM, validateAudio, wavBytes, wavPCM, type AudioControl, type PCM, type PublishedAudio } from './audio'
import { download } from './rich'
const props = withDefaults(defineProps<{ asset: PublishedAudio; controls?: AudioControl[]; stale?: boolean; showWaveform?: boolean }>(), { showWaveform: undefined })
const root = ref<HTMLElement>(), media = ref<HTMLAudioElement>()
const position = ref(0), duration = ref(0), volume = ref(1), playing = ref(false), buffering = ref(false), preparing = ref(false), error = ref(''), ready = ref(false)
const decoded = shallowRef<PCM | null>(null), peaks = shallowRef<Float32Array>(new Float32Array())
const waveform = computed(() => props.showWaveform ?? props.asset.waveform)
const path = computed(() => { let path = ''; for (let i = 0; i < peaks.value.length; i++) { const x = i * 1000 / peaks.value.length, y = peaks.value[i]! * 44; path += `M${x.toFixed(2)},${(45 - y).toFixed(2)}v${(y * 2).toFixed(2)}` } return path })
let original = new Uint8Array(), url = '', data = '', token = '', metadataKey = '', revision = 0n, generation = 0, disposed = false, armed = false
let context: AudioContext | null = null, gain: GainNode | null = null, clockStart = 0, clockPosition = 0
let scheduledFrames = 0
const nodes = new Set<AudioBufferSourceNode>()
let revisions: Record<string, bigint> = {}, timer: ReturnType<typeof setInterval> | undefined
const visible = () => !document.hidden && !!root.value?.getClientRects().length
const time = (value: number) => `${Math.floor(value / 60).toString().padStart(2, '0')}:${(value % 60).toFixed(1).padStart(4, '0')}`
function currentPosition() { return playing.value && props.asset.kind === 'stream' && context ? Math.min(duration.value, clockPosition + Math.max(0, context.currentTime - clockStart)) : position.value }
function stopNodes() { for (const node of nodes) { node.onended = null; try { node.stop() } catch { /* Already ended. */ } node.disconnect() }; nodes.clear(); scheduledFrames = 0 }
function pause(disarm = true) {
  position.value = currentPosition(); playing.value = false; buffering.value = false; media.value?.pause(); stopNodes()
  if (disarm) armed = false
}
function close() {
  generation++; pause(); ready.value = false; decoded.value = null; peaks.value = new Float32Array(); duration.value = 0; position.value = 0; preparing.value = false
  if (media.value) { media.value.removeAttribute('src'); media.value.load() }
  if (url) URL.revokeObjectURL(url)
  url = ''; original = new Uint8Array(); data = ''; token = ''; metadataKey = ''; revision = 0n; revisions = {}
  const previous = context; context = null; gain = null
  if (previous) void previous.close().catch(() => {})
}
function updatePeaks() { peaks.value = waveform.value && decoded.value ? audioPeaks(decoded.value) : new Float32Array() }
function schedulePCM(append = false) {
  const value = decoded.value
  if (!context || !gain || !value || !playing.value) return
  append = append && scheduledFrames > 0 && context.currentTime < clockStart + scheduledFrames / value.rate - clockPosition
  const start = append ? scheduledFrames : Math.min(value.frames, Math.floor(position.value * value.rate))
  if (!append) { stopNodes(); clockPosition = start / value.rate; clockStart = context.currentTime }
  const width = value.format === 's16le' ? 2 : 4, view = new DataView(value.bytes.buffer, value.bytes.byteOffset, value.bytes.length)
  for (let from = start; from < value.frames; from += 16384) {
    const count = Math.min(16384, value.frames - from), buffer = context.createBuffer(value.channels, count, value.rate)
    for (let channel = 0; channel < value.channels; channel++) {
      const samples = buffer.getChannelData(channel)
      for (let frame = 0; frame < count; frame++) { const at = ((from + frame) * value.channels + channel) * width; samples[frame] = width === 2 ? view.getInt16(at, true) / 32768 : view.getFloat32(at, true) }
    }
    const node = context.createBufferSource(); node.buffer = buffer; node.connect(gain); nodes.add(node)
    node.onended = () => { nodes.delete(node); node.disconnect() }
    node.start(clockStart + from / value.rate - clockPosition)
  }
  scheduledFrames = value.frames
  buffering.value = start >= value.frames && !props.asset.finished
}
async function play(user = true) {
  if (!ready.value || !visible()) return
  if (user) armed = true
  if (!armed || (!user && props.stale)) return
  const own = generation
  try {
    error.value = ''
    if (props.asset.kind === 'stream') {
      context ||= new AudioContext()
      if (!gain) { gain = context.createGain(); gain.connect(context.destination) }
      gain.gain.value = volume.value
      await context.resume()
      if (own !== generation || !armed || !visible()) return
      if (context.state !== 'running') throw new Error('Audio is blocked by the browser. Press Play to try again.')
      if (position.value >= duration.value && props.asset.finished) position.value = 0
      playing.value = true; schedulePCM()
    } else if (media.value) {
      if (position.value >= duration.value) seek(0)
      await media.value.play()
      if (own !== generation || !armed || !visible()) { media.value?.pause(); return }
      playing.value = true
    }
  } catch { if (own === generation) { playing.value = false; armed = false; error.value = 'Playback is unavailable or blocked by this browser. Press Play to retry; the original file can still be saved.' } }
}
function seek(value: number) {
  if (!Number.isFinite(value) || value < 0 || value > duration.value) { error.value = 'Player seek exceeds the available audio range.'; return }
  position.value = value
  if (props.asset.kind === 'stream') { if (playing.value) schedulePCM() }
  else if (media.value?.readyState) media.value.currentTime = value
}
function setVolume(value: number) { volume.value = value; if (media.value) media.value.volume = value; if (gain) gain.gain.value = value }
function stop() { pause(); seek(0) }
function applyControls() {
  if (!ready.value) return
  for (const action of controlActions(props.controls || [], revisions)) {
    if (action.kind === 'seek') seek(action.value)
    else if (action.kind === 'volume') setVolume(action.value)
    else if (action.value === 1) { if (armed && !props.stale && visible()) void play(false) }
    else if (action.value === 2) pause(false)
    else if (action.value === 3) { pause(false); seek(0) }
  }
}
function load() {
  try {
    validateAudio(props.asset)
    if (props.asset.kind === 'stream') {
      if (token === props.asset.token && BigInt(props.asset.revision!) <= revision) { applyControls(); return }
      const next = streamPCM(props.asset), same = token === props.asset.token
      if (same && decoded.value && (next.frames < decoded.value.frames || next.rate !== decoded.value.rate || next.channels !== decoded.value.channels || next.format !== decoded.value.format)) throw new Error('PCM stream moved backwards or changed format without a reset.')
      if (same && decoded.value) for (let i = 0; i < decoded.value.bytes.length; i++) if (decoded.value.bytes[i] !== next.bytes[i]) throw new Error('PCM stream changed already published frames.')
      const previousPosition = currentPosition()
      if (!same) { close(); token = props.asset.token!; position.value = Math.min(props.asset.position, next.frames / next.rate); volume.value = props.asset.volume }
      else position.value = previousPosition
      decoded.value = next; duration.value = next.frames / next.rate; revision = BigInt(props.asset.revision!); data = props.asset.data; ready.value = true; error.value = ''; updatePeaks()
      if (playing.value) schedulePCM(same)
      applyControls()
    } else {
      const nextMetadata = [props.asset.format, props.asset.position, props.asset.volume, props.asset.loop, props.asset.autoplay].join(':')
      if (props.asset.data === data && metadataKey === nextMetadata && url) { applyControls(); return }
      close(); error.value = ''; data = props.asset.data; original = audioBytes(data)
      metadataKey = nextMetadata
      position.value = props.asset.position; volume.value = props.asset.volume
      decoded.value = wavPCM(original); updatePeaks()
      url = URL.createObjectURL(new Blob([original], { type: audioMime(props.asset.format) }))
      if (media.value) { media.value.src = url; media.value.volume = volume.value; media.value.loop = props.asset.loop; media.value.load() }
    }
  } catch (cause) { pause(); ready.value = false; error.value = cause instanceof Error ? cause.message : 'Audio could not be loaded.' }
}
function metadata() {
  if (!media.value || props.asset.kind !== 'file' || !url) return
  duration.value = media.value.duration
  if (!Number.isFinite(duration.value) || duration.value <= 0) { error.value = 'The audio duration is unavailable.'; return }
  ready.value = true
  if (props.asset.position <= duration.value) seek(props.asset.position)
  else { position.value = 0; error.value = 'Player position exceeds the track duration.' }
  applyControls()
}
async function prepare() {
  if (preparing.value || decoded.value || !ready.value) return
  const own = generation
  // Browser demux metadata bounds the conversion before decodeAudioData expands
  // compressed files. Decode to 48 kHz; PCM/WAV already use their exact rate.
  if (duration.value > 40) { error.value = 'Browser waveform/WAV conversion is limited to 40 seconds for encoded audio. Save the original file to convert it externally.'; return }
  preparing.value = true; error.value = ''
  try {
    const offline = new OfflineAudioContext(2, 1, 48000), buffer = await offline.decodeAudioData(original.slice().buffer)
    const value = decodedPCM(buffer)
    if (!disposed && own === generation) { decoded.value = value; updatePeaks() }
  } catch { if (own === generation) error.value = 'This browser cannot convert the audio within the mono/stereo WAV limit. Save the original file instead.' }
  finally { if (own === generation) preparing.value = false }
}
async function exportWav() {
  const own = generation
  if (!decoded.value) await prepare()
  if (!decoded.value || own !== generation) return
  try { download(new Blob([wavBytes(decoded.value)], { type: 'audio/wav' }), 'audio.wav') }
  catch (cause) { error.value = (cause as Error).message }
}
function saveOriginal() { if (original.length) download(new Blob([original], { type: audioMime(props.asset.format) }), `audio.${props.asset.format}`) }
function tick() {
  if (!playing.value) return
  if (!visible()) { pause(); return }
  if (props.asset.kind === 'file') { position.value = media.value?.currentTime || 0; return }
  position.value = currentPosition()
  if (position.value >= duration.value) {
    if (!props.asset.finished) buffering.value = true
    else if (props.asset.loop && duration.value > 0) { position.value = 0; schedulePCM() }
    else pause(false)
  }
}
function visibility() { if (document.hidden) pause() }
watch(() => [props.asset.kind, props.asset.data, props.asset.token, props.asset.revision, props.asset.format, props.asset.position, props.asset.volume, props.asset.loop, props.asset.autoplay], load)
watch(() => props.controls, applyControls, { deep: true })
watch(waveform, updatePeaks)
watch(() => props.stale, value => { if (value) pause() })
onMounted(() => { load(); timer = setInterval(tick, 100); document.addEventListener('visibilitychange', visibility) })
onBeforeUnmount(() => { disposed = true; clearInterval(timer); document.removeEventListener('visibilitychange', visibility); close() })
</script>

<template>
  <section ref="root" class="notebook-audio" :class="{ 'audio-stale': stale }" aria-label="Audio player" data-testid="audio-player" :data-channel="asset.id" :data-playing="playing" :data-frames="asset.frames">
    <audio ref="media" preload="metadata" aria-hidden="true" @loadedmetadata="metadata" @ended="playing = false" @error="url && (error = 'This browser cannot play this audio format. Save the original file to open it elsewhere.')" />
    <div class="audio-toolbar"><button :disabled="!ready || preparing" @click="playing ? pause() : play()">{{ playing ? 'Pause' : 'Play' }}</button><button :disabled="!ready" @click="stop">Stop</button><output aria-label="Audio time">{{ time(position) }} / {{ time(duration) }}</output><span v-if="asset.kind === 'stream'" class="source-note">{{ asset.finished ? 'Stream finished' : 'Receiving PCM' }}</span></div>
    <svg v-if="waveform && peaks.length" class="audio-waveform" viewBox="0 0 1000 90" preserveAspectRatio="none" role="img" aria-label="Audio waveform"><path :d="path" /><line :x1="duration ? position / duration * 1000 : 0" :x2="duration ? position / duration * 1000 : 0" y1="0" y2="90" /></svg>
    <label class="sr-only">Playback position</label><input type="range" min="0" :max="Math.max(.001, duration)" step="0.01" :value="position" :disabled="!ready" aria-label="Playback position" @input="seek(Number(($event.target as HTMLInputElement).value))">
    <div class="audio-volume"><label>Volume<input type="range" min="0" max="1" step="0.01" :value="volume" aria-label="Audio volume" @input="setVolume(Number(($event.target as HTMLInputElement).value))"></label><span v-if="buffering" role="status">Buffering…</span><span v-if="preparing" role="status">Preparing audio…</span><span v-if="stale" class="rich-stale-note">Previous audio · stale</span></div>
    <p v-if="asset.caption" class="audio-caption">{{ asset.caption }}</p>
    <div class="audio-export"><button v-if="asset.kind === 'file'" :disabled="!original.length" @click="saveOriginal">Save original…</button><button :disabled="!ready || preparing || asset.kind === 'stream' && !Number(asset.frames)" @click="exportWav">Export WAV…</button><button v-if="waveform && !decoded" :disabled="!ready || preparing" @click="prepare">Prepare waveform</button></div>
    <p v-if="error" class="source-error" role="status">{{ error }}</p>
    <p v-if="asset.autoplay" class="source-note">Press Play to enable audio in this view.</p>
  </section>
</template>
