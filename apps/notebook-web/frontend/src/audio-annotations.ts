import { documentJSON } from './document-json'
import { annotationClassesError, annotationNumber, type AnnotationClass } from './image-annotations'
import type { BoardComponent } from './boards'
export interface AudioSegment {
  id: string; title: string; start_frame: number; end_frame: number; low_hz?: number | null; high_hz?: number | null
  classes: string[]; attributes: Record<string, Record<string, unknown>>; transcript: string; [key: string]: unknown
}
export interface AudioSource {
  asset: string; source: 'input' | 'cell'; channel: string; cell: unknown; sample_rate: number; channels: number; frames: number
}
export interface AudioAnnotations extends AudioSource {
  version: 1; transcript: string; classes: AnnotationClass[]; segments: AudioSegment[]; [key: string]: unknown
}
const text = (value: unknown, limit: number, required = false): value is string => typeof value === 'string' && !value.includes('\0') && new TextEncoder().encode(value).length <= limit && (!required || !!value.trim())
export function audioSettingsError(c: BoardComponent) {
  if (!['file', 'input', 'cell'].includes(String(c.audio_source ?? 'file'))) return 'Choose an audio source.'
  if (c.audio_source === 'cell' && (!c.cell || !/^[1-9]\d*$/.test(documentJSON(c.cell).replace(/^"|"$/g, '')))) return 'Choose a source cell.'
  if (c.audio_view !== undefined && !['waveform', 'spectrogram'].includes(String(c.audio_view))) return 'Choose a supported audio view.'
  if (c.audio_fft_size !== undefined && ![256, 512, 1024, 2048, 4096].includes(Number(c.audio_fft_size))) return 'Choose a supported FFT size.'
  for (const prefix of ['audio_transcript', 'audio_segment_transcript']) {
    for (const suffix of ['allowed', 'required']) if (c[prefix + '_' + suffix] !== undefined && typeof c[prefix + '_' + suffix] !== 'boolean') return 'Transcript settings must be Boolean.'
    if (c[prefix + '_required'] && c[prefix + '_allowed'] === false) return 'Required transcripts must be allowed.'
  }
  return c.annotation_classes === undefined ? '' : annotationClassesError(c.annotation_classes as AnnotationClass[])
}
export function audioAnnotationError(value: AudioAnnotations, component: BoardComponent) {
  if (value.version !== 1 || !/^[a-f0-9]{64}$/.test(value.asset) || !text(value.channel, 256, true) || !['input', 'cell'].includes(value.source) ||
      !Number.isInteger(value.sample_rate) || value.sample_rate < 8000 || value.sample_rate > 192000 || ![1, 2].includes(value.channels) ||
      !Number.isInteger(value.frames) || value.frames <= 0 || value.frames * value.channels * 4 > 16 * 1024 * 1024 - 64) return 'Invalid audio source identity or decoded size.'
  const classes = annotationClassesError(value.classes); if (classes) return classes
  const transcript = (s: unknown, segment: boolean) => {
    const prefix = segment ? 'audio_segment_transcript' : 'audio_transcript'
    return !text(s, segment ? 8192 : 65536) ? 'Transcript exceeds its UTF-8 limit.' : component[prefix + '_allowed'] === false && s !== '' ? 'This transcript is disallowed.' : component[prefix + '_required'] === true && !s.trim() ? 'Complete the required transcript.' : ''
  }
  const invalid = transcript(value.transcript, false); if (invalid) return invalid
  if (!Array.isArray(value.segments) || value.segments.length > 1000) return 'Use up to 1,000 segments.'
  const ids = new Set<string>()
  for (const s of value.segments) {
    if (!text(s.id, 64, true) || ids.has(s.id) || !text(s.title, 256)) return 'Segments need unique IDs and bounded titles.'
    ids.add(s.id)
    if (!Number.isInteger(s.start_frame) || !Number.isInteger(s.end_frame) || s.start_frame < 0 || s.start_frame >= s.end_frame || s.end_frame > value.frames) return 'Segment frames must satisfy 0 ≤ Start < End ≤ source frames.'
    if ((s.low_hz != null) !== (s.high_hz != null) || s.low_hz != null && (!Number.isFinite(s.low_hz) || !Number.isFinite(s.high_hz) || s.low_hz < 0 || s.low_hz >= s.high_hz! || s.high_hz! > value.sample_rate / 2)) return 'Frequency bounds must satisfy 0 ≤ Low < High ≤ Nyquist.'
    const error = transcript(s.transcript, true); if (error) return error
    if (!Array.isArray(s.classes) || new Set(s.classes).size !== s.classes.length || s.classes.some(id => !value.classes.some(c => c.id === id))) return 'Choose configured segment classes.'
    for (const [id, values] of Object.entries(s.attributes || {})) {
      const c = value.classes.find(c => c.id === id)
      if (!c || !s.classes.includes(id) || !values || typeof values !== 'object') return 'Attributes require an assigned class.'
      for (const [key, entry] of Object.entries(values)) {
        const a = c.attributes.find(a => a.id === key)
        if (!a || a.type === 'number' && !annotationNumber(entry) || a.type === 'boolean' && typeof entry !== 'boolean' || a.type === 'text' && !text(entry, 2048) || a.type === 'choice' && (typeof entry !== 'string' || !a.options.includes(entry))) return 'Invalid configured attribute value.'
      }
    }
  }
  return new TextEncoder().encode(documentJSON(value)).length > 512 * 1024 ? 'Audio annotations exceed 512 KiB.' : ''
}
export function drawnSegment(from: { frame: number; hz: number }, to: { frame: number; hz: number }, frames: number, rate: number, spectral: boolean): AudioSegment | null {
  if (![from.frame, to.frame, from.hz, to.hz].every(Number.isFinite)) return null
  const start = Math.max(0, Math.min(frames, Math.round(Math.min(from.frame, to.frame)))), end = Math.max(0, Math.min(frames, Math.round(Math.max(from.frame, to.frame))))
  const low = Math.max(0, Math.min(rate / 2, Math.min(from.hz, to.hz))), high = Math.max(0, Math.min(rate / 2, Math.max(from.hz, to.hz)))
  return start === end || spectral && low === high ? null : { id: crypto.randomUUID(), title: '', start_frame: start, end_frame: end, classes: [], attributes: {}, transcript: '', ...(spectral ? { low_hz: low, high_hz: high } : {}) }
}
