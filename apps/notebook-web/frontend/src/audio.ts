export interface PublishedAudio {
  id: string; caption: string; kind: 'file' | 'stream'; format: string; data: string
  position: number; volume: number; waveform: boolean; loop: boolean; autoplay: boolean
  token?: string; revision?: string; frames?: string; rate?: number; channels?: number; finished?: boolean
}
export interface AudioControl { cell: string; channel: string; playback_revision: string; seek_revision: string; volume_revision: string; playback: number; position: number; volume: number }
export interface PCM { bytes: Uint8Array<ArrayBuffer>; format: 's16le' | 'f32le'; rate: number; channels: number; frames: number }
export const maxAudioBytes = 16 * 1024 * 1024, maxDecodedBytes = 32 * 1024 * 1024
const uint64 = (text: unknown, positive = false): text is string => typeof text === 'string' && /^(0|[1-9]\d{0,19})$/.test(text) && BigInt(text) <= 18446744073709551615n && (!positive || BigInt(text) > 0n)
export function audioBytes(source: string) {
  if (typeof source !== 'string' || source.length > Math.ceil(maxAudioBytes / 3) * 4 || source.length % 4 || /[^A-Za-z0-9+/=]/.test(source)) throw new Error('Invalid or oversized audio bytes.')
  const padding = source.endsWith('==') ? 2 : source.endsWith('=') ? 1 : 0
  if (source.slice(0, source.length - padding).includes('=') || source.length / 4 * 3 - padding > maxAudioBytes) throw new Error('Invalid audio encoding.')
  return Uint8Array.from(atob(source), char => char.charCodeAt(0))
}
export function validateAudio(audio: PublishedAudio) {
  if (!audio || !['file', 'stream'].includes(audio.kind) || typeof audio.id !== 'string' || audio.id.length > 256 || audio.id.includes('\0') || typeof audio.caption !== 'string' || audio.caption.length > 65536 ||
      !Number.isFinite(audio.position) || audio.position < 0 || !Number.isFinite(audio.volume) || audio.volume < 0 || audio.volume > 1 || !['waveform', 'loop', 'autoplay'].every(key => typeof audio[key as keyof PublishedAudio] === 'boolean') || !/^[a-z0-9]{1,16}$/.test(audio.format)) throw new Error('Invalid audio metadata.')
  if (audio.kind === 'stream' && (!uint64(audio.token, true) || !uint64(audio.revision, true) || !uint64(audio.frames) || typeof audio.finished !== 'boolean')) throw new Error('Invalid PCM stream identity.')
}
export function pcm(bytes: Uint8Array<ArrayBuffer>, format: string, rate: number, channels: number): PCM {
  const width = format === 's16le' ? 2 : format === 'f32le' ? 4 : 0
  if (!width || !Number.isInteger(rate) || rate < 8000 || rate > 192000 || ![1, 2].includes(channels) || bytes.length > maxAudioBytes || bytes.length % (channels * width) || bytes.length / width * 4 > maxDecodedBytes) throw new Error('PCM must contain complete finite mono/stereo frames within the audio limit.')
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  if (format === 'f32le') for (let offset = 0; offset < bytes.length; offset += 4) if (!Number.isFinite(view.getFloat32(offset, true))) throw new Error('Audio contains non-finite samples.')
  return { bytes, format: format as PCM['format'], rate, channels, frames: bytes.length / (channels * width) }
}
export function streamPCM(audio: PublishedAudio) {
  validateAudio(audio)
  const value = pcm(audioBytes(audio.data), audio.format, audio.rate!, audio.channels!)
  if (audio.kind !== 'stream' || String(value.frames) !== audio.frames || value.bytes.length > maxAudioBytes - 128) throw new Error('Incomplete PCM stream snapshot.')
  return value
}
export function wavPCM(bytes: Uint8Array<ArrayBuffer>): PCM | null {
  const text = (offset: number, size: number) => String.fromCharCode(...bytes.subarray(offset, offset + size))
  if (bytes.length < 12 || text(0, 4) !== 'RIFF' || text(8, 4) !== 'WAVE') return null
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength), end = view.getUint32(4, true) + 8
  if (end > bytes.length || end < 12) throw new Error('Incomplete WAV file.')
  let format = 0, channels = 0, rate = 0, bits = 0, block = 0, data: Uint8Array<ArrayBuffer> | undefined
  for (let offset = 12, chunks = 0; offset + 8 <= end; chunks++) {
    if (chunks >= 4096) throw new Error('WAV contains too many chunks.')
    const id = text(offset, 4), size = view.getUint32(offset + 4, true), start = offset + 8
    if (size > end - start) throw new Error('Incomplete WAV chunk.')
    if (id === 'fmt ') {
      if (size < 16) throw new Error('Incomplete WAV format.')
      format = view.getUint16(start, true); channels = view.getUint16(start + 2, true); rate = view.getUint32(start + 4, true); block = view.getUint16(start + 12, true); bits = view.getUint16(start + 14, true)
    } else if (id === 'data') { if (data) return null; data = bytes.subarray(start, start + size) }
    offset = start + size + (size % 2)
  }
  if (!data || !((format === 1 && bits === 16) || (format === 3 && bits === 32))) return null
  if (block !== channels * bits / 8) throw new Error('Invalid WAV frame alignment.')
  return pcm(data, format === 1 ? 's16le' : 'f32le', rate, channels)
}
export function sample(value: PCM, frame: number, channel: number) {
  const view = new DataView(value.bytes.buffer, value.bytes.byteOffset, value.bytes.byteLength), width = value.format === 's16le' ? 2 : 4, at = (frame * value.channels + channel) * width
  return value.format === 's16le' ? view.getInt16(at, true) / 32768 : view.getFloat32(at, true)
}
export function audioPeaks(value: PCM) {
  const peaks = new Float32Array(Math.min(2048, value.frames))
  const view = new DataView(value.bytes.buffer, value.bytes.byteOffset, value.bytes.byteLength), width = value.format === 's16le' ? 2 : 4
  for (let frame = 0; frame < value.frames; frame++) {
    let peak = 0
    for (let channel = 0; channel < value.channels; channel++) { const at = (frame * value.channels + channel) * width; peak = Math.max(peak, Math.min(1, Math.abs(width === 2 ? view.getInt16(at, true) / 32768 : view.getFloat32(at, true)))) }
    const bucket = Math.floor(frame * peaks.length / value.frames); peaks[bucket] = Math.max(peaks[bucket]!, peak)
  }
  return peaks
}
export function wavBytes(value: PCM) {
  if (value.bytes.length + 44 > maxAudioBytes) throw new Error('Exported WAV exceeds 16 MiB.')
  const bytes = new Uint8Array(value.bytes.length + 44), view = new DataView(bytes.buffer)
  const text = (offset: number, value: string) => bytes.set(new TextEncoder().encode(value), offset)
  const width = value.format === 's16le' ? 2 : 4
  text(0, 'RIFF'); view.setUint32(4, bytes.length - 8, true); text(8, 'WAVEfmt '); view.setUint32(16, 16, true)
  view.setUint16(20, width === 2 ? 1 : 3, true); view.setUint16(22, value.channels, true); view.setUint32(24, value.rate, true); view.setUint32(28, value.rate * value.channels * width, true)
  view.setUint16(32, value.channels * width, true); view.setUint16(34, width * 8, true); text(36, 'data'); view.setUint32(40, value.bytes.length, true); bytes.set(value.bytes, 44)
  return bytes
}
export function decodedPCM(buffer: AudioBuffer) {
  if (![1, 2].includes(buffer.numberOfChannels) || buffer.length * buffer.numberOfChannels * 4 > Math.min(maxDecodedBytes, maxAudioBytes - 44)) throw new Error('Decoded WAV exceeds the mono/stereo export limit.')
  const bytes = new Uint8Array(buffer.length * buffer.numberOfChannels * 4), view = new DataView(bytes.buffer), channels = Array.from({ length: buffer.numberOfChannels }, (_, index) => buffer.getChannelData(index))
  for (let frame = 0; frame < buffer.length; frame++) for (let channel = 0; channel < channels.length; channel++) view.setFloat32((frame * channels.length + channel) * 4, channels[channel]![frame]!, true)
  return pcm(bytes, 'f32le', buffer.sampleRate, buffer.numberOfChannels)
}
export function audioMime(format: string) { return ({ wav: 'audio/wav', wave: 'audio/wav', mp3: 'audio/mpeg', m4a: 'audio/mp4', aac: 'audio/aac', ogg: 'audio/ogg', opus: 'audio/ogg', flac: 'audio/flac', aif: 'audio/aiff', aiff: 'audio/aiff' } as Record<string, string>)[format] || 'application/octet-stream' }
export function controlActions(controls: AudioControl[], revisions: Record<string, bigint>) {
  const actions: { kind: 'playback' | 'seek' | 'volume'; revision: bigint; value: number }[] = []
  for (const control of controls) {
    if (![control.position, control.volume].every(Number.isFinite) || control.position < 0 || control.volume < 0 || control.volume > 1 || ![0, 1, 2, 3].includes(control.playback)) continue
    for (const kind of ['playback', 'seek', 'volume'] as const) {
      const value = control[`${kind}_revision`]
      if (!uint64(value) || BigInt(value) <= (revisions[kind] || 0n)) continue
      actions.push({ kind, revision: BigInt(value), value: kind === 'playback' ? control.playback : kind === 'seek' ? control.position : control.volume })
    }
  }
  return actions.sort((a, b) => a.revision < b.revision ? -1 : a.revision > b.revision ? 1 : 0).filter(action => {
    if (action.revision <= (revisions[action.kind] || 0n)) return false
    revisions[action.kind] = action.revision; return true
  })
}
