import assert from 'node:assert/strict'
import ts from '../frontend/node_modules/typescript/lib/typescript.js'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
const root = await mkdtemp(path.join(tmpdir(), 'sputnik-web-boards-'))
try {
  for (const name of ['document-json', 'boards']) {
    const code = ts.transpileModule(await readFile(new URL(`../frontend/src/${name}.ts`, import.meta.url), 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText.replaceAll("'./document-json'", "'./document-json.mjs'")
    await writeFile(path.join(root, `${name}.mjs`), code)
  }
  const { boardLayout, boardPresentation, emptyPresentation, referenceID } = await import('file://' + path.join(root, 'boards.mjs'))
  const { parseDocumentJSON } = await import('file://' + path.join(root, 'document-json.mjs'))
  const legacy = { columns: 5, components: Array.from({ length: 6 }, (_, i) => ({ id: `m${i}`, kind: 'metric', title: `Metric ${i}` })) }
  legacy.components.splice(2, 0, { id: 'service', kind: 'periodic_work', title: 'Service' })
  const original = JSON.stringify(legacy), layout = boardLayout(legacy)
  assert.equal(layout.rows.length, 2)
  assert.deepEqual(layout.components.slice(0, 5).map(item => item.span), [2, 2, 3, 2, 3])
  assert(layout.components.every(item => item.kind !== 'periodic_work'))
  assert.equal(JSON.stringify(legacy), original, 'viewing a legacy board never upgrades the saved document')
  const modern = { columns: 1, rows: [{ id: 'row', height: 240 }], components: [{ id: 'metric', kind: 'metric', row: 'row', span: 6 }] }
  assert.equal(boardLayout(modern).components, modern.components)
  assert.equal(referenceID(parseDocumentJSON('18446744073709551614')), '18446744073709551614')
  const first = emptyPresentation('run'), second = emptyPresentation('run')
  first.rich.charts = [{ id: 'loss', points: [[0, 1]], total_points: '1' }]; second.rich.charts = [{ id: 'loss', points: [[0, 2]], total_points: '1' }]
  first.rich.images = [{ id: 'hero', images: [], caption: 'first' }]; second.rich.images = [{ id: 'hero', images: [], caption: 'second' }]
  second.rich.telemetry_stale = true; second.rich.rich_stale = true
  first.rich.stopwatches = [{ id: 'clock', elapsed_ms: '9223372036854775807', done: false }]; first.active = true
  second.rich.stopwatches = [{ id: 'clock', elapsed_ms: '99', done: true }]
  const context = { sheet: { id: 'main', cells: [{ id: '1', kind: 'code' }, { id: '2', kind: 'code' }] }, presentations: { '1': first, '2': second }, identity: 'run' }
  const chart = boardPresentation({ id: 'chart', kind: 'live_chart', chart_id: 'loss' }, context)
  assert.equal(chart.rich.charts[0].points[0][1], 2, 'sheet channels follow reverse authored cell order')
  assert(chart.rich.telemetry_stale)
  assert.equal(boardPresentation({ id: 'image', kind: 'image', image_id: 'hero' }, context).rich.images[0].caption, 'second')
  assert.equal(boardPresentation({ id: 'clock', kind: 'stopwatch', stopwatch_id: 'clock' }, context).rich.stopwatches[0].elapsed_ms, '9223372036854775807')
  assert.equal(boardPresentation({ id: 'metric', kind: 'metric', cell: '1' }, context), first)
  assert.equal(boardPresentation({ id: 'metric', kind: 'metric', cell: 'missing' }, context).ok, false)
  assert.equal(boardPresentation({ id: 'chart', kind: 'live_chart', chart_id: 'loss' }, { ...context, sheet: { id: 'other', cells: [] } }).rich.charts.length, 0, 'channels never cross controller sheets')
  console.log('PASS inert legacy/modern board layout, exact source IDs, controller/channel resolution and stale provenance')
} finally { await rm(root, { recursive: true, force: true }) }
