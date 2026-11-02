import { documentJSON, parseDocumentJSON } from './document-json'
export type InputType = 'number' | 'integer' | 'boolean' | 'string' | 'range'
export interface InputDefinition { id: string; title: string; type: InputType; default?: unknown; default_json?: string; minimum?: number; maximum?: number; [key: string]: unknown }
export interface InputControl { style?: string; config_format?: string; minimum?: number; maximum?: number; step?: number; unit?: string; precision?: number; start_minimum?: number; start_maximum?: number; finish_minimum?: number; finish_maximum?: number; options?: { label: string; value_json: string; [key: string]: unknown }[]; [key: string]: unknown }
export interface FormField { input: string; control?: InputControl; [key: string]: unknown }
export interface ChartSeriesSettings { id: string; title: string; stroke: string; [key: string]: unknown }
export interface ActionArgument { id: string; name?: string; input?: string; value_json?: string; [key: string]: unknown }
export interface DisplaySettings { unit?: string; precision?: number; percentage?: boolean; target?: unknown; baseline?: unknown; improvement?: string; series?: ChartSeriesSettings[]; arguments?: ActionArgument[]; target_kind?: string; target_component?: string; [key: string]: unknown }
export interface CellComponent {
  id: string; kind: string; title: string; input?: string; control?: InputControl; fields?: FormField[]
  binding?: string; table_id?: string; chart_id?: string; image_id?: string; image_mode?: string; image_allow_save?: boolean
  audio_id?: string; show_waveform?: boolean
  caption?: string; x_label?: string; y_label?: string; stroke?: string; x_min?: unknown; x_max?: unknown; y_min?: unknown; y_max?: unknown; p1?: DisplaySettings
  [key: string]: unknown
}
export interface CellUI { inputs: InputDefinition[]; pre: CellComponent[]; post: CellComponent[]; [key: string]: unknown }
export interface InputState { revision: string; version: string; values: Record<string, string>; can_apply: boolean }
export const inputTypes: InputType[] = ['number', 'integer', 'boolean', 'string', 'range']
export const typeTitles: Record<InputType, string> = { number: 'Number (decimal)', integer: 'Integer (Int64)', boolean: 'Boolean', string: 'String (text)', range: 'Range' }
const integer = /^[+-]?\d+$/
function int64(text: string) {
  if (!integer.test(text)) throw new Error('Enter a whole number in the Int64 range.')
  const value = BigInt(text)
  if (value < -9223372036854775808n || value > 9223372036854775807n) throw new Error('Enter a whole number in the Int64 range.')
  return value.toString()
}
export function decimalJSON(text: string) {
  if (!text.trim() || !Number.isFinite(Number(text)) || !/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(text)) throw new Error('Enter a finite number.')
  const value = Number(text)
  const token = Object.is(value, -0) ? '-0' : String(value)
  return /[.eE]/.test(token) ? token : token + '.0'
}
function rangeToken(text: string) { return integer.test(text) ? int64(text) : decimalJSON(text) }
function rangeParts(source: string) {
  const object = parseDocumentJSON(source) as Record<string, unknown>
  if (!object || typeof object !== 'object' || Object.keys(object).sort().join(',') !== 'finish,inclusive_end,start,step' || typeof object.inclusive_end !== 'boolean') throw new Error('Range requires start, finish, inclusive_end and step.')
  const token = (key: string) => {
    const match = new RegExp(`"${key}"\\s*:\\s*(-?(?:0|[1-9]\\d*)(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)(?=\\s*[,}])`).exec(source)
    if (!match) throw new Error('Range bounds and step must be numbers.')
    return match[1]!
  }
  return { start: token('start'), finish: token('finish'), step: token('step'), inclusive: object.inclusive_end }
}
export function rangeJSON(source: string): string {
  let start: string, finish: string, step: string, inclusive: boolean
  let text = source.trim()
  if (text.startsWith('{')) {
    const parts = rangeParts(text)
    start = parts.start; finish = parts.finish; step = parts.step; inclusive = parts.inclusive
  } else {
    if (text.startsWith('(') || text.endsWith(')')) { if (!text.startsWith('(') || !text.endsWith(')')) throw new Error('Close the range parentheses.'); text = text.slice(1, -1) }
    const number = '([+-]?(?:\\d+(?:\\.\\d+)?|\\.\\d+)(?:[eE][+-]?\\d+)?)'
    const match = new RegExp(`^\\s*${number}\\s*(\\.\\.\\.?)\\s*${number}\\s*(?::\\s*${number})?\\s*$`).exec(text)
    if (!match) throw new Error('Enter a range such as (0...15:3).')
    start = match[1]!; finish = match[3]!; step = match[4] || '1'; inclusive = match[2] === '..'
  }
  start = rangeToken(start); finish = rangeToken(finish); step = rangeToken(step)
  if (Number(step) === 0) throw new Error('Range step must not be zero.')
  if (integer.test(start) && integer.test(finish) && !integer.test(step)) throw new Error('An integer range requires an integer step.')
  return `{"start":${start},"finish":${finish},"inclusive_end":${inclusive},"step":${step}}`
}
export function rangeDomains(source: string, control: InputControl) {
  const value = rangeParts(rangeJSON(source))
  const start = value.start, finish = value.finish
  const whole = integer.test(start) && integer.test(finish)
  const separate = control.style === 'range_sliders'
  const domains = [separate ? control.start_minimum : control.minimum, separate ? control.start_maximum : control.maximum, separate ? control.finish_minimum : control.minimum, separate ? control.finish_maximum : control.maximum]
  if (!domains.every((item): item is number => typeof item === 'number' && Number.isFinite(item) && Math.abs(item) < 1e100 && (!whole || Number.isSafeInteger(item)))) throw new Error('Set finite slider bounds; integer slider bounds must be exact whole numbers.')
  const [startMin, startMax, finishMin, finishMax] = domains as [number, number, number, number]
  const increment = control.step ?? (whole ? 1 : Math.min(startMax - startMin, finishMax - finishMin) / 100)
  if (startMin >= startMax || finishMin >= finishMax || startMin > finishMax || !Number.isFinite(increment) || increment <= 0 || (whole && !Number.isSafeInteger(increment))) throw new Error('Set increasing slider domains and a positive increment.')
  if (Number(start) < startMin || Number(start) > startMax || Number(finish) < finishMin || Number(finish) > finishMax || Number(start) > Number(finish)) throw new Error('Range endpoints must fit slider bounds, with finish greater than or equal to start.')
  return { start: Number(start), finish: Number(finish), startMin, startMax, finishMin, finishMax, increment, whole, inclusive: value.inclusive, step: value.step }
}
export function rangeText(source: string) {
  const value = rangeParts(source)
  return `(${value.start}${value.inclusive ? '..' : '...'}${value.finish}:${value.step})`
}
export function defaultJSON(input: InputDefinition) { return Object.hasOwn(input, 'default') ? documentJSON(input.default) : input.default_json || 'null' }
export function editingText(value: string, type: InputType) {
  try { return type === 'string' ? JSON.parse(value) as string : type === 'range' ? rangeText(value) : value } catch { return value }
}
export function inputJSON(text: string, input: InputDefinition, control: InputControl = {}): string {
  let json: string
  if (input.type === 'string') {
    if (new TextEncoder().encode(text).length > 65536 || text.includes('\0')) throw new Error('Text must fit 64 KiB and contain no NUL.')
    // Config syntax (including YAML/TOML and duplicate keys) is validated by the shared core.
    json = JSON.stringify(text)
  } else if (input.type === 'boolean') { if (!['true', 'false'].includes(text)) throw new Error('Choose true or false.'); json = text }
  else if (input.type === 'range') { json = rangeJSON(text); if (['slider', 'range_sliders'].includes(control.style || '')) rangeDomains(text, control) }
  else {
    json = input.type === 'integer' || integer.test(text.trim()) ? int64(text.trim()) : decimalJSON(text.trim())
    const minimum = lowerBound(input, control), maximum = upperBound(input, control)
    if (minimum != null && (input.type === 'integer' ? BigInt(json) < BigInt(Math.ceil(minimum)) : Number(json) < minimum)) throw new Error(`Minimum: ${minimum}.`)
    if (maximum != null && (input.type === 'integer' ? BigInt(json) > BigInt(Math.floor(maximum)) : Number(json) > maximum)) throw new Error(`Maximum: ${maximum}.`)
  }
  if (['select', 'segmented', 'radio'].includes(control.style || '') && !(control.options || []).some(option => {
    try { return editingText(option.value_json, input.type) === editingText(json, input.type) } catch { return false }
  })) throw new Error('Choose one of the available options.')
  return json
}
export function inputError(text: string, input: InputDefinition, control?: InputControl) { try { inputJSON(text, input, control); return '' } catch (cause) { return cause instanceof Error ? cause.message : 'Invalid parameter value.' } }
export const lowerBound = (input: InputDefinition, control: InputControl) => { const values = [input.minimum, control.minimum].filter((v): v is number => typeof v === 'number'); return values.length ? Math.max(...values) : undefined }
export const upperBound = (input: InputDefinition, control: InputControl) => { const values = [input.maximum, control.maximum].filter((v): v is number => typeof v === 'number'); return values.length ? Math.min(...values) : undefined }
export function stepped(text: string, by: number, input: InputDefinition, control: InputControl): string | null {
  try {
    const result = input.type === 'integer' ? (BigInt(int64(text.trim())) + BigInt(control.step || 1) * BigInt(by)).toString() : decimalJSON(String(Number(text) + by * (control.step || 1)))
    return inputError(result, input, control) ? null : result
  } catch { return null }
}
export function initialText(type: InputType) { return type === 'range' ? '(0...15:3)' : type === 'boolean' ? 'false' : type === 'string' ? '' : '0' }
export function valueEqual(a: string, b: string, type: InputType) {
  try { return inputJSON(editingText(a, type), { id: '', title: '', type }) === inputJSON(editingText(b, type), { id: '', title: '', type }) } catch { return a === b }
}
