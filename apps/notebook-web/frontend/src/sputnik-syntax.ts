// Lossless lexical styling, following the native Notebook's SputnikSyntax.
// Incomplete source remains editable; compiler diagnostics come from the worker.
export type SyntaxKind = 'keyword' | 'constant' | 'className' | 'number' | 'string' | 'comment' | 'variable' | 'identifier' | 'operator' | 'punctuation' | 'plain'
export interface SyntaxToken { start: number; end: number; kind: SyntaxKind; text: string; limited?: boolean }
const keywords = new Set('and attr break catch case class class_method class_prop def do elif else elsif export ensure extend for from if import in include loop mixin not or package prop raise rescue return throw try unless until when while as get set var native macro string_tag pattern with numeric quote owned borrowed collected'.split(' '))
const constants = new Set(['true', 'false', 'null', 'self'])
const identifierStart = (char: string) => /[a-zA-Z_\u0400-\u052f\u1c80-\u1c8f\u2de0-\u2dff\ua640-\ua69f\u0370-\u03ff\u1f00-\u1fff]/.test(char)
const identifierPart = (char: string) => identifierStart(char) || /[0-9]/.test(char)
const operators = ['.?.', '...', '<=>', '===', '**', '//', '~=', '==', '!=', '<<', '>>', '<=', '>=', '->', '..']
export function sputnikTokens(source: string, depth = 0): SyntaxToken[] {
  const fallback = (): SyntaxToken[] => [{ start: 0, end: source.length, kind: 'plain', text: source, limited: true }]
  if (source.length > 262144 || depth > 8) return fallback()
  const tokens: SyntaxToken[] = []; let at = 0, expectingClass = false, bracketDepth = 0, macro = 0, macroIndent = 0, lineIndent = 0, lineStart = true, macroTokens = 0
  const char = (index = at) => source[index] || ''
  function emit(start: number, end: number, kind: SyntaxKind) { if (end > start) tokens.push({ start, end, kind, text: source.slice(start, end) }) }
  function nestedString(quote: string) { at++; while (at < source.length) { if (char() === '\\') at = Math.min(source.length, at + 2); else if (char() === quote) { at++; return } else at += source.codePointAt(at)! > 65535 ? 2 : 1 } }
  function string(start: number, raw = false) {
    const quote = char(), triple = source.startsWith('"""', at), tagged = identifierPart(char(at - 1)), controls = tagged && triple && !raw
    let segment = start; at += triple ? 3 : 1
    while (at < source.length) {
      if (triple && source.startsWith('"""', at)) { at += 3; break }
      if (!triple && char() === quote) { at++; break }
      if (controls && char() === '%' && /^(?:%for[ \t]|%#)/.test(source.slice(at, at + 5)) && /^\s*$/.test(source.slice(Math.max(source.lastIndexOf('\n', at - 1), source.lastIndexOf('\r', at - 1)) + 1, at))) {
        emit(segment, at, 'string'); const begin = at, newline = source.slice(at).search(/[\r\n]/); at = newline < 0 ? source.length : at + newline
        if (source[begin + 1] === '#') emit(begin, at, 'comment')
        else { emit(begin, begin + 1, 'punctuation'); for (const token of sputnikTokens(source.slice(begin + 1, at), depth + 1)) tokens.push({ ...token, start: token.start + begin + 1, end: token.end + begin + 1 }) }
        segment = at; continue
      }
      if (char() === '\\') { at = Math.min(source.length, at + 2); continue }
      if ((quote === '"' || tagged) && source.startsWith('#{', at)) {
        at += 2; let nesting = 0
        while (at < source.length) {
          if (char() === '\\') { at = Math.min(source.length, at + 2); continue }
          if (['"', "'"].includes(char())) { nestedString(char()); continue }
          if (char() === '{') nesting++
          if (char() === '}' && nesting-- === 0) { at++; break }
          at += source.codePointAt(at)! > 65535 ? 2 : 1
        }
        continue
      }
      if (!triple && /[\r\n]/.test(char())) break
      at += source.codePointAt(at)! > 65535 ? 2 : 1
    }
    if (tagged && identifierStart(char())) while (at < source.length && identifierPart(char())) at++
    emit(segment, at, 'string'); if (macro === 3) macroTokens++
  }
  while (at < source.length) {
    if (tokens.length > 20000) return fallback()
    if (lineStart) {
      let next = at; while (/[ \t]/.test(char(next)) && next < source.length) next++
      lineIndent = next - at; const blank = !char(next) || /[\r\n]/.test(char(next)) || (char(next) === '#' && char(next + 1) !== '{')
      if (macro === 4 && !blank && lineIndent <= macroIndent) macro = 0
      else if (macro === 3 && !blank && lineIndent > macroIndent) macro = 4
      lineStart = false
    }
    if (/[ \t]/.test(char())) { at++; continue }
    if (/[\r\n]/.test(char())) { if (macro === 2 || (macro === 3 && macroTokens > 0)) macro = 0; at += source.startsWith('\r\n', at) ? 2 : 1; lineStart = true; continue }
    const start = at
    if (source.startsWith('#{', at) && [3, 4].includes(macro)) { at += 2; bracketDepth++; emit(start, at, 'punctuation'); continue }
    if (char() === '#' && (at === 0 || /[ \t\r\n]/.test(char(at - 1)))) { while (at < source.length && !/[\r\n]/.test(char())) at++; emit(start, at, 'comment'); continue }
    if (identifierStart(char())) {
      while (at < source.length && identifierPart(char())) at++
      const word = source.slice(start, at), previous = tokens.at(-1), gap = source.slice(previous?.end || 0, start)
      if (word === 'r' && ['"', "'"].includes(char())) { string(start, true); continue }
      let kind: SyntaxKind = expectingClass ? 'className' : constants.has(word) ? 'constant' : keywords.has(word) ? 'keyword' : /^[\p{Lu}]/u.test(word) ? 'className' : /^_\d+$/.test(word) ? 'variable' : 'identifier'
      if (word === 'then') kind = previous && !/[\r\n]/.test(gap) && !['.', '#', '&', 'def'].includes(previous.text) && !['?', '!'].includes(char()) && (['identifier', 'variable', 'number', 'string', 'constant', 'className'].includes(previous.kind) || [')', ']', '}', '?', '!'].includes(previous.text)) ? 'keyword' : 'identifier'
      if (word === 'next') {
        let following = at; while (following < source.length && /[ \t]/.test(char(following))) following++
        const next = char(following), beforeColon = tokens.at(-2)?.text || ''
        const boundary = !previous || /[\r\n]/.test(gap) || (previous.text === 'then' && previous.kind === 'keyword') || (previous.text === ':' && bracketDepth === 0 && !['', '=', 'return', 'throw', '(', '[', '{'].includes(beforeColon))
        const valueFollows = !next || (next === ':' ? following > at : /[\r\n#,)\]}"'@$0-9]/.test(next) || identifierStart(next))
        kind = boundary && !['?', '!'].includes(char()) && valueFollows ? 'keyword' : 'identifier'
      }
      if (word === 'blocking' && previous?.kind === 'string' && tokens.at(-2)?.text === 'from' && !/[\r\n]/.test(gap)) kind = 'keyword'
      emit(start, at, kind); expectingClass = word === 'class' || word === 'mixin'
      if (word === 'macro') { macro = 1; macroIndent = lineIndent } else if (macro === 1) macro = word === 'def' ? 2 : 0; else if (macro === 3) macroTokens++
      continue
    }
    if (/[0-9]/.test(char())) { const match = /^(?:0[xXbBoO][0-9a-fA-F_]+|[0-9][0-9_]*(?:\.(?!\.)[0-9_]+)?(?:[eE][+-]?[0-9_]*)?)/.exec(source.slice(at))!; at += match[0].length; emit(start, at, 'number'); if (macro === 3) macroTokens++; continue }
    if (['"', "'"].includes(char())) { string(start); continue }
    if (char() === '@' && (identifierStart(char(at + 1)) || (char(at + 1) === '@' && identifierStart(char(at + 2))))) { at++; if (char() === '@') at++; while (at < source.length && identifierPart(char())) at++; if (['?', '!'].includes(char())) at++; emit(start, at, 'variable'); continue }
    if (char() === '$' && (char(at + 1) === '_' || source.startsWith('$it', at))) { at += char(at + 1) === '_' ? 2 : 3; while (/[0-9]/.test(char()) && at < source.length) at++; emit(start, at, 'variable'); continue }
    const operator = operators.find(value => source.startsWith(value, at)), kind = /[()[\]{},:;]/.test(char()) ? 'punctuation' : /[.+\-*/%=!<>&|^?#]/.test(char()) ? 'operator' : 'punctuation'
    at += operator?.length || (source.codePointAt(at)! > 65535 ? 2 : 1); emit(start, at, operator ? 'operator' : kind)
    if ('([{'.includes(source[start]!)) bracketDepth++; if (')]}'.includes(source[start]!)) bracketDepth = Math.max(0, bracketDepth - 1)
    if (source[start] === ':' && macro === 2 && bracketDepth === 0) { macro = 3; macroTokens = 0 } else if (macro === 3) macroTokens++
  }
  // Preserve whitespace and malformed fragments verbatim in the overlay.
  if (tokens.length > 20000) return fallback()
  const result: SyntaxToken[] = []; let cursor = 0
  for (const token of tokens) { if (token.start > cursor) result.push({ start: cursor, end: token.start, text: source.slice(cursor, token.start), kind: 'plain' }); result.push(token); cursor = token.end }
  if (cursor < source.length) result.push({ start: cursor, end: source.length, text: source.slice(cursor), kind: 'plain' })
  return result.length > 20000 ? fallback() : result
}
