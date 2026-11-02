import assert from 'node:assert/strict'
import ts from '../frontend/node_modules/typescript/lib/typescript.js'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
const root = await mkdtemp(path.join(tmpdir(), 'sputnik-text-features-'))
try {
  for (const name of ['text-variables', 'sputnik-syntax', 'diagnostics', 'markdown']) {
    let code = ts.transpileModule(await readFile(new URL(`../frontend/src/${name}.ts`, import.meta.url), 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText
    for (const local of ['text-variables', 'sputnik-syntax']) code = code.replaceAll(`'./${local}'`, `'./${local}.mjs'`)
    code = code.replaceAll("'markdown-it'", JSON.stringify(new URL('../frontend/node_modules/markdown-it/dist/markdown-it.mjs', import.meta.url).href))
    await writeFile(path.join(root, `${name}.mjs`), code)
  }
  const { textVariables, interpolateInline } = await import(pathToFileURL(path.join(root, 'text-variables.mjs')).href)
  const { sputnikTokens } = await import(pathToFileURL(path.join(root, 'sputnik-syntax.mjs')).href)
  const { diagnosticSelection } = await import(pathToFileURL(path.join(root, 'diagnostics.mjs')).href)
  const { markdownNodes, safeMarkdownLink } = await import(pathToFileURL(path.join(root, 'markdown.mjs')).href)
  const style = { style: 'body', bold: false, italic: false, underline: false }
  const provider = (value, more = {}) => ({ ok: true, stale: false, running: false, text_values: [{ name: 'answer', value, initialized: value !== null, truncated: false }], ...more })
  const sheet = { cells: [{ id: '1', kind: 'code' }, { id: '2', kind: 'text' }, { id: '3', kind: 'code' }, { id: '4', kind: 'text' }] }
  const presentations = { '1': provider('9223372036854775807'), '3': provider('later') }
  assert.equal(textVariables(sheet, presentations, '2')[0].value, '9223372036854775807')
  assert.equal(textVariables(sheet, presentations, '4')[0].value, 'later')
  assert.equal(textVariables(sheet, { ...presentations, '3': provider(null) }, '4')[0].initialized, false, 'an uninitialized later provider shadows the earlier value')
  assert.equal(textVariables(sheet, { ...presentations, '3': provider('later', { ok: false }) }, '4')[0].stale, true)
  assert.deepEqual(textVariables(sheet, presentations, 'missing'), [])
  const values = textVariables(sheet, presentations, '2')
  const split = interpolateInline([{ ...style, bold: true, text: '{{ans' }, { ...style, text: 'wer}}' }], values)
  assert.equal(split[0].text, '9223372036854775807'); assert.equal(split[0].bold, true)
  assert.equal(interpolateInline([{ ...style, text: '{{answer + 1}}' }], values)[0].state, 'unavailable', 'no expression evaluation')
  assert.equal(interpolateInline([{ ...style, text: '{{answer}}' }], [{ ...values[0], value: 'a\r\nb\nc\r', stale: false }])[0].text, 'a\u2028b\u2028c\u2028')
  assert.throws(() => interpolateInline([{ ...style, text: '{{answer}}'.repeat(80) }], [{ ...values[0], value: 'x'.repeat(4096) }]), /exceeds/)
  const snippets = [
    'π = 0x2A + 1.5e+2\nЖар = true\n', '😀 + π = 1', 'value = "unterminated if # true',
    'r"\\d+#{"я"}"mi ~= text', "rx'#{'я'}\\d+'im ~= text", 'worker#run &handler # comment\n',
    'macro def wrap(value):\n  #{value}\nresult = 42 # end\n',
    'html"""\n  %for item in items:\n    #{item}\n  %# omitted\n"""',
  ]
  for (const source of snippets) { const tokens = sputnikTokens(source); assert.equal(tokens.map(token => token.text).join(''), source); assert(tokens.every(token => token.end > token.start)) }
  const kind = (source, text) => sputnikTokens(source).find(token => token.text === text)?.kind
  assert.equal(kind('π = 0x2A', '0x2A'), 'number'); assert.equal(kind('Жар = true', 'Жар'), 'className')
  assert.equal(kind('x = 1 then 2', 'then'), 'keyword'); assert.equal(kind('object.then()', 'then'), 'identifier')
  assert.equal(kind('next 42', 'next'), 'keyword'); assert.equal(kind('next = 42', 'next'), 'identifier')
  assert.equal(kind('worker#run # comment', '# comment'), 'comment'); assert.equal(kind('worker#run', '#'), 'operator')
  assert.equal(kind('native def read() from "read" blocking', 'blocking'), 'keyword')
  assert.equal(kind('html"""\n %for x in values:\n"""', 'for'), 'keyword')
  assert.equal(sputnikTokens('+ '.repeat(30000))[0].limited, true, 'dense source falls back before creating an unbounded token DOM')
  const source = 'π = "😀"\r\nα + missing\n'
  const selection = diagnosticSelection(source, { start_line: 0, start_column: 4, end_line: 0, end_column: 7, whole_line: false })
  assert.equal(source.slice(selection.start, selection.end), '"😀"')
  assert.equal(source.slice(...Object.values(diagnosticSelection(source, { start_line: 1, start_column: 4, end_line: 1, end_column: 11, whole_line: false }))), 'missing')
  assert.equal(diagnosticSelection(source, { start_line: 50, start_column: 0, end_line: 50, end_column: 1, whole_line: false }), null)
  assert.equal(diagnosticSelection(source, { start_line: 0, start_column: -1, end_line: 0, end_column: 2, whole_line: false }), null)
  const literal = [{ ...values[0], value: '**not bold** <img src=x>\nnext', stale: false }]
  const nodes = markdownNodes('# Report\n\n{{answer}}\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n[bad](javascript:alert(1))\n\n![image](https://example.invalid/private.png)\n\n<script>alert(1)</script>', literal)
  const walk = nodes => nodes.flatMap(node => [node, ...walk(node.children || [])]), all = walk(nodes)
  assert(all.some(node => node.tag === 'h1')); assert(all.some(node => node.tag === 'table'))
  assert(!all.some(node => ['script', 'iframe', 'img', 'style'].includes(node.tag)))
  assert(all.some(node => node.text?.includes('**not bold** <img src=x>')), 'substituted values remain literal after Markdown parsing')
  assert(!all.some(node => /^(?:javascript:|data:|file:)/i.test(node.attrs?.href || '')))
  const fence = walk(markdownNodes('```sputnik\n{{answer}}\n```', values)); assert(fence.some(node => node.text === '9223372036854775807'), 'fenced Sputnik interpolates after lexical styling')
  for (const link of ['javascript:alert(1)', 'data:text/html,x', 'file:///etc/passwd', '/api/anything', '//example.com']) assert.equal(safeMarkdownLink(link), null)
  assert.equal(safeMarkdownLink('https://example.com'), 'https://example.com/')
  assert.throws(() => markdownNodes('x'.repeat(262145)), /limited/)
  assert.throws(() => markdownNodes(('```sputnik\n' + '+ '.repeat(1000) + '\n```\n').repeat(20)), /20000/, 'fence styling shares the structural work budget')
  const stressed = '#'.repeat(100000); assert(markdownNodes(stressed).length)
  console.log('PASS text scope/shadowing/staleness, immutable literal interpolation, Unicode diagnostics, Sputnik lexical surface and bounded inert Markdown')
} finally { await rm(root, { recursive: true, force: true }) }
