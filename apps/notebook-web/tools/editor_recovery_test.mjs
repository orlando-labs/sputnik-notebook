import assert from 'node:assert/strict'
import ts from '../frontend/node_modules/typescript/lib/typescript.js'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { webcrypto } from 'node:crypto'
globalThis.crypto ||= webcrypto
const root = await mkdtemp(path.join(tmpdir(), 'sputnik-editor-recovery-'))
try {
  for (const name of ['document-json', 'notebook', 'editor-operations', 'draft-merge', 'draft-journal']) {
    let code = ts.transpileModule(await readFile(new URL(`../frontend/src/${name}.ts`, import.meta.url), 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText
    code = code.replace(/from '(\.\/[^']+)'/g, (_, name) => `from '${name}.mjs'`)
    await writeFile(path.join(root, `${name}.mjs`), code)
  }
  const { parseDocumentJSON: parse, documentJSON: json } = await import('file://' + path.join(root, 'document-json.mjs'))
  const { duplicateSheet, moveSheet, deleteSheet } = await import('file://' + path.join(root, 'editor-operations.mjs'))
  const { mergeDocument, mergeFiles } = await import('file://' + path.join(root, 'draft-merge.mjs'))
  const { validDraft } = await import('file://' + path.join(root, 'draft-journal.mjs'))
  const source = '{"format":"sputnik-notebook","version":4,"title":"Test","active_sheet":"main","sheets":[{"id":"main","title":"Main","future":9223372036854775807,"cells":[{"id":"18446744073709551614","kind":"code","source":"π = 1","cell_ui":{"inputs":[],"pre":[{"id":"start","kind":"execution_controls","p1":{"target_component":"action"}}],"post":[{"id":"action","kind":"action","future":9223372036854775807}]}}]}],"boards":[{"id":"b","sheet":"main","components":[]}],"future":{"unchanged":9223372036854775807}}'
  const doc = parse(source), copy = duplicateSheet(doc, 'main')
  assert.equal(doc.sheets.length, 2); assert.notEqual(doc.sheets[1].cells[0].id, doc.sheets[0].cells[0].id)
  assert.equal(doc.sheets[1].cells[0].cell_ui.pre[0].p1.target_component, doc.sheets[1].cells[0].cell_ui.post[0].id)
  assert(json(doc.sheets[1]).includes('9223372036854775807'))
  moveSheet(doc, copy, -1); assert.equal(doc.sheets[0].id, copy)
  deleteSheet(doc, 'main', copy); assert.equal(doc.boards[0].sheet, copy); assert.equal(doc.active_sheet, copy)
  assert.throws(() => deleteSheet(doc, copy, 'main'), /at least one/)
  const local = parse(source), remote = parse(source)
  local.sheets[0].cells[0].source = 'π = 2'; remote.sheets[0].title = 'Remote title'; remote.future.added = true
  let merged = mergeDocument(source, json(local), json(remote))
  assert.equal(merged.conflicts.length, 0); assert.equal(parse(merged.document).sheets[0].title, 'Remote title'); assert.equal(parse(merged.document).sheets[0].cells[0].source, 'π = 2'); assert(merged.document.includes('9223372036854775807'))
  remote.sheets[0].cells[0].source = 'π = 3'
  merged = mergeDocument(source, json(local), json(remote)); assert.equal(merged.conflicts.length, 1)
  assert.equal(parse(mergeDocument(source, json(local), json(remote), { [merged.conflicts[0].id]: 'remote' }).document).sheets[0].cells[0].source, 'π = 3')
  local.sheets[0].cells = []; merged = mergeDocument(source, json(local), json(remote)); assert.equal(merged.conflicts.length, 1); assert.equal(merged.conflicts[0].local, '(removed)')
  const orderBase = json({ items: ['a','b','c'].map(id => ({ id, value: 0 })) }), orderLocal = json({ items: ['b','a','c','l'].map(id => ({ id, value: 0 })) }), orderRemote = json({ items: ['c','b','a','r'].map(id => ({ id, value: 0 })) })
  merged = mergeDocument(orderBase, orderLocal, orderRemote); assert.equal(merged.conflicts.length, 1); assert(merged.conflicts[0].id.endsWith('$order'))
  assert.deepEqual(parse(mergeDocument(orderBase, orderLocal, orderRemote, { [merged.conflicts[0].id]: 'remote' }).document).items.map(item => item.id), ['c','b','a','r','l'])
  const styled = mergeDocument('{"source":"abc","formatting":{"runs":[]}}', '{"source":"x","formatting":{"runs":[]}}', '{"source":"abc","formatting":{"runs":[{"start":1}]}}'); assert.equal(styled.conflicts.length, 1); assert(styled.conflicts[0].id.endsWith('$text')); assert.equal(parse(styled.document).source, 'x'); assert.deepEqual(parse(styled.document).formatting.runs, []);
  const prototype = mergeDocument('{"x":{}}', '{"x":{"__proto__":{"a":1}}}', '{"x":{"constructor":2}}'); assert.equal(prototype.conflicts.length, 0); assert.equal(parse(prototype.document).x.__proto__.a, 1); assert.equal({}.a, undefined)
  const files = [{ path: 'data.bin', digest: 'before' }, { path: 'removed', digest: 'before' }], changes = { 'data.bin': { encoding: 'base64', data: 'AP8=' }, removed: null, added: { encoding: 'utf8', data: 'new' } }
  const fm = mergeFiles(files, [{ path: 'data.bin', digest: 'after' }], changes); assert.equal(fm.conflicts.length, 1); assert(!Object.hasOwn(fm.changes, 'removed')); assert.equal(json(mergeFiles(files, [{ path: 'data.bin', digest: 'after' }], changes, { 'file/data.bin': 'remote' }).changes), json({ added: changes.added }))
  const record = { id: 'draft', account: 'a', project: 'p', updated: Date.now(), base_revision: 'a'.repeat(64), base_document: source, document: json(remote), changes: {}, pending: null, sheet: 'main', file: '', board: '' }
  assert(validDraft(record, 'a', 'p')); assert(validDraft({ ...record, changes: { 'large.bin': { encoding: 'base64', data: Buffer.alloc(16777216).toString('base64') } } }, 'a', 'p')); assert(!validDraft({ ...record, changes: { '../escape': null } }, 'a', 'p')); assert(!validDraft(record, 'b', 'p')); assert(!validDraft(record, 'a', 'other')); assert(!validDraft({ ...record, updated: 1 }, 'a', 'p')); assert(!validDraft({ ...record, document: '{}' }, 'a', 'p')); assert(!validDraft({ ...record, pending: { command_id: 'unsafe!', base_revision: record.base_revision } }, 'a', 'p'))
  console.log('PASS sheet identity/reference preservation, lossless three-way merge, delete/order/file conflicts, prototype safety, journal scope/validation')
} finally { await rm(root, { recursive: true, force: true }) }
