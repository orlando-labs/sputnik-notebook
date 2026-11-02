import type { Figure, LiveChart } from './rich'
import type { Point, Viewport } from './plot'

export function duration(milliseconds: string) {
  if (!/^\d{1,20}$/.test(milliseconds)) return '—'
  const value = BigInt(milliseconds), seconds = value / 1000n
  const pad = (part: bigint) => part.toString().padStart(2, '0')
  const tail = `${pad(seconds % 60n)}.${pad(value % 1000n / 10n)}`
  return seconds >= 3600n ? `${seconds / 3600n}:${pad(seconds / 60n % 60n)}:${tail}` : `${pad(seconds / 60n)}:${tail}`
}
export const progressNumber = (value: number) => Number(value.toPrecision(6)).toString()

// Keep first/last and each bucket's extrema, in original order. The CSV always
// contains every retained point; sampling only bounds the canvas geometry.
export function sampledPoints(points: Point[], maximum = 2048): Point[] {
  if (points.length <= maximum) return points
  const buckets = Math.max(1, Math.floor((maximum - 2) / 4)), result: Point[] = [points[0]!]
  for (let bucket = 0; bucket < buckets; bucket++) {
    const start = 1 + Math.floor(bucket * (points.length - 2) / buckets)
    const end = 1 + Math.floor((bucket + 1) * (points.length - 2) / buckets)
    const indices = [start, start, start, start]
    for (let i = start + 1; i < end; i++) {
      if (points[i]![0] < points[indices[0]!]![0]) indices[0] = i
      if (points[i]![0] > points[indices[1]!]![0]) indices[1] = i
      if (points[i]![1] < points[indices[2]!]![1]) indices[2] = i
      if (points[i]![1] > points[indices[3]!]![1]) indices[3] = i
    }
    for (const i of [...new Set(indices)].sort((a, b) => a - b)) result.push(points[i]!)
  }
  result.push(points.at(-1)!)
  return result
}

export interface ChartStyle { title?: string; x_label?: string; y_label?: string; x_min?: number; x_max?: number; y_min?: number; y_max?: number; stroke?: string }
export interface StyledChart { chart: LiveChart; stroke: string }
export function chartFigure(chart: LiveChart, style: ChartStyle = {}): Figure | null {
  return chartsFigure([{ chart, stroke: style.stroke || '#d97706' }], style)
}
export function chartsFigure(series: StyledChart[], style: ChartStyle = {}): Figure | null {
  const first = series.find(item => item.chart.points.length)?.chart.points[0]
  if (!first) return null
  const bounds: Viewport = [first[0], first[1], first[0], first[1]]
  let integralX = true
  let count = 0
  for (const item of series) for (const [x, y] of item.chart.points) {
    bounds[0] = Math.min(bounds[0], x); bounds[2] = Math.max(bounds[2], x)
    bounds[1] = Math.min(bounds[1], y); bounds[3] = Math.max(bounds[3], y)
    integralX &&= Number.isInteger(x)
    count++
  }
  if (integralX) {
    if (style.x_min === undefined) bounds[0] = Math.min(0, bounds[0])
    if (style.x_max === undefined) bounds[2] = Math.max(0, bounds[2])
    const rough = Math.max(1, (bounds[2] - bounds[0]) / 5), power = 10 ** Math.floor(Math.log10(rough)), fraction = rough / power
    const step = (fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10) * power
    if (style.x_min === undefined) bounds[0] = Math.floor(bounds[0] / step) * step
    if (style.x_max === undefined) { bounds[2] = Math.ceil(bounds[2] / step) * step; if (count === 1) bounds[2] += step }
  }
  if (style.x_min !== undefined) bounds[0] = style.x_min
  if (style.x_max !== undefined) bounds[2] = style.x_max
  if (style.y_min !== undefined) bounds[1] = style.y_min
  if (style.y_max !== undefined) bounds[3] = style.y_max
  for (const axis of [0, 1]) {
    const scale = Math.max(Math.abs(bounds[axis]!), Math.abs(bounds[axis + 2]!))
    if (bounds[axis + 2]! - bounds[axis]! <= Math.max(1e-100, scale * 1e-13)) {
      const center = (bounds[axis]! + bounds[axis + 2]!) / 2, delta = Math.max(.5, scale * 1e-6)
      const low = axis === 0 ? style.x_min : style.y_min, high = axis === 0 ? style.x_max : style.y_max
      if (low !== undefined && high === undefined) bounds[axis + 2] = bounds[axis]! + 2 * delta
      else if (high !== undefined && low === undefined) bounds[axis] = bounds[axis + 2]! - 2 * delta
      else { bounds[axis] = center - delta; bounds[axis + 2] = center + delta }
    }
  }
  const title = style.title || '', top = title ? 80 : 56, height = title ? 284 : 308
  const layers = series.filter(item => item.chart.points.length).map(item => {
    const points = sampledPoints(item.chart.points).map(([x, y]) => [56 + (x - bounds[0]) / (bounds[2] - bounds[0]) * 528, top + (bounds[3] - y) / (bounds[3] - bounds[1]) * height])
    const command = points.length === 1 ? [3, item.stroke, 'none', 0, 1, 3, points] : [2, item.stroke, 2, 1, points]
    return { kind: points.length === 1 ? 'points' : 'line', commands: [command] }
  })
  const id = series[0]!.chart.id
  return { id, mime: 'application/vnd.sputnik.plot+json', caption: style.title === undefined ? id : '', width: 640, height: 420,
    plot_scene: JSON.stringify({ version: 1, bounds, frame: [56, top, 528, height], padding: 56, color_scale: false, aspect_equal: false,
      y_down: false, axes: true, background: '#ffffff', title, x_label: style.x_label ?? 'X', y_label: style.y_label ?? 'Y', layers, decorations: [] }) }
}
export function chartCSV(chart: LiveChart) {
  return 'X,Y\r\n' + chart.points.map(([x, y]) => `${x},${y}\r\n`).join('')
}
