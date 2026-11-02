import { pcm, wavBytes } from './audio'
export class RecordingPCM {
  private chunks: Uint8Array<ArrayBuffer>[] = []
  frames = 0
  channels = 0
  peak = 0
  rms = 0
  clipped = false
  constructor(readonly rate: number) { if (!Number.isInteger(rate) || rate < 8000 || rate > 192000) throw new Error('Recording requires 8–192 kHz PCM.') }
  append(data: unknown, channels: number, frames: number) {
    if (!(data instanceof Float32Array) || ![1,2].includes(channels) || this.channels && this.channels !== channels || !Number.isInteger(frames) || frames <= 0 || frames > 4096 || data.length !== frames * channels) throw new Error('Invalid microphone PCM chunk.')
    if ((this.frames + frames) > Math.min(this.rate * 30, Math.floor((16 * 1024 * 1024 - 64) / (4 * channels)))) throw new Error('Recording exceeds 30 seconds or the PCM limit.')
    const bytes = new Uint8Array(data.length * 2), view = new DataView(bytes.buffer)
    let peak = 0, sum = 0
    for (let i = 0; i < data.length; i++) {
      const value = data[i]!
      if (!Number.isFinite(value)) throw new Error('Microphone returned invalid samples.')
      peak = Math.max(peak, Math.abs(value)); sum += value * value
      const clamped = Math.max(-1, Math.min(1, value)); view.setInt16(i * 2, Math.min(32767, Math.round(clamped * 32768)), true)
    }
    this.channels = channels; this.frames += frames; this.peak = peak; this.rms = Math.sqrt(sum / data.length); this.clipped ||= peak >= 1; this.chunks.push(bytes)
  }
  wav() {
    if (!this.frames) throw new Error('No microphone samples were captured. Try recording again.')
    const bytes = new Uint8Array(this.frames * this.channels * 2); let offset = 0
    for (const chunk of this.chunks) { bytes.set(chunk, offset); offset += chunk.length }
    return wavBytes(pcm(bytes, 's16le', this.rate, this.channels))
  }
}
