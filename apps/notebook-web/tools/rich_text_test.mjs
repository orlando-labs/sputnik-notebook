import assert from 'node:assert/strict'
import ts from '../frontend/node_modules/typescript/lib/typescript.js'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
const directory = await mkdtemp(path.join(tmpdir(), 'sputnik-rich-text-'))
try {
  await writeFile(path.join(directory, 'rich-text.mjs'), ts.transpileModule(await readFile(new URL('../frontend/src/rich-text.ts', import.meta.url), 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText)
  const { readFormatting, formattingError, inlineFormat, paragraphFormat, listFormat, renumberLists, replaceText, replaceSource, insertTable, tableChange, textBlocks } = await import('file://' + path.join(directory, 'rich-text.mjs'))
  const source = { source: 'A 💫 hello\nSecond\n' }, original = JSON.stringify(source)
  const bold = inlineFormat(source, { start: 2, length: 2 }, 'bold')
  assert.deepEqual(bold.formatting.runs, [{ start: 2, length: 2, style: 'body', bold: true, italic: false, underline: false }])
  assert.equal(JSON.stringify(source), original)
  assert.throws(() => inlineFormat(source, { start: 3, length: 1 }, 'bold'), /Unicode/)
  const inserted = replaceText(bold, { start: 0, length: 0 }, 'Title: ')
  assert.equal(inserted.formatting.runs[0].start, 9)
  const diff = replaceSource(inserted, inserted.source.replace('hello', 'world')); assert.equal(diff.formatting.runs[0].start, 9)
  const heading = paragraphFormat(diff, { start: 0, length: 0 }, 'heading1')
  assert.equal(heading.formatting.version, 2); assert.equal(textBlocks(heading)[0].style, 'heading1')
  let list = listFormat({ source: 'First\nSecond\n' }, { start: 0, length: 13 }, 'bullet')
  assert.equal(list.source, '•\tFirst\n•\tSecond\n'); assert.equal(list.formatting.paragraphs.length, 2)
  list = listFormat(list, { start: 0, length: list.source.length }, 'numbered')
  assert.equal(list.source, '1.\tFirst\n2.\tSecond\n')
  const plain = listFormat(list, { start: 0, length: list.source.length }, 'numbered'); assert.equal(plain.source, 'First\nSecond\n')
  const enter = replaceText(list, { start: 8, length: 0 }, '\n3.\t'); readFormatting(enter)
  const normalized = renumberLists(enter, { start: 12, length: 0 }); assert.equal(normalized.content.source, '1.\tFirst\n2.\t\n3.\tSecond\n')
  assert.throws(() => replaceText(list, { start: 0, length: 3 }, ''), /List/)
  let table = insertTable({ source: 'Title\n' }, { start: 0, length: 0 }).content
  assert.equal(table.formatting.tables[0].cells.length, 4)
  table = replaceText(table, { start: 6, length: 0 }, 'First 💫')
  readFormatting(table); assert.equal(table.formatting.tables[0].cells[0].length, 9)
  assert.throws(() => replaceText(table, { start: 14, length: 1 }, ''), /boundaries/)
  const styled = inlineFormat(table, { start: 6, length: 5 }, 'italic')
  const expanded = tableChange(styled, 6, 'addColumn').content
  assert.equal(expanded.formatting.tables[0].columns, 3); assert.equal(expanded.formatting.tables[0].cells.length, 6)
  assert.equal(expanded.formatting.runs[0].italic, true)
  const row = tableChange(expanded, 6, 'addRow').content; assert.equal(row.formatting.tables[0].cells.length, 9)
  const shrink = tableChange(tableChange(row, 6, 'removeRow').content, 6, 'removeColumn').content
  assert.equal(shrink.formatting.tables[0].columns, 2); assert.equal(shrink.formatting.tables[0].cells.length, 4)
  assert.equal(tableChange(shrink, 6, 'remove').content.source, 'Title\n\n')
  assert.equal(textBlocks(styled).find(item => item.kind === 'table').rows.length, 2)
  const beforeExisting = insertTable(table, { start: 0, length: 0 }).content
  assert.equal(beforeExisting.formatting.tables.length, 2, 'new table can precede an existing table')
  assert.equal(tableChange(beforeExisting, 6, 'addColumn').content.formatting.tables.length, 2, 'adjacent structural ownership is preserved')
  assert.throws(() => replaceText(source, { start: 1.5, length: 1 }, ''), /Unicode/)
  const native = JSON.parse(await readFile(new URL('../../../tools/notebook-macos/Samples/Rich Text.sputnikbook/project.json', import.meta.url), 'utf8')).sheets[0].cells[1]
  assert.equal(formattingError(native), ''); assert.equal(textBlocks(native).filter(item => item.kind === 'table').length, 1)
  assert.equal(formattingError(replaceSource(native, native.source.replace('Greeting', 'Welcome'))), '')
  assert.match(formattingError({ source: 'abc', formatting: { version: 99, runs: [] } }), /version/)
  assert.match(formattingError({ source: 'abc', formatting: { version: 1, runs: [], unknown: true } }), /unsupported/)
  assert.match(formattingError({ source: '\ud800' }), /Unicode/)
  let large = { source: 'x'.repeat(40000), formatting: { version: 1, runs: Array.from({ length: 20000 }, (_, i) => ({ start: i * 2, length: 1, bold: true })) } }
  assert.equal(textBlocks(large)[0].spans.length, 40000, 'linear inline segmentation at the native run limit')
  assert.equal(inlineFormat(large, { start: 0, length: 40000 }, 'bold').formatting.runs.length, 1, 'linear formatting at the native run limit')
  console.log('PASS portable rich text v1/v2, Swift sample, Unicode offsets, span remapping, headings/lists, protected tables and structural edits')
} finally { await rm(directory, { recursive: true, force: true }) }
