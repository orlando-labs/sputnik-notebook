import { documentJSON, parseDocumentJSON } from './document-json'
import type { FileEdit, ProjectFile } from './sources'

export interface MergeConflict { id: string; label: string; local: string; remote: string; file?: string }
export type MergeChoices = Record<string, 'local' | 'remote'>
const equal = (a: unknown, b: unknown) => documentJSON(a) === documentJSON(b)
const plain = (value: unknown): value is Record<string, unknown> => value !== null && typeof value === 'object' && !Array.isArray(value) && Object.getPrototypeOf(value) === null
const preview = (value: unknown) => value === undefined ? '(removed)' : (typeof value === 'string' ? value : documentJSON(value)).slice(0, 4000)

// Parse with the lossless document codec. Opaque Int64 tokens are leaves, never
// object fields; unknown metadata uses the same rules as supported fields.
export function mergeDocument(base: string, local: string, remote: string, choices: MergeChoices = {}) {
  const conflicts: MergeConflict[] = []
  let work = 0
  function conflict(path: string, ours: unknown, theirs: unknown) {
    if (conflicts.length >= 512) throw new Error('Too many conflicts to review here. Export the draft before resolving it manually.')
    conflicts.push({ id: path, label: path, local: preview(ours), remote: preview(theirs) })
    return choices[path] === 'remote' ? theirs : ours
  }
  function merge(before: unknown, ours: unknown, theirs: unknown, path: string): unknown {
    if (++work > 100000) throw new Error('This draft is too complex to merge here. Export it before resolving it manually.')
    if (equal(ours, theirs) || equal(theirs, before)) return ours
    if (equal(ours, before)) return theirs
    if (plain(before) && plain(ours) && plain(theirs)) {
      const result: Record<string, unknown> = Object.create(null)
      // Formatting offsets belong to their source. Concurrent source/style
      // edits need one content choice rather than a silent invalid combination.
      const hasFormatting = [before, ours, theirs].some(item => Object.hasOwn(item, 'formatting'))
      const crossTextEdit = hasFormatting && [before, ours, theirs].every(item => typeof item.source === 'string') &&
        ((!equal(ours.source, before.source) && !equal(theirs.formatting, before.formatting)) || (!equal(theirs.source, before.source) && !equal(ours.formatting, before.formatting)))
      if (crossTextEdit) {
        const content = (item: Record<string, unknown>) => ({ source: item.source, formatting: item.formatting })
        const chosen = conflict(`${path}/$text`, content(ours), content(theirs)) as Record<string, unknown>
        result.source = chosen.source
        if (chosen.formatting !== undefined) result.formatting = chosen.formatting
      }
      for (const key of new Set([...Object.keys(before), ...Object.keys(ours), ...Object.keys(theirs)])) {
        if (crossTextEdit && ['source', 'formatting'].includes(key)) continue
        const value = merge(before[key], ours[key], theirs[key], `${path}/${key.replaceAll('~', '~0').replaceAll('/', '~1')}`)
        if (value !== undefined) result[key] = value
      }
      return result
    }
    const identified = (value: unknown): value is { id: string }[] => Array.isArray(value) && value.every(item => plain(item) && typeof item.id === 'string') && new Set(value.map(item => item.id)).size === value.length
    if (identified(before) && identified(ours) && identified(theirs)) {
      const b = new Map(before.map(item => [item.id, item])), l = new Map(ours.map(item => [item.id, item])), r = new Map(theirs.map(item => [item.id, item]))
      const values = new Map<string, unknown>()
      for (const id of new Set([...b.keys(), ...l.keys(), ...r.keys()])) {
        const value = merge(b.get(id), l.get(id), r.get(id), `${path}/@${id.replaceAll('~', '~0').replaceAll('/', '~1')}`)
        if (value !== undefined) values.set(id, value)
      }
      // Only compare relative ordering of survivors from the base. Additions
      // retain their neighbours in the selected order, then the other order.
      const common = new Set(before.filter(item => values.has(item.id) && l.has(item.id) && r.has(item.id)).map(item => item.id))
      const order = (list: { id: string }[]) => list.filter(item => common.has(item.id)).map(item => item.id)
      const bo = order(before), lo = order(ours), ro = order(theirs)
      let primary = ours, secondary = theirs
      if (equal(lo, bo)) { primary = theirs; secondary = ours }
      else if (!equal(ro, bo) && !equal(lo, ro)) {
        conflict(`${path}/$order`, ours.map(item => item.id), theirs.map(item => item.id))
        if (choices[`${path}/$order`] === 'remote') { primary = theirs; secondary = ours }
      }
      const ids = primary.filter(item => values.has(item.id)).map(item => item.id)
      const present = new Set(ids), additions = new Map<string, string[]>()
      let next = ''
      for (let index = secondary.length - 1; index >= 0; index--) {
        const id = secondary[index]!.id
        if (present.has(id)) { next = id; continue }
        if (!values.has(id)) continue
        const group = additions.get(next) || []; group.push(id); additions.set(next, group)
      }
      return [...ids.flatMap(id => [...(additions.get(id) || []).reverse(), id]), ...(additions.get('') || []).reverse()].map(id => values.get(id))
    }
    return conflict(path, ours, theirs)
  }
  const document = documentJSON(merge(parseDocumentJSON(base), parseDocumentJSON(local), parseDocumentJSON(remote), 'notebook'))
  return { document, conflicts }
}

export function mergeFiles(base: ProjectFile[], remote: ProjectFile[], changes: Record<string, FileEdit | null>, choices: MergeChoices = {}) {
  const before = new Map(base.map(file => [file.path, file.digest])), after = new Map(remote.map(file => [file.path, file.digest]))
  const kept: Record<string, FileEdit | null> = Object.create(null), conflicts: MergeConflict[] = []
  for (const [path, change] of Object.entries(changes)) {
    if (change === null && !after.has(path)) continue
    if (before.get(path) !== after.get(path)) {
      const id = `file/${path}`
      conflicts.push({ id, label: path, file: path, local: change === null ? '(removed)' : change.encoding === 'utf8' ? change.data.slice(0, 4000) : '(binary file)', remote: after.has(path) ? '(saved file changed; download the saved version to inspect it)' : '(removed)' })
      if (choices[id] === 'remote') continue
    }
    kept[path] = change
  }
  return { changes: kept, conflicts }
}
