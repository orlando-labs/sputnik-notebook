export interface CodeRange { start_line: number; start_column: number; end_line: number; end_column: number; whole_line: boolean }
export interface CodeDiagnostic { message: string; truncated: boolean; range: CodeRange | null }
export interface DiagnosticSelection { start: number; end: number }
export function sourceLines(source: string) {
  const starts = [0], ends: number[] = []
  for (const match of source.matchAll(/\r\n|[\r\n]/g)) { ends.push(match.index!); starts.push(match.index! + match[0].length) }
  ends.push(source.length)
  return { starts, ends }
}

// Core columns count Unicode scalars, while browser selection uses UTF-16.
// Lines/columns are zero based. No filesystem location crosses this boundary.
export function diagnosticSelection(source: string, range: CodeRange | null, { starts, ends } = sourceLines(source)): DiagnosticSelection | null {
  if (!range || ![range.start_line, range.end_line, range.start_column, range.end_column].every(value => Number.isSafeInteger(value) && value >= 0) || range.end_line < range.start_line) return null
  if (range.end_line >= starts.length) return null
  function position(line: number, column: number, isEnd = false) {
    let at = starts[line]!, count = 0
    while (at < ends[line]! && count < column) { at += source.codePointAt(at)! > 65535 ? 2 : 1; count++ }
    // The compiler can extend a point at end of line by one column.
    return count === column || (isEnd && count + 1 === column) ? at : null
  }
  const start = range.whole_line ? starts[range.start_line]! : position(range.start_line, range.start_column)
  const end = range.whole_line ? ends[range.end_line]! : position(range.end_line, range.end_column, true)
  return start !== null && end !== null && end >= start ? { start, end } : null
}
