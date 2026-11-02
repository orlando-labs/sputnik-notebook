import type { CellComponent, DisplaySettings } from './inputs'
import type { RichCell } from './rich'
import { documentJSON } from './document-json'

export const displayKinds = ['metric', 'live_chart', 'table', 'image', 'audio'] as const
export const displayTitles: Record<string, string> = { metric: 'Metric', live_chart: 'Live Chart', table: 'Table', image: 'Image', audio: 'Audio' }
export function numberSetting(value: unknown): number | undefined {
  if (value == null) return undefined
  const parsed = typeof value === 'number' ? value : Number(documentJSON(value))
  return Number.isFinite(parsed) ? parsed : undefined
}
const color = (value: string) => /^#[0-9a-f]{6}$/i.test(value)
export function displayError(component: CellComponent): string {
  const bounded = (value: string | undefined, maximum: number) => value === undefined || (!value.includes('\0') && new TextEncoder().encode(value).length <= maximum)
  if (!bounded(component.caption, 65536)) return 'Caption must fit 64 KiB and contain no NUL.'
  if (component.kind === 'metric') {
    if (!bounded(component.binding, 65536) || !bounded(component.p1?.unit, 256)) return 'Invalid metric binding or unit.'
    for (const key of ['target', 'baseline', 'precision'] as const) {
      const value = component.p1?.[key]
      if (value !== undefined && numberSetting(value) === undefined) return `Metric ${key} must be finite.`
    }
    const precision = numberSetting(component.p1?.precision)
    if (precision !== undefined && (!Number.isInteger(precision) || precision < 0 || precision > 12)) return 'Metric precision must be a whole number from 0 to 12.'
  }
  if (component.kind === 'table' && !bounded(component.table_id, 256)) return 'Table ID must fit 256 bytes.'
  if (component.kind === 'audio' && (!bounded(component.audio_id, 256) || component.show_waveform !== undefined && typeof component.show_waveform !== 'boolean')) return 'Choose a valid audio channel and waveform setting.'
  if (component.kind === 'image') {
    if (!bounded(component.image_id, 256) || !['fit', 'fill', 'auto-height'].includes(component.image_mode || 'fit')) return 'Choose a valid image channel and sizing mode.'
  }
  if (component.kind === 'live_chart') {
    if (!bounded(component.chart_id, 256) || !bounded(component.x_label, 65536) || !bounded(component.y_label, 65536)) return 'Invalid chart channel or axis label.'
    if (component.stroke !== undefined && !color(component.stroke)) return 'Chart color must be #RRGGBB.'
    for (const axis of ['x', 'y']) {
      const low = numberSetting(component[`${axis}_min`]), high = numberSetting(component[`${axis}_max`])
      for (const key of [`${axis}_min`, `${axis}_max`]) if (component[key] !== undefined && (numberSetting(component[key]) === undefined || Math.abs(numberSetting(component[key])!) >= 1e100)) return 'Axis bounds must be finite with magnitude below 1e100.'
      if (low !== undefined && high !== undefined && high - low <= Math.max(1e-100, Math.max(Math.abs(low), Math.abs(high)) * 1e-13)) return `${axis.toUpperCase()} maximum must exceed its minimum with a resolvable interval.`
    }
    const series = component.p1?.series || []
    if (series.length > 16 || new Set(series.map(item => item.id)).size !== series.length || series.some(item => !item.id || !bounded(item.id, 256) || !item.title || !bounded(item.title, 256) || !color(item.stroke))) return 'Use up to 16 unique series with channel IDs, titles and #RRGGBB colors.'
  }
  return ''
}
export function displayTables(component: CellComponent, rich: RichCell) {
  const published = rich.displays.filter(figure => figure.table && (!component.table_id || figure.id === component.table_id))
  return published.length ? published.map((figure, index) => ({ table: figure.table!, caption: figure.caption, id: figure.id || `published-${index}` }))
    : !component.table_id && rich.table ? [{ table: rich.table, caption: '', id: 'result' }] : []
}
export function automaticRich(rich: RichCell, components: CellComponent[]): RichCell {
  const displays = components.filter(item => displayKinds.includes(item.kind as typeof displayKinds[number]) && !displayError(item))
  const tables = displays.filter(item => item.kind === 'table'), allTables = tables.some(item => !item.table_id)
  const charts = new Set(displays.filter(item => item.kind === 'live_chart').flatMap(item => item.p1?.series?.length ? item.p1.series.map(series => series.id) : [item.chart_id || item.id]))
  const images = new Set(displays.filter(item => item.kind === 'image').map(item => item.image_id || item.id))
  const audio = displays.filter(item => item.kind === 'audio'), allAudio = audio.some(item => !item.audio_id)
  return { ...rich, table: allTables && !rich.displays.some(item => item.table) ? null : rich.table,
    displays: rich.displays.filter(item => !item.table || (!allTables && !tables.some(component => component.table_id === item.id))),
    charts: rich.charts.filter(item => !charts.has(item.id)), images: rich.images.filter(item => !images.has(item.id)),
    audio: (rich.audio || []).filter(item => !allAudio && !audio.some(component => component.audio_id === item.id)),
    audio_controls: rich.audio_controls?.filter(control => control.channel || rich.audio?.length === 1 && !rich.audio_limited) }
}
export function metricValue(source: string | null | undefined, settings: DisplaySettings = {}) {
  if (source == null || !/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(source) || !Number.isFinite(Number(source))) return { text: 'Unavailable', number: undefined }
  const number = Number(source), scaled = settings.percentage ? number * 100 : number
  if (!Number.isFinite(scaled)) return { text: 'Out of range', number }
  let text: string
  const exactInteger = /^[+-]?\d+$/.test(source) && BigInt(source) >= -9223372036854775808n && BigInt(source) <= 9223372036854775807n
  if (exactInteger && !settings.percentage && settings.precision === undefined) text = source
  else {
    const precision = Math.min(12, Math.max(0, settings.precision ?? 2))
    const options = { minimumFractionDigits: precision, maximumFractionDigits: precision, roundingMode: 'halfEven' as const }
    text = new Intl.NumberFormat(undefined, options).format(scaled)
  }
  return { text: text + (settings.percentage ? '%' : '') + (settings.unit ? ` ${settings.unit}` : ''), number }
}
