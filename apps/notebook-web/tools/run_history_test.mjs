import assert from 'node:assert/strict'
import ts from '../frontend/node_modules/typescript/lib/typescript.js'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
const directory = await mkdtemp(path.join(tmpdir(), 'sputnik-history-'))
try {
  for (const name of ['run-history', 'inputs', 'parameter-presets', 'date-input', 'document-json']) {
    const source = await readFile(new URL(`../frontend/src/${name}.ts`, import.meta.url), 'utf8')
    await writeFile(path.join(directory, name + '.mjs'), ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText.replace(/from '(\.\/[^']+)'/g, "from '$1.mjs'"))
  }
  const { exactDelta, compareRuns, comparisonCSV, restoreValues, restoreError } = await import('file://' + path.join(directory, 'run-history.mjs'))
  assert.equal(exactDelta('9223372036854775806', '9223372036854775807'), '+1')
  assert.equal(exactDelta('0.1', '0.3'), '+0.2')
  assert.equal(exactDelta('1e2', '1.25'), '-98.75')
  assert.equal(exactDelta('1.00', '1'), '0')
  assert.equal(exactDelta('-1e-308', '0'), '+' + '0.' + '0'.repeat(307) + '1')
  assert.equal(exactDelta('1e999999', '1'), 'changed')
  assert.equal(exactDelta('"12"', '"14"'), 'changed')
  assert.equal(exactDelta(null, '1'), '—')
  const snapshot = { inputs: { exact: '9223372036854775806', file: '"old/path"' }, asset_inputs: ['file'], cell_inputs: [{ cell_id: 'c', sheet_id: 'main', values: { flag: 'false' } }], run: { sheet_id: 'main' }, result: { cells: [{ id: 'c', metrics: [{ name: 'loss', value: '0.3' }], elapsed_ms: '100' }] } }
  const other = { ...snapshot, inputs: { exact: '9223372036854775807' }, result: { cells: [{ id: 'c', metrics: [{ name: 'loss', value: '0.1' }], elapsed_ms: '110' }] } }
  const rows = compareRuns(snapshot, other)
  assert.equal(rows.find(row => row.name === 'Input · exact').delta, '+1')
  assert.equal(rows.find(row => row.name.endsWith('metric · loss')).delta, '-0.2')
  assert.ok(comparisonCSV([{ name: '=cmd', baseline: '"a,b"', candidate: null, delta: '+1' }]).includes('"\'=cmd"'))
  const document = { inputs: [{ id: 'exact', title: 'Exact', type: 'integer' }, { id: 'file', type: 'string' }], sheets: [{ id: 'main', cells: [{ id: 'c', kind: 'code', cell_ui: { inputs: [{ id: 'flag', title: 'Flag', type: 'boolean' }] } }] }], boards: [] }
  assert.deepEqual(restoreValues(snapshot, document, 'project'), { exact: '9223372036854775806' })
  assert.equal(restoreError(snapshot, document, 'project'), '')
  assert.equal(restoreError(snapshot, document, 'c'), '')
  assert.ok(restoreError(snapshot, document, 'removed'))
  assert.ok(restoreError(snapshot, { ...document, inputs: [] }, 'project'))
  const authored = { ...document, boards: [{ components: [{ kind: 'group', panels: [{ components: [{ kind: 'file_input', input: 'exact' }] }] }] }] }
  assert.deepEqual(restoreValues(snapshot, authored, 'project'), {})
  assert.ok(restoreError(snapshot, authored, 'project'))
  console.log('PASS run history: exact Int64/decimal/exponent deltas, missing values, CSV formula escaping, scoped scalar validation and asset exclusion')
} finally { await rm(directory, { recursive: true, force: true }) }
