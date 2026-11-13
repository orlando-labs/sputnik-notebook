export type Point = [number, number]
export type Viewport = [number, number, number, number]
export interface Frame { x: number; y: number; width: number; height: number }
interface Command {
  kind: number; fill: string; stroke: string; width: number; opacity: number; radius: number; size: number
  align: number; text: string; points: Point[]; rings: Point[][]; dash: number[]; position: Point
}
interface Layer { kind: string; commands: Command[]; guide_value?: number; anchor?: Point; offset?: Point; label_at?: string }
interface Typography { size: number; color: string }
interface TickSteps { x_step: number | null; y_step: number | null }
interface Paper { ink: string; spacing: number; width: number; height: number; pixels: Uint8ClampedArray }
export interface PlotScene {
  version: number; bounds: Viewport; frame: Viewport; padding: number; color_scale: boolean; aspect_equal: boolean
  y_down: boolean; axes: boolean; background: string; title: string; x_label: string; y_label: string
  layers: Layer[]; decorations: Command[]
  typography?: Typography; ticks?: TickSteps; paper?: Paper
}
const finite = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value) && Math.abs(value) < 1e150
const point = (value: unknown): value is Point => Array.isArray(value) && value.length === 2 && value.every(finite)
const color = (value: unknown): value is string => typeof value === 'string' && /^(none|transparent|#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6}|#[0-9a-fA-F]{8})$/.test(value)
const text = (value: unknown): value is string => typeof value === 'string' && new TextEncoder().encode(value).length <= 65536
export function validViewport(value: unknown): value is Viewport {
  return Array.isArray(value) && value.length === 4 && value.every(finite) && [0, 1].every(i => value[i + 2] - value[i] > Math.max(1e-150, Math.max(Math.abs(value[i]), Math.abs(value[i + 2])) * 1e-13))
}
export function parseScene(json: string, width: number, height: number): PlotScene | null {
  try {
    if (json.length > 4 * 1024 * 1024 || width < 1 || height < 1 || width > 8192 || height > 8192 || width * height > 16_000_000) return null
    const scene = JSON.parse(json)
    let nodes = 0
    function command(value: unknown): Command {
      if (!Array.isArray(value)) throw new Error('Invalid plot command')
      const c: Command = { kind: value[0], fill: 'none', stroke: 'none', width: 0, opacity: 1, radius: 0, size: 12, align: 0, text: '', points: [], rings: [], dash: [], position: [0, 0] }
      if (c.kind === 1 && value.length === 6) [c.fill, c.stroke, c.width, c.opacity, c.rings] = value.slice(1) as [string, string, number, number, Point[][]]
      else if (c.kind === 2 && [5, 6].includes(value.length)) { [c.stroke, c.width, c.opacity, c.points] = value.slice(1) as [string, number, number, Point[]]; c.dash = value[5] || [] }
      else if (c.kind === 3 && value.length === 7) [c.fill, c.stroke, c.width, c.opacity, c.radius, c.points] = value.slice(1) as [string, string, number, number, number, Point[]]
      else if (c.kind === 4 && value.length === 7) { c.fill = value[1]; c.size = value[2]; c.position = [value[3], value[4]]; c.align = value[5]; c.text = value[6] }
      else throw new Error('Unknown plot command')
      if (!color(c.fill) || !color(c.stroke) || ![c.width, c.opacity, c.radius, c.size].every(finite) || c.width < 0 || c.width > 1024 || c.opacity < 0 || c.opacity > 1 || c.radius < 0 || c.radius > 1024 || c.size < 1 || c.size > 512 || ![0, 1, 2].includes(c.align) || !text(c.text) || !point(c.position) || !Array.isArray(c.points) || !c.points.every(point) || !Array.isArray(c.rings) || !c.rings.every(ring => Array.isArray(ring) && ring.every(point)) || !Array.isArray(c.dash) || c.dash.length > 64 || !c.dash.every(value => finite(value) && value >= .1 && value <= 10000)) throw new Error('Invalid plot geometry')
      nodes += 1 + c.points.length + c.rings.reduce((sum, ring) => sum + ring.length, 0)
      if (nodes > 100000) throw new Error('Plot geometry limit')
      return c
    }
    if (![1, 2].includes(scene.version) || !validViewport(scene.bounds) || !Array.isArray(scene.frame) || scene.frame.length !== 4 || !scene.frame.every(finite) || scene.frame[0] < 0 || scene.frame[1] < 0 || scene.frame[2] <= 0 || scene.frame[3] <= 0 || scene.frame[0] + scene.frame[2] > width + .001 || scene.frame[1] + scene.frame[3] > height + .001 || !finite(scene.padding) || scene.padding < 0 || scene.padding >= Math.min(width, height) / 2 || width - 2 * scene.padding - (scene.color_scale ? 72 : 0) <= 0 || height - 2 * scene.padding - (scene.title ? 24 : 0) <= 0 || !color(scene.background) || ![scene.title, scene.x_label, scene.y_label].every(text) || !['color_scale', 'aspect_equal', 'y_down', 'axes'].every(key => typeof scene[key] === 'boolean') || !Array.isArray(scene.layers) || scene.layers.length > 10000 || !Array.isArray(scene.decorations)) return null
    let typography: Typography | undefined, ticks: TickSteps | undefined, paper: Paper | undefined
    if (scene.version === 2) {
      const t = scene.typography, steps = scene.ticks
      const validStep = (value: unknown) => value == null || (finite(value) && value >= 1e-150)
      if (!t || Array.isArray(t) || !finite(t.size) || t.size < 1 || t.size > 128 || !color(t.color) || !steps || typeof steps !== 'object' || Array.isArray(steps) || !validStep(steps.x_step) || !validStep(steps.y_step)) return null
      typography = { size: t.size, color: t.color }; ticks = { x_step: steps.x_step ?? null, y_step: steps.y_step ?? null }
      if (scene.paper != null) {
        const p = scene.paper
        if (!color(p.ink) || !Number.isInteger(p.spacing) || p.spacing < 4 || p.spacing > 32 || p.width !== p.spacing * 10 || p.height !== p.width || typeof p.rgba !== 'string' || p.rgba.length !== 4 * Math.ceil(p.width * p.height * 4 / 3) || !/^[A-Za-z0-9+/]*={0,2}$/.test(p.rgba)) return null
        const raw = atob(p.rgba)
        if (raw.length !== p.width * p.height * 4) return null
        paper = { ink: p.ink, spacing: p.spacing, width: p.width, height: p.height, pixels: Uint8ClampedArray.from(raw, (c: string) => c.charCodeAt(0)) }
      }
    } else if (scene.paper != null || scene.typography != null || scene.ticks != null) return null
    const layers = scene.layers.map((layer: Layer & { commands: unknown[] }) => {
      if (!['line', 'points', 'polygons', 'mesh', 'guide', 'vline', 'hline', 'annotation'].includes(layer.kind) || !Array.isArray(layer.commands) || (layer.guide_value != null && !finite(layer.guide_value)) || (layer.anchor != null && !point(layer.anchor)) || (layer.offset != null && !point(layer.offset))) throw new Error('Invalid plot layer')
      if (['vline', 'hline'].includes(layer.kind) && !finite(layer.guide_value)) throw new Error('Invalid plot guide')
      if (['vline', 'hline', 'guide', 'annotation'].includes(layer.kind) && (!point(layer.anchor) || !point(layer.offset) || !['start', 'middle', 'end'].includes(layer.label_at || ''))) throw new Error('Invalid plot annotation')
      return { ...layer, commands: layer.commands.map(command) }
    })
    return { ...scene, typography, ticks, paper, layers, decorations: scene.decorations.map(command) }
  } catch { return null }
}
export function plotFrame(scene: PlotScene, view: Viewport, width: number, height: number): Frame {
  // Leave space for scientific/negative ticks using the scene's font metrics,
  // at the current zoom, including the centered first/last X ticks.
  let left = scene.padding, right = scene.padding
  if (scene.axes) {
    const advance = (scene.typography?.size || 11) * .64
    const span = view[3] - view[1]
    for (let i = 0; i <= 5; i++) left = Math.max(left, tick(view[1] + i / 5 * span, span).length * advance + 12)
    left = Math.max(left, tick(view[0], view[2] - view[0]).length * advance / 2 + 4)
    right = Math.max(right, tick(view[2], view[2] - view[0]).length * advance / 2 + 4)
  }
  const available = Math.max(1, width - (scene.color_scale ? 72 : 0)), margins = available - Math.min(48, available / 2)
  if (left + right > margins) { const scale = margins / (left + right); left *= scale; right *= scale }
  const f = { x: left, y: scene.padding + (scene.title ? 24 : 0), width: width - left - right - (scene.color_scale ? 72 : 0), height: height - 2 * scene.padding - (scene.title ? 24 : 0) }
  if (scene.aspect_equal && f.width > 0 && f.height > 0) {
    const scale = Math.min(f.width / (view[2] - view[0]), f.height / (view[3] - view[1]))
    const w = (view[2] - view[0]) * scale, h = (view[3] - view[1]) * scale
    f.x += (f.width - w) / 2; f.y += (f.height - h) / 2; f.width = w; f.height = h
  }
  return f
}
export function dataPoint(p: Point, scene: PlotScene, view: Viewport, f: Frame): Point {
  return [view[0] + (p[0] - f.x) / f.width * (view[2] - view[0]), scene.y_down ? view[1] + (p[1] - f.y) / f.height * (view[3] - view[1]) : view[3] - (p[1] - f.y) / f.height * (view[3] - view[1])]
}
function screenPoint(p: Point, scene: PlotScene, view: Viewport, f: Frame): Point {
  return [f.x + (p[0] - view[0]) / (view[2] - view[0]) * f.width, f.y + (scene.y_down ? p[1] - view[1] : view[3] - p[1]) / (view[3] - view[1]) * f.height]
}
export function tick(value: number, span: number) {
  const precision = Math.max(1, Math.min(16, Math.ceil(Math.log10(Math.max(Math.abs(value), 1e-150)) - Math.log10(span)) + 3))
  return Number(value.toPrecision(precision)).toString()
}
function tickValues(low: number, high: number, step: number) {
  const first = Math.ceil(low / step - 1e-9), last = Math.floor(high / step + 1e-9), count = last - first + 1
  if (!Number.isFinite(count) || count < 0 || count > 4096) return []
  return Array.from({ length: count }, (_, i) => { const value = (first + i) * step; return Math.abs(value) < step * 1e-9 ? 0 : value })
}
export function axisTicks(scene: PlotScene, view: Viewport, f: Frame, axis: 'x' | 'y') {
  const low = view[axis === 'x' ? 0 : 1], high = view[axis === 'x' ? 2 : 3], span = high - low, pixels = axis === 'x' ? f.width : f.height
  let step = scene.ticks?.[axis === 'x' ? 'x_step' : 'y_step'] ?? null
  if (step === null && !scene.paper) {
    let count = axis === 'x' ? Math.max(2, Math.min(5, Math.floor(pixels / 85))) : 5
    if (axis === 'x' && Number.isInteger(low) && Number.isInteger(high)) while (count > 1 && span % count !== 0) count--
    return { step: span / count, values: Array.from({ length: count + 1 }, (_, i) => low + i / count * span) }
  }
  if (step === null) {
    const intervals = Math.max(2, Math.min(10, Math.floor(pixels / (scene.paper!.spacing * 10))))
    const raw = span / intervals, unit = 10 ** Math.floor(Math.log10(raw))
    step = unit * 10
    for (const factor of [10, 5, 2.5, 2, 1]) if (unit * factor >= raw) step = unit * factor
  }
  // Bound work when an explicit fine grid is zoomed far out. The visible step
  // stays a power-of-ten multiple of the requested step and returns on zoom-in.
  if (span / step > 200) step *= 10 ** Math.ceil(Math.log10(span / step / 200))
  return { step, values: tickValues(low, high, step) }
}
export function paperGridLines(scene: PlotScene, view: Viewport, f: Frame) {
  const lines: { axis: 'x' | 'y'; value: number; position: number; level: number }[] = []
  if (!scene.paper) return lines
  for (const axis of ['x', 'y'] as const) {
    const { step } = axisTicks(scene, view, f, axis)
    for (let value of tickValues(view[axis === 'x' ? 0 : 1], view[axis === 'x' ? 2 : 3], step / 10)) {
      let level = Math.abs(value / (step / 2) - Math.round(value / (step / 2))) < 1e-7 ? 5 : 1
      if (Math.abs(value / step - Math.round(value / step)) < 1e-7) { level = 10; value = Math.round(value / step) * step }
      const p = screenPoint(axis === 'x' ? [value, view[1]] : [view[0], value], scene, view, f)
      lines.push({ axis, value, position: p[axis === 'x' ? 0 : 1], level })
    }
  }
  return lines
}
const paperTiles = new WeakMap<Paper, HTMLCanvasElement>()
function grainTile(paper: Paper) {
  let tile = paperTiles.get(paper)
  if (!tile) {
    tile = document.createElement('canvas'); tile.width = paper.width; tile.height = paper.height
    const ctx = tile.getContext('2d')!
    const pixels = ctx.createImageData(paper.width, paper.height); pixels.data.set(paper.pixels); ctx.putImageData(pixels, 0, 0)
    paperTiles.set(paper, tile)
  }
  return tile
}
function clippedSegment(a: Point, b: Point, f: Frame): [Point, Point] | null {
  const dx = b[0] - a[0], dy = b[1] - a[1]
  let low = 0, high = 1
  for (const [p, q] of [[-dx, a[0] - f.x], [dx, f.x + f.width - a[0]], [-dy, a[1] - f.y], [dy, f.y + f.height - a[1]]] as Point[]) {
    if (p === 0 && q < 0) return null
    if (p !== 0) { const r = q / p; if (p < 0) low = Math.max(low, r); else high = Math.min(high, r) }
    if (low > high) return null
  }
  return [[a[0] + dx * low, a[1] + dy * low], [a[0] + dx * high, a[1] + dy * high]]
}
function clippedPolygon(source: Point[], f: Frame) {
  let points = source
  for (let edge = 0; edge < 4; edge++) {
    const axis = edge >= 2 ? 1 : 0, limit = [f.x, f.x + f.width, f.y, f.y + f.height][edge]!
    const inside = (p: Point) => edge % 2 === 0 ? p[axis] >= limit : p[axis] <= limit
    const output: Point[] = []
    let previous = points.at(-1)
    if (!previous) break
    for (const p of points) {
      if (inside(previous) !== inside(p)) { const t = (limit - previous[axis]) / (p[axis] - previous[axis]); output.push(axis === 0 ? [limit, previous[1] + (p[1] - previous[1]) * t] : [previous[0] + (p[0] - previous[0]) * t, limit]) }
      if (inside(p)) output.push(p)
      previous = p
    }
    points = output
  }
  return points
}
export function drawPlot(ctx: CanvasRenderingContext2D, scene: PlotScene, view: Viewport, width: number, height: number) {
  const f = plotFrame(scene, view, width, height)
  ctx.clearRect(0, 0, width, height)
  ctx.fillStyle = scene.background === 'none' ? 'transparent' : scene.background; ctx.fillRect(0, 0, width, height)
  if (scene.paper) { const pattern = ctx.createPattern(grainTile(scene.paper), 'repeat'); if (pattern) { ctx.fillStyle = pattern; ctx.fillRect(0, 0, width, height) } }
  if (f.width <= 0 || f.height <= 0) return
  const original = { x: scene.frame[0], y: scene.frame[1], width: scene.frame[2], height: scene.frame[3] }
  const size = scene.typography?.size || 11, ink = scene.typography?.color || '#4b5563'
  function label(value: string, p: Point, size: number, fill: string, align = 0, maximumWidth?: number, clipped = false) {
    ctx.fillStyle = fill === 'none' ? 'transparent' : fill; ctx.font = `${size}px SFMono-Regular, Consolas, monospace`; ctx.textAlign = ['left', 'center', 'right'][align] as CanvasTextAlign; ctx.textBaseline = 'top'
    if (clipped) { const w = ctx.measureText(value).width, left = p[0] - w * align / 2; if (left < f.x || left + w > f.x + f.width || p[1] < f.y || p[1] + size > f.y + f.height) return }
    if (maximumWidth === undefined) ctx.fillText(value, p[0], p[1]); else ctx.fillText(value, p[0], p[1], Math.max(1, maximumWidth))
  }
  function line(a: Point, b: Point, stroke: string, width = 1, opacity = 1) { ctx.save(); ctx.strokeStyle = stroke; ctx.lineWidth = width; ctx.globalAlpha = opacity; ctx.beginPath(); ctx.moveTo(...a); ctx.lineTo(...b); ctx.stroke(); ctx.restore() }
  if (scene.paper) {
    ctx.save(); ctx.beginPath(); ctx.rect(f.x, f.y, f.width, f.height); ctx.clip()
    for (const l of paperGridLines(scene, view, f)) {
      const width = l.level === 10 ? 1.1 : l.level === 5 ? .8 : .55, opacity = l.level === 10 ? .65 : l.level === 5 ? .45 : .28
      line(l.axis === 'x' ? [l.position, f.y] : [f.x, l.position], l.axis === 'x' ? [l.position, f.y + f.height] : [f.x + f.width, l.position], scene.paper.ink, width, opacity)
    }
    ctx.restore()
  }
  if (scene.title) label(scene.title, [width / 2, scene.typography ? 20 : 18], scene.typography ? size * 1.625 : 20, scene.typography ? ink : '#111827', 1)
  if (scene.axes) {
    const xs = axisTicks(scene, view, f, 'x'), ys = axisTicks(scene, view, f, 'y')
    for (const value of xs.values) { const x = screenPoint([value, view[1]], scene, view, f)[0]; if (!scene.paper) line([x, f.y], [x, f.y + f.height], '#e5e7eb'); label(tick(value, xs.step), [x, f.y + f.height + (scene.typography ? 12 : 9)], size, ink, 1, Math.min(2 * (x - 4), 2 * (width - x - 4), f.width / Math.max(1, xs.values.length - 1) - 8)) }
    for (const value of ys.values) { const y = screenPoint([view[0], value], scene, view, f)[1]; if (!scene.paper) line([f.x, y], [f.x + f.width, y], '#e5e7eb'); label(tick(value, ys.step), [f.x - (scene.typography ? 12 : 8), y - size / 2], size, ink, 2, f.x - 12) }
    const axisSize = scene.typography ? size * 1.125 : 13, axisInk = scene.typography ? ink : '#374151'
    label(scene.x_label, [f.x + f.width / 2, f.y + f.height + (scene.typography ? size + 24 : 33)], axisSize, axisInk, 1)
    label(scene.y_label, [f.x, f.y - axisSize - (scene.typography ? 16 : 9)], axisSize, axisInk)
  }
  function draw(c: Command, layer?: Layer) {
    const project = (p: Point): Point => layer ? screenPoint(dataPoint(p, scene, scene.bounds, original), scene, view, f) : [p[0] + f.x + f.width - original.x - original.width, p[1] + f.y - original.y]
    ctx.save(); ctx.globalAlpha = c.opacity; ctx.lineWidth = c.width; ctx.lineCap = 'round'; ctx.lineJoin = 'round'; ctx.setLineDash(c.dash)
    ctx.fillStyle = c.fill === 'none' ? 'transparent' : c.fill; ctx.strokeStyle = c.stroke === 'none' ? 'transparent' : c.stroke
    ctx.beginPath()
    if (c.kind === 1) for (const ring of c.rings) { const points = layer ? clippedPolygon(ring.map(project), f) : ring.map(project); points.forEach((p, i) => i ? ctx.lineTo(...p) : ctx.moveTo(...p)); ctx.closePath() }
    if (c.kind === 2) {
      if (layer?.guide_value != null && ['vline', 'hline'].includes(layer.kind)) {
        const p = screenPoint(layer.kind === 'vline' ? [layer.guide_value, view[1]] : [view[0], layer.guide_value], scene, view, f)
        if (layer.kind === 'vline') { ctx.moveTo(p[0], f.y); ctx.lineTo(p[0], f.y + f.height) } else { ctx.moveTo(f.x, p[1]); ctx.lineTo(f.x + f.width, p[1]) }
      } else for (let i = 1; i < c.points.length; i++) { const pair = clippedSegment(project(c.points[i - 1]!), project(c.points[i]!), f); if (pair) { ctx.moveTo(...pair[0]); ctx.lineTo(...pair[1]) } }
    }
    if (c.kind === 3) for (const raw of c.points) { const p = project(raw); if (p[0] >= f.x - c.radius && p[0] <= f.x + f.width + c.radius && p[1] >= f.y - c.radius && p[1] <= f.y + f.height + c.radius) { ctx.moveTo(p[0] + c.radius, p[1]); ctx.arc(...p, c.radius, 0, Math.PI * 2) } }
    if (c.kind === 4) {
      let p = project(c.position)
      if (layer?.anchor && layer.offset) {
        const a: Point = [...layer.anchor], t = layer.label_at === 'start' ? 0 : layer.label_at === 'end' ? 1 : .5
        if (layer.kind === 'vline') a[1] = scene.y_down ? view[1] + t * (view[3] - view[1]) : view[3] - t * (view[3] - view[1])
        if (layer.kind === 'hline') a[0] = view[0] + t * (view[2] - view[0])
        p = screenPoint(a, scene, view, f); p[0] += layer.offset[0]; p[1] += layer.offset[1]
      }
      label(c.text, p, c.size, c.fill, c.align, undefined, layer !== undefined)
    } else { ctx.fill('evenodd'); if (c.width > 0) ctx.stroke() }
    ctx.restore()
  }
  ctx.save(); ctx.beginPath(); ctx.rect(f.x, f.y, f.width, f.height); ctx.clip()
  for (const layer of scene.layers) for (const c of layer.commands) draw(c, layer)
  ctx.restore()
  if (scene.axes) { ctx.strokeStyle = scene.typography ? '#64748b' : '#9ca3af'; ctx.lineWidth = 1; ctx.strokeRect(f.x, f.y, f.width, f.height) }
  for (const c of scene.decorations) draw(c)
}
