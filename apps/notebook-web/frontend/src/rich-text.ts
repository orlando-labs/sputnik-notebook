export type TextStyle = 'body' | 'heading1' | 'heading2' | 'heading3' | 'code'
export interface TextRange { start: number; length: number }
export interface TextRun extends TextRange { style?: TextStyle; bold?: boolean; italic?: boolean; underline?: boolean }
export interface TextParagraph extends TextRange { style?: Exclude<TextStyle, 'code'>; list?: 'bullet' | 'numbered' }
export interface TextTable extends TextRange { columns: number; cells: TextRange[] }
export interface TextFormatting { version: 1 | 2; runs: TextRun[]; paragraphs?: TextParagraph[]; tables?: TextTable[] }
export interface TextContent { source: string; formatting?: unknown }
export const textStyles: TextStyle[] = ['body', 'heading1', 'heading2', 'heading3', 'code']
const end = (range: TextRange) => range.start + range.length
const overlap = (a: TextRange, b: TextRange) => a.start < end(b) && b.start < end(a)
function firstOverlap<T extends TextRange>(ranges: T[], range: TextRange): T | undefined {
  let low = 0, high = ranges.length
  while (low < high) { const mid = (low + high) >>> 1; if (end(ranges[mid]!) <= range.start) low = mid + 1; else high = mid }
  return ranges[low] && overlap(ranges[low]!, range) ? ranges[low] : undefined
}
export const scalarBoundary = (text: string, index: number) => Number.isSafeInteger(index) && index >= 0 && index <= text.length && !(index > 0 && index < text.length && /[\uD800-\uDBFF]/.test(text[index - 1]!) && /[\uDC00-\uDFFF]/.test(text[index]!))
const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === 'object' && !Array.isArray(value)
function keys(value: Record<string, unknown>, allowed: string[]) { if (Object.keys(value).some(key => !allowed.includes(key))) throw new Error('This formatting contains unsupported fields. Its source is preserved.') }
export function paragraphs(source: string): TextRange[] {
  const result: TextRange[] = []; let start = 0
  while (start < source.length) { const newline = source.indexOf('\n', start), finish = newline < 0 ? source.length : newline + 1; result.push({ start, length: finish - start }); start = finish }
  return result
}
export function readFormatting(content: TextContent): TextFormatting {
  const source = content.source
  if (source.length > 16 * 1024 * 1024) throw new Error('Text exceeds 16 MiB of UTF-16 content.')
  // Lone surrogates cannot be serialized as portable UTF-8 scalar text.
  for (const character of source) if (character.length === 1 && /[\uD800-\uDFFF]/.test(character)) throw new Error('Text contains an incomplete Unicode character.')
  if (content.formatting == null) return { version: 1, runs: [] }
  const value = content.formatting
  if (!object(value) || ![1, 2].includes(value.version as number)) throw new Error('This formatting version is unavailable in the web editor. Its source is preserved.')
  keys(value, value.version === 1 ? ['version', 'runs'] : ['version', 'runs', 'paragraphs', 'tables'])
  if (!Array.isArray(value.runs) || value.runs.length > 20000) throw new Error('Formatting permits at most 20000 runs.')
  function ranges<T extends TextRange>(items: unknown[], allowed: string[], structural = false): T[] {
    let previous = 0
    return items.map(item => {
      if (!object(item)) throw new Error('Invalid formatting range.')
      keys(item, allowed)
      const { start, length } = item
      if (typeof start !== 'number' || !Number.isSafeInteger(start) || typeof length !== 'number' || !Number.isSafeInteger(length) || length <= 0 || start < previous || !scalarBoundary(source, start) || !scalarBoundary(source, start + length)) throw new Error('Formatting ranges must be ordered and end at Unicode scalar boundaries.')
      if (structural && ((start > 0 && source[start - 1] !== '\n') || (start + length < source.length && source[start + length - 1] !== '\n'))) throw new Error('Structure must cover complete paragraphs.')
      previous = start + length
      return { ...item } as unknown as T
    })
  }
  const runs = ranges<TextRun>(value.runs, ['start', 'length', 'style', 'bold', 'italic', 'underline'])
  for (const run of runs) {
    if (run.style !== undefined && !textStyles.includes(run.style)) throw new Error('Unsupported inline text style.')
    for (const key of ['bold', 'italic', 'underline'] as const) if (run[key] !== undefined && typeof run[key] !== 'boolean') throw new Error('Invalid inline text attribute.')
  }
  if (value.version === 1) return { version: 1, runs }
  if ((value.paragraphs !== undefined && !Array.isArray(value.paragraphs)) || (value.tables !== undefined && !Array.isArray(value.tables))) throw new Error('Invalid paragraph/table formatting.')
  const para = ranges<TextParagraph>((value.paragraphs || []) as unknown[], ['start', 'length', 'style', 'list'], true)
  if (para.length + runs.length > 20000) throw new Error('Formatting permits at most 20000 runs and paragraphs.')
  for (const item of para) {
    if (item.style !== undefined && !['body', 'heading1', 'heading2', 'heading3'].includes(item.style)) throw new Error('Unsupported paragraph style.')
    if (item.list !== undefined && !['bullet', 'numbered'].includes(item.list)) throw new Error('Unsupported list style.')
    if (item.list) for (const range of paragraphs(source.slice(item.start, end(item)))) if (!listPrefix(source.slice(item.start + range.start), item.list)) throw new Error('List paragraphs need their portable text markers. Use the list controls to change them.')
  }
  const tables = ranges<TextTable>((value.tables || []) as unknown[], ['start', 'length', 'columns', 'cells'], true)
  if (tables.length > 100) throw new Error('Text permits at most 100 tables.')
  for (const table of tables) {
    if (!Number.isInteger(table.columns) || table.columns < 1 || table.columns > 12 || !Array.isArray(table.cells) || !table.cells.length || table.cells.length > 240 || table.cells.length % table.columns || source[end(table) - 1] !== '\n' || para.some(item => overlap(item, table))) throw new Error('Tables need rectangular cells and complete paragraphs without list/heading overlap.')
    const cells = ranges<TextRange>(table.cells, ['start', 'length']); let cursor = table.start
    for (const cell of cells) { if (cell.start !== cursor || end(cell) > end(table) || source[end(cell) - 1] !== '\n') throw new Error('Table cells must partition the table and end with a newline.'); cursor = end(cell) }
    if (cursor !== end(table)) throw new Error('Incomplete table.')
    table.cells = cells
  }
  return { version: 2, runs, paragraphs: para, tables }
}
export function formattingError(content: TextContent) { try { readFormatting(content); return '' } catch (error) { return error instanceof Error ? error.message : 'Invalid rich text.' } }
function descriptor(run?: TextRun): Omit<TextRun, 'start' | 'length'> { return { style: run?.style || 'body', bold: run?.bold === true, italic: run?.italic === true, underline: run?.underline === true } }
function same(a?: TextRun, b?: TextRun) { return JSON.stringify(descriptor(a)) === JSON.stringify(descriptor(b)) }
function normalize(runs: TextRun[]): TextRun[] {
  const result: TextRun[] = []
  for (const run of runs.sort((a, b) => a.start - b.start)) {
    if (!run.length || same(run)) continue
    const last = result.at(-1)
    if (last && end(last) === run.start && same(last, run)) last.length += run.length
    else result.push({ start: run.start, length: run.length, ...descriptor(run) })
  }
  return result
}
function publish(source: string, format: TextFormatting): TextContent {
  format.runs = normalize(format.runs)
  const paragraphs = format.paragraphs || [], tables = format.tables || []
  let formatting: TextFormatting | undefined
  if (paragraphs.length || tables.length) formatting = { version: 2, runs: format.runs, paragraphs, tables }
  else if (format.runs.length) formatting = { version: 1, runs: format.runs }
  const result = { source, ...(formatting ? { formatting } : {}) }; readFormatting(result); return result
}
export function selectedParagraphs(source: string, selection: TextRange) {
  const positions = paragraphs(source)
  return positions.filter(range => selection.length ? overlap(range, selection) : selection.start >= range.start && (selection.start < end(range) || (selection.start === source.length && end(range) === source.length)))
}
function validateSelection(content: TextContent, selection: TextRange) { if (!Number.isSafeInteger(selection.length) || selection.length < 0 || !scalarBoundary(content.source, selection.start) || !scalarBoundary(content.source, end(selection))) throw new Error('Select complete Unicode characters.') }
// A single replacement preserves inline spans and paragraph/table ownership.
// Cell terminators and outside/table boundaries cannot be deleted accidentally.
export function replaceText(content: TextContent, selection: TextRange, insert: string, beforeStructure = false): TextContent {
  validateSelection(content, selection); const format = readFormatting(content), finish = end(selection), delta = insert.length - selection.length
  for (const table of format.tables || []) {
    if (selection.start <= table.start && finish >= end(table) && selection.length) continue
    if (selection.length && selection.start < table.start && finish >= table.start) throw new Error('Select the entire table to remove it, or edit inside one cell.')
    if (table.cells.some(cell => selection.start <= end(cell) - 1 && finish > end(cell) - 1)) throw new Error('Keep table cell boundaries. Use the table controls to change its structure.')
  }
  const source = content.source.slice(0, selection.start) + insert + content.source.slice(finish)
  const inherited = format.runs.find(run => run.start <= selection.start && end(run) > selection.start) || format.runs.find(run => end(run) === selection.start)
  const runs: TextRun[] = []
  for (const run of format.runs) {
    if (run.start < selection.start) { const length = Math.min(end(run), selection.start) - run.start; if (length) runs.push({ ...run, length }) }
    if (end(run) > finish) { const start = Math.max(run.start, finish); runs.push({ ...run, start: start + delta, length: end(run) - start }) }
  }
  if (insert.length && inherited) runs.push({ start: selection.start, length: insert.length, ...descriptor(inherited) })
  function remap(range: TextRange, atEndOutside = false): TextRange | null {
    if (selection.length && selection.start <= range.start && finish >= end(range)) return null
    const start = range.start >= finish && !(selection.length === 0 && range.start === selection.start && !beforeStructure) ? range.start + delta : Math.min(range.start, selection.start)
    const newEnd = end(range) < selection.start || (atEndOutside && end(range) === selection.start) ? end(range) : end(range) >= finish ? end(range) + delta : selection.start + insert.length
    return newEnd > start ? { start, length: newEnd - start } : null
  }
  const tables = (format.tables || []).flatMap(table => {
    const range = remap(table, true); if (!range) return []
    const cells = table.cells.map(cell => remap(cell, true)!).filter(Boolean)
    // Inserting at a cell boundary belongs to the following cell, not both.
    if (!beforeStructure && !selection.length && table.cells.some(cell => cell.start === selection.start) && insert.length) {
      let cursor = range.start
      for (let i = 0; i < cells.length; i++) { const original = table.cells[i]!; cells[i] = { start: cursor, length: original.length + (original.start === selection.start ? insert.length : 0) }; cursor += cells[i]!.length }
    }
    return [{ ...table, ...range, cells }]
  })
  const mapped = (format.paragraphs || []).flatMap(paragraph => { const range = remap(paragraph, true); return range ? [{ ...paragraph, ...range }] : [] })
  const para = paragraphs(source).flatMap(range => {
    if (tables.some(table => overlap(table, range))) return []
    const previous = firstOverlap(mapped, range); return previous ? [{ ...range, ...(previous.style ? { style: previous.style } : {}), ...(previous.list ? { list: previous.list } : {}) }] : []
  })
  return publish(source, { version: 2, runs, paragraphs: para, tables })
}
export function replaceSource(content: TextContent, source: string) {
  let start = 0, finish = content.source.length, next = source.length
  while (start < finish && start < next && content.source[start] === source[start]) start++
  while (!scalarBoundary(content.source, start) || !scalarBoundary(source, start)) start--
  while (finish > start && next > start && content.source[finish - 1] === source[next - 1]) { finish--; next-- }
  while (!scalarBoundary(content.source, finish) || !scalarBoundary(source, next)) { finish++; next++ }
  return replaceText(content, { start, length: finish - start }, source.slice(start, next))
}
export function inlineFormat(content: TextContent, selection: TextRange, key: 'bold' | 'italic' | 'underline' | 'code' | 'clear') {
  validateSelection(content, selection); if (!selection.length) throw new Error('Select text to format.')
  const format = readFormatting(content), points = [...new Set([0, content.source.length, selection.start, end(selection), ...format.runs.flatMap(run => [run.start, end(run)])])].sort((a, b) => a - b)
  let index = 0
  const segments = points.slice(0, -1).map((start, i) => { while (format.runs[index] && end(format.runs[index]!) <= start) index++; return { start, length: points[i + 1]! - start, ...descriptor(format.runs[index] && format.runs[index]!.start <= start ? format.runs[index] : undefined) } })
  const selected = segments.filter(range => overlap(range, selection)), enabled = key === 'code' ? !selected.every(run => run.style === 'code') : key !== 'clear' && !selected.every(run => run[key])
  for (const run of selected) { if (key === 'clear') Object.assign(run, descriptor()); else if (key === 'code') run.style = enabled ? 'code' : 'body'; else run[key] = enabled }
  return publish(content.source, { ...format, runs: segments })
}
export function paragraphFormat(content: TextContent, selection: TextRange, style: Exclude<TextStyle, 'code'>) {
  const format = readFormatting(content), chosen = selectedParagraphs(content.source, selection)
  if (!chosen.length) throw new Error('Write a paragraph before choosing its style.')
  if (chosen.some(range => format.tables?.some(table => overlap(range, table)))) throw new Error('Use inline styles inside table cells.')
  const existing = format.paragraphs || [], selectedStarts = new Set(chosen.map(range => range.start)), para = paragraphs(content.source).flatMap(range => {
    const old = firstOverlap(existing, range), selected = selectedStarts.has(range.start), next = selected ? style : old?.style
    return next && next !== 'body' || old?.list ? [{ ...range, ...(next ? { style: next } : {}), ...(old?.list ? { list: old.list } : {}) }] : []
  })
  return publish(content.source, { ...format, version: 2, paragraphs: para })
}
export function listPrefix(text: string, kind: 'bullet' | 'numbered') { return kind === 'bullet' ? text.startsWith('•\t') ? 2 : 0 : /^[1-9]\d*\.\t/.exec(text)?.[0].length || 0 }
export function renumberLists(content: TextContent, selection: TextRange) {
  const format = readFormatting(content), edits: { start: number; length: number; text: string }[] = []; let count = 0
  for (const range of paragraphs(content.source)) {
    const list = firstOverlap(format.paragraphs || [], range)?.list
    if (list !== 'numbered') { count = 0; continue }
    const text = `${++count}.\t`, length = listPrefix(content.source.slice(range.start), 'numbered')
    if (content.source.slice(range.start, range.start + length) !== text) edits.push({ start: range.start, length, text })
  }
  if (edits.length > 500) throw new Error('Renumber at most 500 list paragraphs per edit. Split this edit into smaller selections.')
  let result = content, start = selection.start, finish = end(selection)
  for (const edit of edits.reverse()) { result = replaceText(result, edit, edit.text); if (edit.start < start) start += edit.text.length - edit.length; if (edit.start < finish) finish += edit.text.length - edit.length }
  return { content: result, selection: { start, length: Math.max(0, finish - start) } }
}
export function listFormat(content: TextContent, selection: TextRange, kind: 'bullet' | 'numbered'): TextContent {
  const format = readFormatting(content), chosen = selectedParagraphs(content.source, selection)
  if (!chosen.length) throw new Error('Write a paragraph before making a list.')
  if (chosen.length > 500) throw new Error('Format at most 500 list paragraphs per operation.')
  if (chosen.some(range => format.tables?.some(table => overlap(range, table)))) throw new Error('Lists cannot replace table cells.')
  const remove = chosen.every(range => firstOverlap(format.paragraphs || [], range)?.list === kind)
  // First remove list ownership, then replace derived markers in reverse order.
  const selectedStarts = new Set(chosen.map(range => range.start))
  const owned = paragraphs(content.source).flatMap(range => { const old = firstOverlap(format.paragraphs || [], range); return old ? [{ ...old, ...range, ...(selectedStarts.has(range.start) ? { list: undefined } : {}) }] : [] })
  let result = publish(content.source, { ...format, paragraphs: owned })
  for (let i = chosen.length - 1; i >= 0; i--) {
    const range = chosen[i]!, oldKind = firstOverlap(format.paragraphs || [], range)?.list, prefix = oldKind ? listPrefix(content.source.slice(range.start), oldKind) : 0
    result = replaceText(result, { start: range.start, length: prefix }, remove ? '' : kind === 'bullet' ? '•\t' : `${i + 1}.\t`)
  }
  if (remove) return result
  const updated = readFormatting(result), positions = paragraphs(result.source), first = chosen[0]!.start, lastIndex = paragraphs(content.source).findIndex(range => range.start === chosen.at(-1)!.start), firstIndex = paragraphs(content.source).findIndex(range => range.start === first)
  const para = positions.flatMap((range, i) => { const old = firstOverlap(updated.paragraphs || [], range), selected = i >= firstIndex && i <= lastIndex; return selected || old ? [{ ...old, ...range, ...(selected ? { list: kind } : {}) }] : [] })
  return publish(result.source, { ...updated, version: 2, paragraphs: para })
}
export function tableAt(content: TextContent, caret: number) { return readFormatting(content).tables?.find(table => caret >= table.start && caret < end(table)) }
export function insertTable(content: TextContent, selection: TextRange, rows = 2, columns = 2) {
  if (tableAt(content, selection.start)) throw new Error('Tables cannot be nested.')
  if (!Number.isInteger(rows) || !Number.isInteger(columns) || rows < 1 || columns < 1 || columns > 12 || rows * columns > 240) throw new Error('Tables permit 1–12 columns and at most 240 cells.')
  let position = selectedParagraphs(content.source, { start: end(selection), length: 0 })[0]; let offset = position ? end(position) : content.source.length
  let result = content
  if (offset && content.source[offset - 1] !== '\n') { result = replaceText(content, { start: offset, length: 0 }, '\n'); offset++ }
  result = replaceText(result, { start: offset, length: 0 }, '\n'.repeat(rows * columns) + '\n', true)
  const format = readFormatting(result), table: TextTable = { start: offset, length: rows * columns, columns, cells: Array.from({ length: rows * columns }, (_, i) => ({ start: offset + i, length: 1 })) }
  format.paragraphs = (format.paragraphs || []).filter(range => !overlap(range, table)); format.tables = [...(format.tables || []), table].sort((a, b) => a.start - b.start)
  return { content: publish(result.source, { ...format, version: 2 }), caret: table.start }
}
export function tableChange(content: TextContent, caret: number, operation: 'addRow' | 'removeRow' | 'addColumn' | 'removeColumn' | 'remove') {
  const format = readFormatting(content), table = format.tables?.find(table => caret >= table.start && caret < end(table))
  if (!table) throw new Error('Place the caret inside a table cell.')
  if (operation === 'remove') return { content: replaceText(content, table, ''), caret: table.start }
  const cellIndex = table.cells.findIndex(cell => caret >= cell.start && caret < end(cell)), row = Math.floor(cellIndex / table.columns), column = cellIndex % table.columns
  const cells = table.cells.map(range => ({ source: content.source.slice(range.start, end(range)), runs: format.runs.filter(run => overlap(run, range)).map(run => ({ ...run, start: Math.max(run.start, range.start) - range.start, length: Math.min(end(run), end(range)) - Math.max(run.start, range.start) })) }))
  let columns = table.columns
  if (operation === 'addRow') cells.splice((row + 1) * columns, 0, ...Array.from({ length: columns }, () => ({ source: '\n', runs: [] })))
  if (operation === 'removeRow') { if (cells.length === columns) return tableChange(content, caret, 'remove'); cells.splice(row * columns, columns) }
  if (operation === 'addColumn') { if (columns >= 12) throw new Error('Tables permit at most 12 columns.'); for (let i = cells.length / columns - 1; i >= 0; i--) cells.splice(i * columns + column + 1, 0, { source: '\n', runs: [] }); columns++ }
  if (operation === 'removeColumn') { if (columns === 1) return tableChange(content, caret, 'remove'); for (let i = cells.length / columns - 1; i >= 0; i--) cells.splice(i * columns + column, 1); columns-- }
  if (cells.length > 240) throw new Error('Tables permit at most 240 cells.')
  let result = replaceText(content, table, ''), offset = table.start
  // The replacement's inline runs are reconstructed from each retained cell.
  const source = cells.map(cell => cell.source).join(''); result = replaceText(result, { start: offset, length: 0 }, source, true)
  const next = readFormatting(result), ranges: TextRange[] = [], runs: TextRun[] = next.runs.flatMap(run => {
    const before = run.start < offset ? [{ ...run, length: Math.min(end(run), offset) - run.start }] : [], after = end(run) > offset + source.length ? [{ ...run, start: Math.max(run.start, offset + source.length), length: end(run) - Math.max(run.start, offset + source.length) }] : []
    return [...before, ...after]
  })
  for (const cell of cells) { ranges.push({ start: offset, length: cell.source.length }); runs.push(...cell.runs.map(run => ({ ...run, start: run.start + offset }))); offset += cell.source.length }
  const newTable = { start: table.start, length: source.length, columns, cells: ranges }
  return { content: publish(result.source, { ...next, version: 2, runs, paragraphs: (next.paragraphs || []).filter(range => !overlap(range, newTable)), tables: [...(next.tables || []), newTable].sort((a, b) => a.start - b.start) }), caret: ranges[Math.min(cellIndex, ranges.length - 1)]!.start }
}
export interface InlineText { text: string; style: TextStyle; bold: boolean; italic: boolean; underline: boolean }
export function inlineText(content: TextContent, range: TextRange, format = readFormatting(content)): InlineText[] {
  let low = 0, high = format.runs.length
  while (low < high) { const mid = (low + high) >>> 1; if (end(format.runs[mid]!) <= range.start) low = mid + 1; else high = mid }
  const runs: TextRun[] = []; for (let i = low; i < format.runs.length && format.runs[i]!.start < end(range); i++) runs.push(format.runs[i]!)
  const points = [...new Set([range.start, end(range), ...runs.flatMap(run => [Math.max(run.start, range.start), Math.min(end(run), end(range))])])].sort((a, b) => a - b)
  let index = 0
  return points.slice(0, -1).map((start, point) => { while (runs[index] && end(runs[index]!) <= start) index++; return { text: content.source.slice(start, points[point + 1]), ...descriptor(runs[index] && runs[index]!.start <= start ? runs[index] : undefined) } }) as InlineText[]
}
export function textBlocks(content: TextContent) {
  const format = readFormatting(content), blocks: ({ kind: 'paragraph'; style: string; list?: string; spans: InlineText[] } | { kind: 'table'; columns: number; rows: InlineText[][][] })[] = []
  let cursor = 0, paragraphIndex = 0
  const tables = new Map(format.tables?.map(table => [table.start, table]))
  while (cursor < content.source.length) {
    const table = tables.get(cursor)
    if (table) { const rows: InlineText[][][] = []; for (let i = 0; i < table.cells.length; i += table.columns) rows.push(table.cells.slice(i, i + table.columns).map(range => inlineText(content, { start: range.start, length: range.length - 1 }, format))); blocks.push({ kind: 'table', columns: table.columns, rows }); cursor = end(table) }
    else { const newline = content.source.indexOf('\n', cursor), finish = newline < 0 ? content.source.length : newline + 1; while (format.paragraphs?.[paragraphIndex] && end(format.paragraphs[paragraphIndex]!) <= cursor) paragraphIndex++; const paragraph = format.paragraphs?.[paragraphIndex]; blocks.push({ kind: 'paragraph', style: paragraph && cursor >= paragraph.start ? paragraph.style || 'body' : 'body', list: paragraph && cursor >= paragraph.start ? paragraph.list : undefined, spans: inlineText(content, { start: cursor, length: finish - cursor - (content.source[finish - 1] === '\n' ? 1 : 0) }, format) }); cursor = finish }
  }
  return blocks
}
