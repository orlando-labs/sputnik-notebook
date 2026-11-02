import { defaultJSON, editingText, inputJSON, type InputDefinition } from './inputs'
import { dateSettingsError } from './date-input'
import type { BoardComponent } from './boards'
export interface ParameterPreset { id: string; title: string; values: Record<string, string>; [key: string]: unknown }
export function presetError(preset: ParameterPreset, definitions: InputDefinition[], scope: string[] = [], components: BoardComponent[] = []): string {
  const text = (v: unknown, limit: number) => typeof v === 'string' && !!v.trim() && !v.includes('\0') && new TextEncoder().encode(v).length <= limit
  if (!preset || !text(preset.id, 256) || !text(preset.title, 256) || !preset.values || typeof preset.values !== 'object' || Array.isArray(preset.values) || !Object.keys(preset.values).length || Object.keys(preset.values).length > 128) return 'Use a named preset with 1–128 parameter values.'
  for (const [id, json] of Object.entries(preset.values)) {
    const input = definitions.find(d => d.id === id)
    if (!input || scope.length && !scope.includes(id) || typeof json !== 'string') return 'A preset parameter is unavailable or outside its scope.'
    try {
      if (input.type === 'string' && typeof JSON.parse(json) !== 'string' || input.type === 'boolean' && !['true', 'false'].includes(json) || input.type === 'integer' && !/^-?\d+$/.test(json)) throw new Error('Incorrect scalar type.')
      const normalized = inputJSON(editingText(json, input.type), input)
      void normalized
      for (const component of components) { if (component.kind === 'date_input' && component.input === id) { const invalid = dateSettingsError(component, editingText(json, 'string')); if (invalid) throw new Error(invalid) }; for (const panel of component.panels || []) { const invalid = presetError({ ...preset, values: { [id]: json } }, definitions, scope, panel.components); if (invalid) throw new Error(invalid) } }
    } catch (cause) { return `${input.title}: ${(cause as Error).message}` }
  }
  return ''
}
export function presetListError(values: ParameterPreset[], definitions: InputDefinition[], scope: string[] = [], components: BoardComponent[] = []) {
  if (!Array.isArray(values) || values.length > 128 || new Set(values.map(v => v?.id)).size !== values.length) return 'Use up to 128 presets with unique IDs.'
  for (const preset of values) { const invalid = presetError(preset, definitions, scope, components); if (invalid) return invalid }
  return ''
}
export function capturePreset(title: string, definitions: InputDefinition[], current: Record<string, string>, scope: string[]) {
  const values: Record<string, string> = Object.create(null)
  for (const input of definitions) if (!scope.length || scope.includes(input.id)) values[input.id] = current[input.id] ?? defaultJSON(input)
  return { id: 'preset_' + crypto.randomUUID().replaceAll('-', ''), title, values }
}
