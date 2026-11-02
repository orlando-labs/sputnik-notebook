import type { PublishedAudio, AudioControl } from './audio'
export interface TableValue { kind: 'null' | 'boolean' | 'integer' | 'number' | 'text'; text: string }
export interface TableRow { id: string; values: TableValue[] }
export interface TableSnapshot {
  columns: { id: string; title: string; type: string }[]
  rows: TableRow[]; total_rows: string; truncated: boolean
}
export interface Figure {
  id: string; mime: string; caption: string; width: number; height: number
  data?: string; plot_scene?: string; table?: TableSnapshot | null
}
export interface ImageSeries { id: string; caption: string; images: Figure[] }
export interface ProgressItem { id: string; current: number; total: number; description: string; done: boolean; elapsed_ms: string }
export interface StopwatchItem { id: string; elapsed_ms: string; done: boolean }
export interface LiveChart { id: string; total_points: string; points: [number, number][] }
export interface RichCell {
  audio?: PublishedAudio[]; audio_controls?: AudioControl[]; audio_limited?: boolean; audio_stale?: boolean
  table: TableSnapshot | null; displays: Figure[]; images: ImageSeries[]; rich_stale: boolean; rich_unsupported: boolean
  progress: ProgressItem[]; stopwatches: StopwatchItem[]; charts: LiveChart[]
  elapsed_ms: string | null; timing_running: boolean; telemetry_stale: boolean
}

export function compareValues(a: TableValue, b: TableValue) {
  if (['integer', 'number'].includes(a.kind) && ['integer', 'number'].includes(b.kind)) {
    const left = a.kind === 'integer' ? BigInt(a.text) : Number(a.text)
    const right = b.kind === 'integer' ? BigInt(b.text) : Number(b.text)
    return left < right ? -1 : left > right ? 1 : 0
  }
  return a.text.localeCompare(b.text, undefined, { numeric: true, sensitivity: 'base' })
}
export function tableCSV(table: TableSnapshot, rows: TableRow[]) {
  const quote = (text: string) => `"${text.replaceAll('"', '""')}"`
  return [table.columns.map(column => quote(column.title)).join(','), ...rows.map(row => row.values.map(value => quote(value.text)).join(','))].join('\r\n') + '\r\n'
}
export function tableMarkdown(table: TableSnapshot, rows: TableRow[]) {
  const escape = (text: string) => text.replaceAll('\\', '\\\\').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('|', '\\|').replace(/\r\n?|\n/g, '<br>')
  const line = (cells: string[]) => `| ${cells.join(' | ')} |`
  return [line(table.columns.map(column => escape(column.title))), line(table.columns.map(() => '---')), ...rows.map(row => line(row.values.map(value => escape(value.text))))].join('\n') + '\n'
}
export function download(blob: Blob, name: string) {
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url; link.download = name; link.click()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
export function rasterURL(figure: Figure) {
  return ['image/png', 'image/jpeg'].includes(figure.mime) && figure.data && /^[A-Za-z0-9+/]*={0,2}$/.test(figure.data)
    ? `data:${figure.mime};base64,${figure.data}` : ''
}
export function downloadRaster(figure: Figure) {
  if (!rasterURL(figure)) return
  const bytes = Uint8Array.from(atob(figure.data!), char => char.charCodeAt(0))
  download(new Blob([bytes], { type: figure.mime }), `image.${figure.mime === 'image/jpeg' ? 'jpg' : 'png'}`)
}
