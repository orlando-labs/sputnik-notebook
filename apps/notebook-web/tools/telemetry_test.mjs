import assert from 'node:assert/strict'
import ts from '../frontend/node_modules/typescript/lib/typescript.js'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
const root = await mkdtemp(path.join(tmpdir(), 'sputnik-web-telemetry-'))
try {
  for (const name of ['plot', 'telemetry']) {
    const code = ts.transpileModule(await readFile(new URL(`../frontend/src/${name}.ts`, import.meta.url), 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText
    await writeFile(path.join(root, `${name}.mjs`), code)
  }
  const { chartFigure, chartCSV, duration, sampledPoints } = await import('file://' + path.join(root, 'telemetry.mjs'))
  const { parseScene, plotFrame, dataPoint } = await import('file://' + path.join(root, 'plot.mjs'))
  assert.equal(duration('9223372036854775807'), '2562047788015:12:55.80')
  assert.equal(duration('0'), '00:00.00')
  assert.equal(duration('3601234'), '1:00:01.23')
  assert.equal(duration('-1'), '—')
  for (const points of [[[0, 0]], [[1e-200, -1e-200], [2e-200, -2e-200]], [[-1e99, 1e99], [1e99, -1e99]]]) {
    const figure = chartFigure({ id: 'edge', points, total_points: '18446744073709551615' })
    assert(figure)
    assert(parseScene(figure.plot_scene, figure.width, figure.height))
  }
  const points = Array.from({ length: 65536 }, (_, i) => [i, i === 32123 ? 1000000 : i % 7])
  const sampled = sampledPoints(points)
  assert(sampled.length <= 2048)
  assert.deepEqual(sampled[0], points[0]); assert.deepEqual(sampled.at(-1), points.at(-1))
  assert(sampled.includes(points[32123]), 'sampling must retain the spike')
  assert(sampled.every((point, i) => i === 0 || point[0] > sampled[i - 1][0]), 'sampling preserves order')
  assert.equal(chartCSV({ id: 'csv', points, total_points: '65536' }).split('\r\n').length, 65538)
  assert.equal(chartCSV({ id: 'exact', points: [[1e-200, -1.2345678901234567]], total_points: '1' }), 'X,Y\r\n1e-200,-1.2345678901234567\r\n')
  const narrow = chartFigure({ id: 'mobile', points: [[0, -1.23456789e-10], [1, 2.34567891e-10]], total_points: '2' })
  const scene = parseScene(narrow.plot_scene, narrow.width, narrow.height)
  const frame = plotFrame(scene, scene.bounds, 282, 185)
  assert(frame.x > 56 && frame.width > 0, 'scientific ticks need space on a narrow canvas')
  const corner = dataPoint([frame.x, frame.y + frame.height], scene, scene.bounds, frame)
  assert(corner.every((value, i) => Math.abs(value - scene.bounds[i]) <= (scene.bounds[i + 2] - scene.bounds[i]) * 1e-13))
  assert(plotFrame(scene, [1, 1, 1.000000000001, 1.000000000001], 120, 180).width > 0, 'labels cannot consume the entire plot')
  console.log('PASS exact duration, chart edge domains, bounded extrema sampling and complete CSV')
} finally { await rm(root, { recursive: true, force: true }) }
