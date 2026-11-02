import type { NotebookSheet } from './notebook'
import type { CellPresentation } from './execution'
import type { InlineText } from './rich-text'
export interface PublishedText { name: string; value: string | null; initialized: boolean; truncated: boolean }
export interface TextVariable extends PublishedText { cellID: string; cellNumber: number; stale: boolean }
export interface InterpolatedText extends InlineText { variable?: string; state?: 'stale' | 'unavailable' }
export function textResolver(sheet: NotebookSheet | undefined, presentations: Record<string, CellPresentation>): (before?: string) => TextVariable[] {
  if (!sheet) return () => []
  const positions = new Map(sheet.cells.map((cell, index) => [cell.id, index])), stale = [false]
  const providers = new Map<string, { index: number; value: TextVariable }[]>()
  for (let index = 0; index < sheet.cells.length; index++) {
    const cell = sheet.cells[index]!
    stale[index + 1] = stale[index]!
    if (cell.kind !== 'code') continue
    const result = presentations[cell.id]
    stale[index + 1] ||= !result?.ok || !!result.stale || !!result.running
    for (const value of result?.text_values || []) { const list = providers.get(value.name) || []; list.push({ index, value: { ...value, cellID: cell.id, cellNumber: index + 1, stale: stale[index + 1]! || !value.initialized } }); providers.set(value.name, list) }
  }
  const names = [...providers.keys()].sort((a, b) => a.localeCompare(b))
  return before => {
    const end = before === undefined ? sheet.cells.length : positions.get(before)
    if (end === undefined) return []
    return names.flatMap(name => {
      const list = providers.get(name)!; let low = 0, high = list.length
      while (low < high) { const mid = (low + high) >>> 1; if (list[mid]!.index < end) low = mid + 1; else high = mid }
      const provider = list[low - 1]
      return provider ? [{ ...provider.value, stale: stale[end]! || provider.value.stale }] : []
    })
  }
}
export function textVariables(sheet: NotebookSheet | undefined, presentations: Record<string, CellPresentation>, before?: string): TextVariable[] {
  return textResolver(sheet, presentations)(before)
}
export function variableDisplay(name: string, value?: TextVariable): { text: string; state?: 'stale' | 'unavailable' } {
  if (!value?.initialized || value.value === null) return { text: `[${name}: unavailable]`, state: 'unavailable' }
  const text = value.value.replace(/\r\n|[\r\n]/g, '\u2028') + (value.truncated ? '…' : '')
  return value.stale ? { text: `[${name}: stale — ${text}]`, state: 'stale' } : { text }
}
// Interpolate after structure/style parsing. A value is always a literal text
// node; a placeholder crossing inline styles inherits its opening character.
export function interpolateInline(spans: InlineText[], variables: TextVariable[], budget = { remaining: 262144, tokens: 4096 }): InterpolatedText[] {
  const source = spans.map(span => span.text).join(''), values = new Map(variables.map(value => [value.name, value])), result: InterpolatedText[] = []
  let spanIndex = 0, spanStart = 0, cursor = 0
  function seek(at: number) { while (spans[spanIndex] && spanStart + spans[spanIndex]!.text.length <= at) { spanStart += spans[spanIndex]!.text.length; spanIndex++ } }
  function append(value: InterpolatedText) { budget.remaining -= value.text.length; if (budget.remaining < 0) throw new Error('Interpolated preview exceeds 256 Ki UTF-16 units. Reduce text or displayed values.'); if (value.text) result.push(value) }
  function literal(end: number) {
    while (cursor < end) { seek(cursor); const span = spans[spanIndex]; if (!span) break; const finish = Math.min(end, spanStart + span.text.length); append({ ...span, text: source.slice(cursor, finish) }); cursor = finish }
  }
  for (const match of source.matchAll(/\{\{([^{}\r\n]+)\}\}/g)) {
    if (--budget.tokens < 0) throw new Error('Text preview permits at most 4096 variable placeholders.')
    const start = match.index!, name = match[1]!.trim(); literal(start); seek(start)
    const style = spans[spanIndex] || { style: 'body', bold: false, italic: false, underline: false }
    append({ ...style, ...variableDisplay(name, values.get(name)), variable: name }); cursor = start + match[0].length
  }
  literal(source.length)
  return result
}
