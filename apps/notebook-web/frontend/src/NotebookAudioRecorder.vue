<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { RecordingPCM } from './audio-recording'
const props = defineProps<{ disabled: boolean; identity: string }>()
const emit = defineEmits<{ captured: [file: File]; active: [active: boolean] }>()
const root = ref<HTMLElement>(), phase = ref<'idle'|'requesting'|'recording'|'finishing'>('idle'), error = ref(''), devices = ref<MediaDeviceInfo[]>([]), device = ref(''), elapsed = ref(0), peak = ref(0), rms = ref(-120), clipped = ref(false)
const available = computed(() => window.isSecureContext && !!navigator.mediaDevices?.getUserMedia && typeof AudioWorkletNode !== 'undefined')
let generation = 0, stream: MediaStream | null = null, context: AudioContext | null = null, source: MediaStreamAudioSourceNode | null = null, node: AudioWorkletNode | null = null, silent: GainNode | null = null, samples: RecordingPCM | null = null, timer: ReturnType<typeof setInterval> | undefined, stopTimer: ReturnType<typeof setTimeout> | undefined, started = 0, lastSamples = 0, disposed = false
const visible = () => !document.hidden && !!root.value?.getClientRects().length
watch(phase, value => emit('active', value !== 'idle'), { flush:'sync' })
async function microphones() {
  try { devices.value = (await navigator.mediaDevices.enumerateDevices()).filter(item => item.kind === 'audioinput'); if (device.value && !devices.value.some(item => item.deviceId === device.value)) device.value = '' }
  catch { error.value = 'Microphone devices are unavailable. Try the system default.' }
}
function cleanup() {
  generation++; clearInterval(timer); clearTimeout(stopTimer)
  if (node) { node.port.onmessage = null; node.onprocessorerror = null; node.port.close(); node.disconnect() }
  source?.disconnect(); silent?.disconnect()
  for (const track of stream?.getTracks() || []) { track.onended = null; track.stop() }
  const previous = context; context = null; if(previous) { previous.onstatechange=null; void previous.close().catch(()=>{}) }
  stream=null; source=null; node=null; silent=null; samples=null; phase.value='idle'; peak.value=0
}
function cancel() { cleanup() }
function fail(message:string) { error.value=message; cleanup() }
function finish(message = '') {
  try {
    if(message)throw new Error(message)
    const bytes=samples!.wav()
    const file=new File([bytes],'Recording.wav',{type:'audio/wav'})
    cleanup(); emit('captured',file)
  } catch(cause) { fail((cause as Error).message) }
}
function stop() {
  if(phase.value!=='recording')return
  phase.value='finishing'
  source?.disconnect(); for(const track of stream?.getTracks() || []) { track.onended=null; track.stop() }
  node?.port.postMessage('stop')
  stopTimer=setTimeout(()=>fail('The audio processor did not finish. The previous draft is unchanged.'),1500)
}
async function record() {
  if(props.disabled || phase.value!=='idle' || !available.value || !visible())return
  error.value='';elapsed.value=0;clipped.value=false;phase.value='requesting';const own=++generation
  timer=setInterval(()=>{if(!visible()||props.disabled)cancel()},100)
  let stage='Starting Web Audio'
  try {
    const current=new AudioContext({sampleRate:48000}); context=current
    await current.resume()
    stage='Opening microphone'
    const captured=await navigator.mediaDevices.getUserMedia({audio:device.value?{deviceId:{exact:device.value}}:true,video:false})
    if(disposed || own!==generation || props.disabled || !visible()){captured.getTracks().forEach(track=>track.stop());return}
    stream=captured
    stage='Loading recording processor'
    await current.audioWorklet.addModule(new URL('./audio-recorder-worklet.js',import.meta.url).href)
    if(own!==generation)return
    if(current.state!=='running')throw new Error('Audio capture is suspended. Press Record to try again.')
    stage='Connecting recording processor'
    samples=new RecordingPCM(current.sampleRate)
    source=current.createMediaStreamSource(captured)
    node=new AudioWorkletNode(current,'sputnik-notebook-recorder',{numberOfInputs:1,numberOfOutputs:1,outputChannelCount:[1],channelCount:2,channelCountMode:'max'})
    silent=current.createGain();silent.gain.value=0;source.connect(node);node.connect(silent);silent.connect(current.destination)
    node.port.onmessage=event=>{
      if(own!==generation)return
      try {
        if(event.data.kind==='pcm') { samples!.append(event.data.data,event.data.channels,event.data.frames);elapsed.value=samples!.frames/current.sampleRate;peak.value=Math.min(1,samples!.peak);rms.value=20*Math.log10(Math.max(.000001,samples!.rms));clipped.value=samples!.clipped;lastSamples=performance.now() }
        else if(event.data.kind==='done')finish(event.data.error)
      }catch(cause){fail((cause as Error).message)}
    }
    node.onprocessorerror=()=>fail('The microphone processor stopped. Try recording again.')
    for(const track of captured.getTracks())track.onended=()=>fail('The microphone disconnected. The previous draft is unchanged.')
    current.onstatechange=()=>{if(phase.value==='recording' && current.state!=='running')fail('Audio capture was interrupted. The previous draft is unchanged.')}
    phase.value='recording';started=lastSamples=performance.now();void microphones()
    clearInterval(timer);timer=setInterval(()=>{if(!visible() || props.disabled){cancel();return}if(performance.now()-started>=31000)stop();else if(performance.now()-lastSamples>4000)fail('No microphone samples arrived. Check the selected device.')},100)
  }catch(cause){if(own===generation){const name=(cause as DOMException).name;fail(name==='NotAllowedError'?'Microphone access was denied. Allow it in your browser to record.':name==='NotFoundError'?'No microphone is available. Choose another device or import audio.':stage+': '+(cause as Error).message)}}
}
function visibility(){if(document.hidden && phase.value!=='idle')cancel()}
watch(()=>props.disabled,value=>{if(value)cancel()})
watch(()=>props.identity,cancel)
onMounted(()=>document.addEventListener('visibilitychange',visibility))
onBeforeUnmount(()=>{disposed=true;document.removeEventListener('visibilitychange',visibility);cleanup()})
</script>
<template>
  <section ref="root" class="audio-recorder" aria-label="Microphone recorder" data-testid="audio-recorder" :data-phase="phase">
    <div class="media-input-actions"><label>Microphone<select v-model="device" aria-label="Microphone" :disabled="disabled || phase !== 'idle'"><option value="">System default</option><option v-for="(item,index) in devices" :key="item.deviceId || index" :value="item.deviceId">{{ item.label || `Microphone ${index+1}` }}</option></select></label><button :disabled="!available || disabled || phase!=='idle'" @click="microphones">Refresh microphones</button></div>
    <div class="media-input-actions"><button v-if="phase==='idle'" :disabled="disabled || !available" @click="record">Record</button><button v-if="phase==='recording'" @click="stop">Stop recording</button><button v-if="phase!=='idle'" @click="cancel">Cancel recording</button><output aria-label="Recording duration">{{ elapsed.toFixed(1) }} / 30 s</output><span v-if="phase==='requesting'" role="status">Waiting for microphone permission…</span><span v-if="phase==='finishing'" role="status">Finishing WAV…</span></div>
    <div v-if="phase==='recording'" class="recording-meter"><label>Microphone level<meter :value="peak" min="0" max="1" aria-label="Microphone level" /></label><output aria-label="Microphone RMS">RMS {{ rms.toFixed(1) }} dBFS</output><span v-if="clipped" role="status">Clipping · samples will be limited to PCM16</span></div>
    <p class="source-note">Record opens the microphone explicitly. Stop creates a local WAV draft; Apply media accepts it. Capture stops after 30 seconds or when this view is hidden.</p>
    <p v-if="!available" class="source-note">Recording requires HTTPS (or localhost) and Web Audio worklet support. Audio import remains available.</p><p v-if="error" class="source-error" role="status">{{ error }}</p>
  </section>
</template>
