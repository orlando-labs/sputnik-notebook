type Token = { start: number; end: number; kind: string }
const inlineRules: [RegExp, string][] = [
  [/`+[^`]+?`+/g, 'string'],
  [/(?<!\\)(?:\$\$[^$]+?\$\$|\$[^$]+?\$|\\\(.+?\\\))/g, 'variable'],
  [/!?\[[^\]]+\]\([^)]+\)/g, 'className'],
  [/(?<!\\)(?:\*\*[^*]+\*\*|__[^_]+__|\*[^*]+\*|(?<!\w)_[^_]+_(?!\w)|~~[^~]+~~)/g, 'keyword'],
]
const block = /^ {0,3}(?:#{1,6}(?:\s|$).*|>+|[-+*](?=\s)|\d{1,9}[.)](?=\s)|[-*_]{3,}\s*$|\|)/
const fence = /^ {0,3}(`{3,}|~{3,})(.*)$/

export function markdownTokens(source: string): Token[] {
  const tokens: Token[] = []
  let openFence = '', displayMath = '', offset = 0
  for (const line of source.split('\n')) {
    const trimmed = line.trim()
    const marker = fence.exec(line)
    const display = trimmed.startsWith('$$') ? '$$' : trimmed.startsWith('\\[') ? '\\]' : ''
    const sections: Token[] = []
    let lineKind = 'plain'
    if (displayMath) {
      lineKind = 'variable'
      if (trimmed.includes(displayMath)) displayMath = ''
    } else if (marker) {
      lineKind = 'comment'
      const mark = marker[1]!
      if (!openFence) openFence = mark
      else if (mark[0] === openFence[0] && mark.length >= openFence.length && !marker[2]?.trim()) openFence = ''
    } else if (openFence) lineKind = 'string'
    else if (display) {
      lineKind = 'variable'
      if (!trimmed.slice(2).includes(display)) displayMath = display
    } else {
      const prefix = block.exec(line)?.[0].length ?? 0
      if (prefix === line.length && prefix) lineKind = 'keyword'
      for (const [rule, kind] of line.length <= 16384 ? inlineRules : []) {
        for (const match of line.matchAll(rule)) {
          const start = match.index, end = start + match[0].length
          if (!sections.some(token => start < token.end && end > token.start)) sections.push({ start, end, kind })
        }
      }
      if (prefix && prefix < line.length && !sections.some(token => token.start < prefix)) sections.push({ start: 0, end: prefix, kind: 'keyword' })
    }
    let start = 0
    function push(from: number, to: number, kind: string) {
      if (to > from) tokens.push({ start: offset + from, end: offset + to, kind })
    }
    for (const part of sections.sort((a, b) => a.start - b.start)) {
      push(start, part.start, lineKind)
      push(part.start, part.end, part.kind)
      start = part.end
    }
    const end = Math.min(source.length - offset, line.length + 1)
    push(start, end, lineKind)
    offset += end
  }
  return tokens
}
