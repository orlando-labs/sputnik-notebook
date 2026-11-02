// Authored notebook fields can contain int64 inputs and unknown metadata. Keep
// integer tokens outside JS's exact range opaque while editing supported fields.
class RawInteger {
  constructor(readonly token: string) {}
}
export function parseDocumentJSON(source: string): unknown {
  let offset = 0
  const number = /-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/y
  const whitespace = () => { while (/[\x20\t\r\n]/.test(source[offset] || '\0')) offset++ }
  function string(): string {
    const start = offset++
    while (offset < source.length) {
      const char = source[offset++]
      if (char === '\\') offset++
      else if (char === '"') return JSON.parse(source.slice(start, offset))
    }
    throw new Error('Unterminated JSON string')
  }
  function value(depth: number): unknown {
    if (depth > 256) throw new Error('Notebook JSON nesting is too deep')
    whitespace()
    const char = source[offset]
    if (char === '"') return string()
    if (char === '[') {
      offset++; whitespace(); const result: unknown[] = []
      if (source[offset] === ']') { offset++; return result }
      for (;;) { result.push(value(depth + 1)); whitespace(); const next = source[offset++]; if (next === ']') return result; if (next !== ',') throw new Error('Invalid JSON array') }
    }
    if (char === '{') {
      offset++; whitespace(); const result: Record<string, unknown> = Object.create(null)
      if (source[offset] === '}') { offset++; return result }
      for (;;) {
        whitespace(); if (source[offset] !== '"') throw new Error('Invalid JSON key')
        const key = string(); whitespace()
        if (source[offset++] !== ':' || Object.hasOwn(result, key)) throw new Error('Invalid or duplicate JSON key')
        result[key] = value(depth + 1); whitespace()
        const next = source[offset++]; if (next === '}') return result; if (next !== ',') throw new Error('Invalid JSON object')
      }
    }
    for (const [token, result] of [['true', true], ['false', false], ['null', null]] as const) if (source.startsWith(token, offset)) { offset += token.length; return result }
    number.lastIndex = offset
    const match = number.exec(source)
    if (!match) throw new Error('Invalid JSON value')
    offset = number.lastIndex
    const token = match[0], parsed = Number(token)
    if (/^-?\d+$/.test(token) && !Number.isSafeInteger(parsed)) return new RawInteger(token)
    if (!Number.isFinite(parsed)) throw new Error('Invalid JSON number')
    return parsed
  }
  const result = value(0); whitespace()
  if (offset !== source.length) throw new Error('Unexpected JSON data')
  return result
}
export function documentJSON(value: unknown): string {
  if (value instanceof RawInteger) return value.token
  // A plain Number outside the safe integer range came from a Float token or
  // a numeric editor. Keep it a Float; an integer JSON token could overflow Int64.
  if (typeof value === 'number' && Number.isFinite(value) && Number.isInteger(value) && !Number.isSafeInteger(value)) return value.toExponential()
  if (Array.isArray(value)) return `[${value.map(item => item === undefined ? 'null' : documentJSON(item)).join(',')}]`
  if (value !== null && typeof value === 'object') return `{${Object.entries(value).filter(([, value]) => value !== undefined).map(([key, value]) => `${JSON.stringify(key)}:${documentJSON(value)}`).join(',')}}`
  return JSON.stringify(value) ?? 'null'
}
