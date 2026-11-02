export type Point = [number, number]
export type Viewport = [number, number, number, number]
export interface Frame { x: number; y: number; width: number; height: number }
interface Command {
  kind: number; fill: string; stroke: string; width: number; opacity: number; radius: number; size: number
  align: number; text: string; points: Point[]; rings: Point[][]; dash: number[]; position: Point
}
interface Layer { kind: string; commands: Command[]; guide_value?: number; anchor?: Point; offset?: Point; label_at?: string }
export interface PlotScene {
  version: number; bounds: Viewport; frame: Viewport; padding: number; color_scale: boolean; aspect_equal: boolean
  y_down: boolean; axes: boolean; background: string; title: string; x_label: string; y_label: string
  layers: Layer[]; decorations: Command[]
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
    if (scene.version !== 1 || !validViewport(scene.bounds) || !Array.isArray(scene.frame) || scene.frame.length !== 4 || !scene.frame.every(finite) || scene.frame[0] < 0 || scene.frame[1] < 0 || scene.frame[2] <= 0 || scene.frame[3] <= 0 || scene.frame[0] + scene.frame[2] > width + .001 || scene.frame[1] + scene.frame[3] > height + .001 || !finite(scene.padding) || scene.padding < 0 || scene.padding >= Math.min(width, height) / 2 || width - 2 * scene.padding - (scene.color_scale ? 72 : 0) <= 0 || height - 2 * scene.padding - (scene.title ? 24 : 0) <= 0 || !color(scene.background) || ![scene.title, scene.x_label, scene.y_label].every(text) || !['color_scale', 'aspect_equal', 'y_down', 'axes'].every(key => typeof scene[key] === 'boolean') || !Array.isArray(scene.layers) || scene.layers.length > 10000 || !Array.isArray(scene.decorations)) return null
    const layers = scene.layers.map((layer: Layer & { commands: unknown[] }) => {
      if (!['line', 'points', 'polygons', 'mesh', 'guide', 'vline', 'hline', 'annotation'].includes(layer.kind) || !Array.isArray(layer.commands) || (layer.guide_value != null && !finite(layer.guide_value)) || (layer.anchor != null && !point(layer.anchor)) || (layer.offset != null && !point(layer.offset))) throw new Error('Invalid plot layer')
      if (['vline', 'hline'].includes(layer.kind) && !finite(layer.guide_value)) throw new Error('Invalid plot guide')
      if (['vline', 'hline', 'guide', 'annotation'].includes(layer.kind) && (!point(layer.anchor) || !point(layer.offset) || !['start', 'middle', 'end'].includes(layer.label_at || ''))) throw new Error('Invalid plot annotation')
      return { ...layer, commands: layer.commands.map(command) }
    })
    return { ...scene, layers, decorations: scene.decorations.map(command) }
  } catch { return null }
}
export function plotFrame(scene: PlotScene, view: Viewport, width: number, height: number): Frame {
  // Axis labels use 11px monospace. Leave space for scientific/negative ticks
  // at the current zoom, including the centered first/last X ticks.
  let left = scene.padding, right = scene.padding
  if (scene.axes) {
    const span = view[3] - view[1]
    for (let i = 0; i <= 5; i++) left = Math.max(left, tick(view[1] + i / 5 * span, span).length * 7 + 12)
    left = Math.max(left, tick(view[0], view[2] - view[0]).length * 3.5 + 4)
    right = Math.max(right, tick(view[2], view[2] - view[0]).length * 3.5 + 4)
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
  const precision = Math.max(1, Math.min(13, Math.ceil(Math.log10(Math.max(Math.abs(value), 1e-150)) - Math.log10(span)) + 3))
  return Number(value.toPrecision(precision)).toString()
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
  if (f.width <= 0 || f.height <= 0) return
  const original = { x: scene.frame[0], y: scene.frame[1], width: scene.frame[2], height: scene.frame[3] }
  function label(value: string, p: Point, size: number, fill: string, align = 0, maximumWidth?: number) {
    ctx.fillStyle = fill === 'none' ? 'transparent' : fill; ctx.font = `${size}px SFMono-Regular, Consolas, monospace`; ctx.textAlign = ['left', 'center', 'right'][align] as CanvasTextAlign; ctx.textBaseline = 'top'
    if (maximumWidth === undefined) ctx.fillText(value, p[0], p[1]); else ctx.fillText(value, p[0], p[1], Math.max(1, maximumWidth))
  }
  function line(a: Point, b: Point, stroke: string) { ctx.strokeStyle = stroke; ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(...a); ctx.lineTo(...b); ctx.stroke() }
  if (scene.title) label(scene.title, [width / 2, 18], 20, '#111827', 1)
  if (scene.axes) {
    let intervals = Math.max(2, Math.min(5, Math.floor(f.width / 85)))
    const span = view[2] - view[0]
    if (Number.isInteger(view[0]) && Number.isInteger(view[2])) while (intervals > 1 && span % intervals !== 0) intervals--
    for (let i = 0; i <= intervals; i++) { const t = i / intervals, x = f.x + t * f.width; line([x, f.y], [x, f.y + f.height], '#e5e7eb'); label(tick(view[0] + t * span, span), [x, f.y + f.height + 9], 11, '#4b5563', 1, i === 0 ? 2 * (f.x - 4) : i === intervals ? 2 * (width - x - 4) : f.width / intervals - 8) }
    for (let i = 0; i <= 5; i++) { const t = i / 5, y = f.y + t * f.height; line([f.x, y], [f.x + f.width, y], '#e5e7eb'); label(tick(scene.y_down ? view[1] + t * (view[3] - view[1]) : view[3] - t * (view[3] - view[1]), view[3] - view[1]), [f.x - 8, y - 5], 11, '#4b5563', 2, f.x - 12) }
    label(scene.x_label, [f.x + f.width / 2, f.y + f.height + 33], 13, '#374151', 1); label(scene.y_label, [f.x, f.y - 22], 13, '#374151')
  }
  function draw(c: Command, layer?: Layer) {
    const project = (p: Point): Point => layer ? screenPoint(dataPoint(p, scene, scene.bounds, original), scene, view, f) : [p[0] + f.x + f.width - original.x - original.width, p[1] + f.y - original.y]
    ctx.save(); ctx.globalAlpha = c.opacity; ctx.lineWidth = c.width; ctx.lineCap = 'round'; ctx.lineJoin = 'round'; ctx.setLineDash(c.dash)
    ctx.fillStyle = c.fill === 'none' ? 'transparent' : c.fill; ctx.strokeStyle = c.stroke === 'none' ? 'transparent' : c.stroke
    ctx.beginPath()
    if (c.kind === 1) for (const ring of c.rings) { const points = layer ? clippedPolygon(ring.map(project), f) : ring.map(project); points.forEach((p, i) => i ? ctx.lineTo(...p) : ctx.moveTo(...p)); ctx.closePath() }
    if (c.kind === 2) {
      if (layer?.guide_value != null && ['vline', 'hline'].includes(layer.kind)) {
        const p = screenPoint([layer.guide_value, layer.guide_value], scene, view, f)
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
      label(c.text, p, c.size, c.fill, c.align)
    } else { ctx.fill('evenodd'); if (c.width > 0) ctx.stroke() }
    ctx.restore()
  }
  ctx.save(); ctx.beginPath(); ctx.rect(f.x, f.y, f.width, f.height); ctx.clip()
  for (const layer of scene.layers) for (const c of layer.commands) draw(c, layer)
  ctx.restore()
  if (scene.axes) { ctx.strokeStyle = '#9ca3af'; ctx.lineWidth = 1; ctx.strokeRect(f.x, f.y, f.width, f.height) }
  for (const c of scene.decorations) draw(c)
}
