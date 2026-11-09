import MarkdownIt, { type Token } from 'markdown-it'
import { interpolateInline, type TextVariable } from './text-variables'
import { sputnikTokens } from './sputnik-syntax'
export interface MarkdownNode {
  tag?: string; text?: string; attrs?: Record<string, string>; children?: MarkdownNode[]
  formula?: { source: string; display: boolean; block: boolean; number?: string }
}
export const createMarkdownParser = () => new MarkdownIt({ html: false, linkify: false, typographer: false, maxNesting: 16 })
const parser = createMarkdownParser()
const allowed = new Set('p h1 h2 h3 h4 h5 h6 blockquote ul ol li em strong s a table thead tbody tr th td'.split(' '))
export function safeMarkdownLink(value: string): string | null {
  // Explicit http(s), mail and fragment links only. No automatic image requests,
  // local paths, relative API mutations, arbitrary schemes or DOM identifiers.
  if (/^#[a-zA-Z][\w-]*$/.test(value)) return value
  try { const url = new URL(value); return ['http:', 'https:', 'mailto:'].includes(url.protocol) && !/[\u0000-\u001f\u007f]/.test(value) ? url.href : null } catch { return null }
}
export function markdownNodes(source: string, variables: TextVariable[] = [], documentParser?: ReturnType<typeof createMarkdownParser>): MarkdownNode[] {
  if (source.length > 262144 || source.split(/\r\n|[\r\n]/).length > 4000) throw new Error('Markdown preview is limited to 256 Ki UTF-16 units and 4000 lines. Complete source is saved intact.')
  const budget = { remaining: 262144, tokens: 4096 }; let count = 0
  const text = (value: string): MarkdownNode[] => [{ text: value }]
  function nodes(tokens: Token[], depth = 0): MarkdownNode[] {
    if (depth > 32) throw new Error('Markdown preview nesting exceeds its limit.')
    const root: MarkdownNode[] = [], stack = [root]
    for (const token of tokens) {
      if (++count > 20000) throw new Error('Markdown preview permits at most 20000 structural tokens.')
      const target = stack.at(-1)!
      if (token.nesting === -1) { if (stack.length > 1) stack.pop(); continue }
      if (token.type === 'inline') { target.push(...nodes(token.children || [], depth + 1)); continue }
      if (token.type.startsWith('math_')) {
        target.push({ formula: { source: token.content, display: token.block || token.type === 'math_inline_double', block: token.block,
          number: token.type === 'math_block_eqno' ? token.info : undefined } })
        continue
      }
      if (token.type === 'text' || token.type === 'code_inline') { const children = text(token.content); if (token.type === 'code_inline') target.push({ tag: 'code', children }); else target.push(...children); continue }
      if (token.type === 'softbreak' || token.type === 'hardbreak') { target.push(token.type === 'hardbreak' ? { tag: 'br' } : { text: '\n' }); continue }
      if (token.type === 'hr') { target.push({ tag: 'hr' }); continue }
      if (token.type === 'image') { target.push(...text('[Image: ' + token.content + ']')); continue }
      if (token.type === 'fence' || token.type === 'code_block') {
        const language = token.info.trim().split(/\s+/)[0]?.toLowerCase()
        const syntax = language === 'sputnik' || language === 's' ? sputnikTokens(token.content) : null
        count += syntax?.length || 0
        if (count > 20000) throw new Error('Markdown preview permits at most 20000 structure and highlighting tokens.')
        const children = syntax ? syntax.flatMap(item => text(item.text).map(node => ({ tag: 'span', attrs: { class: 'syntax-' + item.kind }, children: [node] }))) : text(token.content)
        target.push({ tag: 'pre', children: [{ tag: 'code', children }] }); continue
      }
      if (token.nesting === 1) {
        const tag = allowed.has(token.tag) ? token.tag : 'span', attrs: Record<string, string> = {}
        if (tag === 'a') { const href = safeMarkdownLink(String(token.attrGet('href') || '')); if (href) Object.assign(attrs, { href, target: '_blank', rel: 'noopener noreferrer' }); else attrs['aria-disabled'] = 'true' }
        if (tag === 'ol') { const start = String(token.attrGet('start') || ''); if (start && /^\d{1,9}$/.test(start)) attrs.start = start }
        if (tag === 'th' || tag === 'td') { const style = String(token.attrGet('style') || ''); if (['text-align:left', 'text-align:right', 'text-align:center'].includes(style)) attrs.class = 'markdown-align-' + style.slice(11) }
        const node: MarkdownNode = { tag, attrs, children: [] }; target.push(node); stack.push(node.children!); continue
      }
      if (token.content) target.push(...text(token.content))
    }
    return root
  }
  const root = nodes((documentParser ?? parser).parse(source, {}))
  function interpolate(node: MarkdownNode) {
    if (['p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'th', 'td', 'pre'].includes(node.tag || '')) {
      const leaves: MarkdownNode[] = []
      function collect(value: MarkdownNode) { if (value.text !== undefined) leaves.push(value); for (const child of value.children || []) collect(child) }
      collect(node)
      const spans = leaves.map((leaf, index) => ({ text: leaf.text!, style: 'body' as const, bold: false, italic: false, underline: false, leaf: index }))
      const rendered = interpolateInline(spans, variables, budget) as (ReturnType<typeof interpolateInline>[number] & { leaf: number })[]
      const grouped = new Map<number, MarkdownNode[]>()
      for (const span of rendered) { const list = grouped.get(span.leaf) || []; list.push({ tag: span.variable ? 'span' : undefined, text: span.text, attrs: span.variable ? { class: span.state ? 'text-variable text-variable-' + span.state : 'text-variable', title: span.variable } : undefined }); grouped.set(span.leaf, list) }
      leaves.forEach((leaf, index) => { delete leaf.text; leaf.tag ||= 'span'; leaf.children = grouped.get(index) || [] })
    } else for (const child of node.children || []) interpolate(child)
  }
  if (!documentParser) root.forEach(interpolate)
  return root
}
