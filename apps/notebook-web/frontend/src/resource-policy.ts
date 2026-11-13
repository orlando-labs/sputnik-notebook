import { documentJSON, parseDocumentJSON } from './document-json'

export const resourceFields = [
  { key: 'run_count', title: 'Saved runs', unit: '', scale: 1n, maximum: 1000n },
  { key: 'run_age_seconds', title: 'Keep history', unit: 'seconds', scale: 1n, maximum: 315360000n },
  { key: 'project_bytes', title: 'Notebook storage', unit: 'MiB', scale: 1048576n, maximum: 10240n },
  { key: 'max_run_bytes', title: 'One run snapshot', unit: 'MiB', scale: 1048576n, maximum: 128n },
  { key: 'minimum_free_bytes', title: 'Keep server disk space free', unit: 'MiB', scale: 1048576n, maximum: 1048576n },
  { key: 'revision_count', title: 'Server revisions', unit: '', scale: 1n, maximum: 1000n },
  { key: 'run_seconds', title: 'One run', unit: 'seconds', scale: 1n, maximum: 31536000n },
  { key: 'total_run_seconds', title: 'Total execution time per notebook', unit: 'seconds', scale: 1n, maximum: 31536000n },
] as const
export type ResourceKey = typeof resourceFields[number]['key']
export type ResourceLimits = Record<ResourceKey, string | null>
export interface ResourceStatus {
  effective: ResourceLimits; defaults: ResourceLimits; spent_ms: string; remaining_ms: string | null
  ip_remaining_ms?: string
  temporary: boolean; allow_book_policy_overrides: boolean
  storage?: { project_bytes: string; retained_runs: string; active_runs: string }
}
export function integerToken(value: unknown): string | null {
  if (value == null) return null
  const token = documentJSON(value)
  if (!/^[1-9]\d{0,18}$/.test(token) || BigInt(token) > 9223372036854775807n) throw new Error('Resource limits must be positive integers.')
  return token
}
export function bookPolicy(value: unknown): Partial<Record<ResourceKey, unknown>> {
  if (value == null) return {}
  if (typeof value !== 'object' || Array.isArray(value)) throw new Error('This notebook has an unsupported resource policy. Its settings are preserved.')
  for (const [key, item] of Object.entries(value)) {
    if (!resourceFields.some(field => field.key === key)) throw new Error('This notebook has unsupported resource fields. Its settings are preserved.')
    integerToken(item)
  }
  return value as Partial<Record<ResourceKey, unknown>>
}
export function scaledValue(token: string | null, scale: bigint): string {
  if (token === null) return ''
  const value = BigInt(token), whole = value / scale
  let remainder = value % scale, fraction = ''
  while (remainder && fraction.length < 20) { remainder *= 10n; fraction += (remainder / scale).toString(); remainder %= scale }
  return whole.toString() + (fraction ? '.' + fraction : '')
}
export function policyValue(text: string, field: typeof resourceFields[number]): unknown {
  if (!/^\d+(?:\.\d{1,20})?$/.test(text)) throw new Error(`${field.title} needs a positive number in ${field.unit || 'whole units'}.`)
  const [whole, fraction = ''] = text.split('.'), denominator = 10n ** BigInt(fraction.length)
  const numerator = BigInt(whole! + fraction) * field.scale
  if (numerator % denominator !== 0n || numerator <= 0n || numerator / denominator > field.maximum * field.scale) throw new Error(`${field.title} must be positive, at most ${field.maximum} ${field.unit}, and represent whole ${field.scale === 1n ? 'units' : 'bytes'}.`)
  return parseDocumentJSON((numerator / denominator).toString())
}
export function secondsLabel(milliseconds: string | null): string {
  if (milliseconds === null) return 'Unlimited'
  return scaledValue(milliseconds, 1000n) + ' s'
}
export function bytesLabel(bytes: string): string { return scaledValue(bytes, 1048576n).replace(/(\.\d{2})\d+$/, '$1') + ' MiB' }
