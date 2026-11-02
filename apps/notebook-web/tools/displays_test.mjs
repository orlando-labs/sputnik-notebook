import assert from 'node:assert/strict'
import ts from '../frontend/node_modules/typescript/lib/typescript.js'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
const root = await mkdtemp(path.join(tmpdir(), 'sputnik-web-displays-'))
try {
  for (const name of ['document-json', 'displays', 'plot', 'telemetry']) {
    const code = ts.transpileModule(await readFile(new URL(`../frontend/src/${name}.ts`, import.meta.url), 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText.replaceAll("'./document-json'", "'./document-json.mjs'")
    await writeFile(path.join(root, `${name}.mjs`), code)
  }
  const { displayError, metricValue, automaticRich, displayTables } = await import('file://' + path.join(root, 'displays.mjs'))
  const { parseDocumentJSON, documentJSON } = await import('file://' + path.join(root, 'document-json.mjs'))
  const { chartsFigure } = await import('file://' + path.join(root, 'telemetry.mjs'))
  const { parseScene } = await import('file://' + path.join(root, 'plot.mjs'))
  assert.equal(metricValue('9223372036854775807').text, '9223372036854775807')
  assert.equal(metricValue('-9223372036854775808').text, '-9223372036854775808')
  assert.equal(metricValue('0.875', { percentage: true, precision: 1, unit: 'score' }).text, '87.5% score')
  assert.deepEqual(['0.125', '0.375', '1.005', '-0.125'].map(value => metricValue(value).text), ['0.12', '0.38', '1.00', '-0.12'], 'match Swift half-even formatting')
  assert.equal(metricValue('private text').text, 'Unavailable')
  assert.equal(metricValue('Infinity').text, 'Unavailable')
  assert.equal(metricValue('1e308', { percentage: true }).text, 'Out of range')
  const table = { columns: [], rows: [], total_rows: '0', truncated: false }
  const rich = { table, displays: [{ id: 'one', table }, { id: 'two', table }], images: [{ id: 'hero', images: [] }, { id: 'other', images: [] }], charts: [{ id: 'loss', points: [[0, 1]], total_points: '1' }, { id: 'other', points: [[0, 2]], total_points: '1' }], progress: [], stopwatches: [], elapsed_ms: null, rich_stale: false, telemetry_stale: false, rich_unsupported: false, timing_running: false }
  const components = [{ id: 'a', kind: 'table', title: 'Table', table_id: 'one' }, { id: 'b', kind: 'image', title: 'Image', image_id: 'hero' }, { id: 'c', kind: 'live_chart', title: 'Chart', chart_id: 'loss' }]
  const automatic = automaticRich(rich, components)
  assert.equal(automatic.table, table)
  assert.deepEqual(automatic.displays.map(value => value.id), ['two'])
  assert.deepEqual(automatic.images.map(value => value.id), ['other'])
  assert.deepEqual(automatic.charts.map(value => value.id), ['other'])
  assert.equal(rich.displays.length, 2, 'automatic projection never mutates the snapshot')
  assert.equal(displayTables({ kind: 'table', table_id: 'missing' }, rich).length, 0)
  assert.equal(displayTables({ kind: 'table' }, rich).length, 2)
  const all = automaticRich({ ...rich, displays: [] }, [{ kind: 'table', id: 'all', title: 'All' }])
  assert.equal(all.table, null, 'implicit table is rendered once through its authored owner')
  assert(displayError({ ...components[2], x_min: 1, x_max: 1 }))
  const preserved = parseDocumentJSON('{"id":"m","kind":"metric","title":"Exact","p1":{"target":9223372036854775807,"future":9223372036854775806},"future":{"nested":true}}')
  assert.equal(displayError(preserved), '')
  preserved.title = 'Renamed'
  assert(documentJSON(preserved).includes('"future":9223372036854775806'))
  assert.equal(documentJSON(parseDocumentJSON('1e20')), '1e+20', 'large whole-valued Float must not become an overflowing Int64 token')
  assert.equal(documentJSON(parseDocumentJSON('9223372036854775807')), '9223372036854775807')
  const series = [{ chart: rich.charts[0], stroke: '#86505f' }, { chart: rich.charts[1], stroke: '#4c739e' }]
  const figure = chartsFigure(series, { title: 'Two series', x_min: 0, x_max: 10, y_min: -1, y_max: 3, x_label: 'Epoch', y_label: 'Score' })
  const scene = parseScene(figure.plot_scene, figure.width, figure.height)
  assert(scene); assert.equal(scene.layers.length, 2); assert.deepEqual(scene.bounds, [0, -1, 10, 3]); assert.equal(scene.x_label, 'Epoch')
  const fixed = chartsFigure(series, { x_min: 100 })
  assert(parseScene(fixed.plot_scene, fixed.width, fixed.height), 'one-sided fixed bounds stay resolvable')
  console.log('PASS exact metrics, formatting, table/channel ownership, multi-series domains and metadata preservation')
} finally { await rm(root, { recursive: true, force: true }) }
