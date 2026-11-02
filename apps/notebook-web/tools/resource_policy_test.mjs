import assert from 'node:assert/strict'
import ts from '../frontend/node_modules/typescript/lib/typescript.js'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
const directory = await mkdtemp(path.join(tmpdir(), 'sputnik-resource-ui-'))
try {
  for (const name of ['document-json', 'resource-policy']) {
    const source = (await readFile(new URL(`../frontend/src/${name}.ts`, import.meta.url), 'utf8')).replaceAll("'./document-json'", "'./document-json.mjs'")
    await writeFile(path.join(directory, name + '.mjs'), ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText)
  }
  const { documentJSON, parseDocumentJSON } = await import('file://' + path.join(directory, 'document-json.mjs'))
  const { bookPolicy, integerToken, policyValue, resourceFields, scaledValue, secondsLabel } = await import('file://' + path.join(directory, 'resource-policy.mjs'))
  assert.equal(integerToken(bookPolicy(parseDocumentJSON('{"project_bytes":9007199254740993}')).project_bytes), '9007199254740993')
  assert.equal(documentJSON(bookPolicy(parseDocumentJSON('{"run_count":100,"run_seconds":null}'))), '{"run_count":100,"run_seconds":null}')
  const bytes = resourceFields.find(field => field.key === 'project_bytes')
  assert.equal(scaledValue('1', bytes.scale), '0.00000095367431640625')
  assert.equal(documentJSON(policyValue(scaledValue('1', bytes.scale), bytes)), '1')
  assert.equal(policyValue('1.5', bytes), 1572864)
  assert.throws(() => policyValue('0.0000001', bytes), /whole bytes/)
  assert.throws(() => policyValue('0', bytes), /positive/)
  assert.throws(() => policyValue('10241', bytes), /at most/)
  assert.throws(() => bookPolicy({ run_count: 1.5 }), /positive integers/)
  assert.throws(() => bookPolicy({ persistence: 'durable' }), /unsupported resource fields/)
  assert.equal(secondsLabel('9007199254740993'), '9007199254740.993 s')
  assert.equal(secondsLabel(null), 'Unlimited')
  console.log('PASS web resource policy: exact Int64/units, byte granularity, bounds, inheritance and preserved authored values')
} finally { await rm(directory, { recursive: true, force: true }) }
