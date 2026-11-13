import { expect, test } from '@playwright/test'
import { axisTicks, paperGridLines, parseScene, plotFrame, type Viewport } from '../src/plot'

function fixture() {
  return {
    version: 2, bounds: [-1, -1, 3, 3], frame: [40, 40, 400, 280], padding: 40,
    color_scale: false, aspect_equal: false, y_down: false, axes: true,
    background: '#faf3df', title: '', x_label: 'X', y_label: 'Y', layers: [], decorations: [],
    typography: { size: 16, color: '#1f2937' }, ticks: { x_step: 1, y_step: 1 },
    paper: { ink: '#cc8653', spacing: 4, width: 40, height: 40, rgba: Buffer.alloc(40 * 40 * 4, 255).toString('base64') },
  }
}
test('paper scene validates bounded pixels, style, steps, and legacy compatibility', () => {
  const source = fixture()
  const parsed = parseScene(JSON.stringify(source), 480, 360)!
  expect(parsed.paper?.pixels.length).toBe(6400)
  expect(parsed.typography).toEqual({ size: 16, color: '#1f2937' })
  const legacy: any = { ...source, version: 1 }
  delete legacy.paper; delete legacy.typography; delete legacy.ticks
  expect(parseScene(JSON.stringify(legacy), 480, 360)?.version).toBe(1)
  const bad: ((v: any) => void)[] = [
    v => { v.version = 99 }, v => { v.paper.width = 1000000 },
    v => { v.paper.spacing = 33 }, v => { v.paper.rgba = 'https://invalid.example/image' },
    v => { v.paper.rgba = Buffer.alloc(6399).toString('base64') },
    v => { v.paper.ink = 'url(https://invalid.example/)' },
    v => { v.typography.size = 0 }, v => { v.typography.color = 'red' },
    v => { v.ticks.x_step = -1 }, v => { v.ticks.y_step = 1e-200 },
    v => { v.ticks = [] }, v => { delete v.typography },
    v => { v.version = 1 },
  ]
  for (const change of bad) { const altered = structuredClone(source); change(altered); expect(parseScene(JSON.stringify(altered), 480, 360)).toBeNull() }
})
test('major paper lines and ticks agree through zoom, pan, Y direction, and aspect', () => {
  const scene = parseScene(JSON.stringify(fixture()), 480, 360)!
  for (const down of [false, true]) for (const equal of [false, true]) for (const view of [[-1, -1, 3, 3], [.25, -.6, 2.25, 1.4], [-3, -2, 1, 2]] as Viewport[]) {
    const s = { ...scene, y_down: down, aspect_equal: equal }, f = plotFrame(s, view, 480, 360)
    const lines = paperGridLines(s, view, f)
    for (const axis of ['x', 'y'] as const) {
      const values = axisTicks(s, view, f, axis).values
      const major = lines.filter(l => l.axis === axis && l.level === 10)
      expect(major.map(l => l.value)).toEqual(values)
      for (const line of major) {
        const expected = axis === 'x' ? f.x + (line.value - view[0]) / (view[2] - view[0]) * f.width
          : f.y + (down ? line.value - view[1] : view[3] - line.value) / (view[3] - view[1]) * f.height
        expect(line.position).toBeCloseTo(expected, 8)
      }
    }
  }
  const original: Viewport = [-1, -1, 3, 3], zoom: Viewport = [.25, -1, 2.25, 3]
  const first = paperGridLines(scene, original, plotFrame(scene, original, 480, 360))
  const second = paperGridLines(scene, zoom, plotFrame(scene, zoom, 480, 360))
  const f = plotFrame(scene, original, 480, 360), z = plotFrame(scene, zoom, 480, 360)
  expect(first.find(l => l.axis === 'x' && l.value === 0)?.position).toBeCloseTo(f.x + f.width / 4)
  expect(second.find(l => l.axis === 'x' && l.value === 1)?.position).toBeCloseTo(z.x + .75 / 2 * z.width)
  const gap = (lines: typeof first) => lines.find(l => l.axis === 'x' && l.value === 2)!.position - lines.find(l => l.axis === 'x' && l.value === 1)!.position
  expect(gap(second) / gap(first)).toBeCloseTo(2)
  const far: Viewport = [-1e12, -1e12, 1e12, 1e12]
  expect(paperGridLines(scene, far, plotFrame(scene, far, 480, 360)).length).toBeLessThan(4096)
  const automatic = { ...scene, ticks: { x_step: null, y_step: null } }
  const panned: Viewport = [-.3, -.6, 3.7, 3.4]
  expect(paperGridLines(automatic, panned, plotFrame(automatic, panned, 480, 360)).some(l => l.axis === 'x' && l.value === 0 && l.level === 10)).toBe(true)
})
