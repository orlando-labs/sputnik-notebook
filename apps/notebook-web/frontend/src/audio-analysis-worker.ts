import { analyzeAudio, type AnalysisRequest } from './audio-analysis'
let samples: Float32Array[] = []
self.onmessage = (event: MessageEvent<{ samples?: Float32Array[]; request?: Omit<AnalysisRequest, 'samples'> }>) => {
  if (event.data.samples) samples = event.data.samples
  if (!event.data.request) return
  try {
    const result = analyzeAudio({ ...event.data.request, samples })
    self.postMessage(result, { transfer: [result.waveform.buffer, result.rgba.buffer] })
  } catch { self.postMessage({ error: 'Cannot analyze this audio source.' }) }
}
