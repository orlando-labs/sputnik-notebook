import { plasma } from './plasma'
export interface AudioViewport { start: number; end: number; low: number; high: number }
export interface AnalysisRequest { samples: Float32Array[]; rate: number; channel: number; viewport: AudioViewport; fft: number; range: number; spectral: boolean; columns: number }
// Radix-2 real-input FFT with coherent Hann gain. DC/Nyquist do not double.
export function spectrum(samples: Float32Array[], center: number, channel: number, size: number) {
  const re = new Float64Array(size), im = new Float64Array(size); let sum = 0
  for (let i = 0; i < size; i++) {
    const window = .5 - .5 * Math.cos(2 * Math.PI * i / (size - 1)), frame = center + i - size / 2
    let value = 0
    if (frame >= 0 && frame < samples[0]!.length) value = channel < 0 ? samples.reduce((s, c) => s + c[frame]!, 0) / samples.length : samples[channel]![frame]!
    re[i] = value * window; sum += window
  }
  for (let i = 1, j = 0; i < size; i++) {
    let bit = size >> 1; for (; j & bit; bit >>= 1) j ^= bit; j ^= bit
    if (i < j) { const v = re[i]!; re[i] = re[j]!; re[j] = v }
  }
  for (let length = 2; length <= size; length *= 2) {
    const angle = -2 * Math.PI / length, wr = Math.cos(angle), wi = Math.sin(angle)
    for (let base = 0; base < size; base += length) {
      let r = 1, q = 0
      for (let j = 0; j < length / 2; j++) {
        const a = base + j, b = a + length / 2, br = re[b]! * r - im[b]! * q, bi = re[b]! * q + im[b]! * r
        re[b] = re[a]! - br; im[b] = im[a]! - bi; re[a] = re[a]! + br; im[a] = im[a]! + bi
        const next = r * wr - q * wi; q = r * wi + q * wr; r = next
      }
    }
  }
  const db = new Float32Array(size / 2 + 1)
  for (let k = 0; k < db.length; k++) db[k] = 20 * Math.log10(Math.max(1e-12, Math.hypot(re[k]!, im[k]!) * (k === 0 || k === size / 2 ? 1 : 2) / sum))
  return db
}
export function analyzeAudio(request: AnalysisRequest) {
  const { samples, rate, channel, viewport: v, fft, range, spectral } = request
  if (!samples.length || samples.length > 2 || !samples[0]!.length || samples.some(s => s.length !== samples[0]!.length) || samples[0]!.length * samples.length * 4 > 16 * 1024 * 1024 ||
      ![256, 512, 1024, 2048, 4096].includes(fft) || ![60, 90, 120].includes(range) || !Number.isInteger(channel) || channel < -1 || channel >= samples.length || ![v.start, v.end, v.low, v.high, rate, request.columns].every(Number.isFinite) ||
      v.start < 0 || v.start >= v.end || v.end > samples[0]!.length || v.low < 0 || v.low >= v.high || v.high > rate / 2) throw new Error('Invalid audio analysis bounds.')
  const columns = Math.max(1, Math.min(1400, Math.floor(request.columns))), rows = Math.min(768, Math.max(1, Math.ceil((v.high - v.low) * fft / rate)))
  const waveform = new Float32Array(columns * 2), rgba = spectral ? new Uint8ClampedArray(columns * rows * 4) : new Uint8ClampedArray()
  for (let x = 0; x < columns; x++) {
    const first = Math.floor(v.start + x / columns * (v.end - v.start)), last = Math.min(samples[0]!.length, Math.max(first + 1, Math.ceil(v.start + (x + 1) / columns * (v.end - v.start))))
    let low = 0, high = 0
    for (let i = first; i < last; i++) {
      const value = channel < 0 ? samples.reduce((s, c) => s + c[i]!, 0) / samples.length : samples[channel]![i]!
      low = Math.min(low, value); high = Math.max(high, value)
    }
    waveform[x * 2] = low; waveform[x * 2 + 1] = high
    if (!spectral) continue
    const db = spectrum(samples, Math.round((first + last) / 2), channel, fft)
    for (let y = 0; y < rows; y++) {
      const bin = Math.max(0, Math.min(fft / 2, Math.round((v.high - (y + .5) / rows * (v.high - v.low)) * fft / rate)))
      const color = Math.max(0, Math.min(255, Math.round((db[bin]! + range) / range * 255))), at = (y * columns + x) * 4
      rgba[at] = plasma[color * 3]!; rgba[at + 1] = plasma[color * 3 + 1]!; rgba[at + 2] = plasma[color * 3 + 2]!; rgba[at + 3] = 255
    }
  }
  return { waveform, rgba, columns, rows }
}
