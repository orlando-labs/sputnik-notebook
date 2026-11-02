// Exact-value editing rules; the authoritative validator remains notebook-core.
import assert from 'node:assert/strict'
import ts from '../frontend/node_modules/typescript/lib/typescript.js'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
const root = await mkdtemp(path.join(tmpdir(), 'sputnik-web-inputs-'))
try {
  for (const name of ['document-json', 'inputs']) {
    const code = ts.transpileModule(await readFile(new URL(`../frontend/src/${name}.ts`, import.meta.url), 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText.replace("'./document-json'", "'./document-json.mjs'")
    await writeFile(path.join(root, `${name}.mjs`), code)
  }
  const { inputJSON, inputError, rangeText, rangeJSON, stepped } = await import('file://' + path.join(root, 'inputs.mjs'))
  const whole = { id: 'exact', title: 'Exact', type: 'integer' }
  assert.equal(inputJSON('9223372036854775807', whole), '9223372036854775807')
  assert.equal(inputJSON('-9223372036854775808', whole), '-9223372036854775808')
  assert.ok(inputError('9223372036854775808', whole))
  assert.equal(stepped('9223372036854775806', 1, whole, { step: 1 }), '9223372036854775807')
  assert.equal(stepped('9223372036854775807', 1, whole, { step: 1 }), null)
  const number = { id: 'n', title: 'Number', type: 'number' }
  assert.equal(inputJSON('1', number), '1')
  assert.equal(inputJSON('1.0', number), '1.0')
  assert.equal(stepped('1.5', 1, number, { step: 0.5 }), '2.0')
  const exact = '{"start":9223372036854775806,"finish":9223372036854775807,"inclusive_end":true,"step":1}'
  assert.equal(rangeJSON(rangeText(exact)), exact)
  const decimal = '{"start":0.0,"finish":10.0,"inclusive_end":false,"step":0.5}'
  assert.equal(rangeJSON(rangeText(decimal)), decimal)
  assert.throws(() => rangeJSON('(0..10:0.5)'))
  assert.equal(inputJSON('(1..10:2)', { id: 'r', title: 'Range', type: 'range' }, { style: 'slider', minimum: 0, maximum: 20 }), '{"start":1,"finish":10,"inclusive_end":true,"step":2}')
  assert.ok(inputError('(10..1:2)', { id: 'r', title: 'Range', type: 'range' }, { style: 'slider', minimum: 0, maximum: 20 }))
  assert.equal(inputJSON('line\n"quoted"', { id: 's', title: 'Text', type: 'string' }), '"line\\n\\"quoted\\""')
  assert.ok(inputError('wrong', whole, { style: 'select', options: [{ label: 'One', value_json: '1' }] }))
  console.log('PASS exact input JSON, Int64 stepping, typed ranges, choice and string validation')
} finally { await rm(root, { recursive: true, force: true }) }
