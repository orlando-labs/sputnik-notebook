import { computed, onUnmounted, ref, watch, type Ref } from 'vue'
import { api, apiBlob, type Project } from './api'
import { download } from './rich'
import type { NotebookDocument } from './notebook'

export interface FileEdit { encoding: 'utf8' | 'base64'; data: string }
export interface ProjectFile { path: string; size: number; digest: string; kind: 'module' | 'dependency' | 'resource'; module_id: string | null }
export interface FileView { revision: string; path: string; size: number; text: string | null; preview: string | null; editable: boolean; truncated: boolean; draft?: boolean }
const encoder = new TextEncoder()
const moduleIDPattern = /^[A-Za-z_][A-Za-z0-9_]{0,63}$/
const moduleFilename = /[^/]*(\.(?:s|spu|sputnik))$/
export function moduleIDFromName(name: string) {
  const id = name.trim().replace(/[\s-]+/g, '_')
  return moduleIDPattern.test(id) ? id : null
}
export function modulePathForID(path: string, id: string) {
  return path.replace(moduleFilename, (_filename, extension: string) => id + extension)
}
export function memberPath(path: string) {
  return !!path && encoder.encode(path).length <= 1024 && path.toLowerCase() !== 'project.json' && !/[\x00-\x1f\x7f\\:]/.test(path) && !path.startsWith('/') && path.split('/').every(part => !!part && part !== '.' && part !== '..')
}
export function fileBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(String(reader.result).slice(String(reader.result).indexOf(',') + 1))
    reader.onerror = () => reject(new Error(`Could not read ${file.name}.`))
    reader.readAsDataURL(file)
  })
}
export const archiveName = (title: string) => `${title.replace(/[\x00-\x1f\x7f/\\:*?"<>|]/g, '_').slice(0, 120) || 'Notebook'}.sputnikbook.zip`
export function useSources(project: () => Project, document: Ref<NotebookDocument | null>, revision: Ref<string>) {
  const base = `/api/projects/${encodeURIComponent(project().id)}/notebook`
  const selected = ref('')
  const entries = ref<ProjectFile[]>([])
  const changes = ref<Record<string, FileEdit | null>>(Object.create(null))
  const cache = ref<Record<string, FileView>>(Object.create(null))
  const indexBusy = ref(false)
  const fileBusy = ref(false)
  const error = ref('')
  const ready = ref(false)
  const controller = new AbortController()
  let generation = 0, disposed = false
  const dirty = computed(() => Object.keys(changes.value).length > 0)
  const files = computed(() => {
    const values = new Map(entries.value.map(entry => [entry.path, entry]))
    for (const [path, edit] of Object.entries(changes.value)) {
      if (edit === null) { values.delete(path); continue }
      const module = document.value?.modules?.find(module => module.path === path)
      values.set(path, { path, size: edit.encoding === 'utf8' ? encoder.encode(edit.data).length : Math.floor(edit.data.length * .75), digest: '',
        kind: module ? 'module' : ['requirements.txt', 'requirements.lock', 'Gemfile', 'Gemfile.lock'].includes(path) ? 'dependency' : 'resource', module_id: module?.id || null })
    }
    return [...values.values()].map(file => {
      const module = document.value?.modules?.find(module => module.path === file.path)
      return { ...file, kind: module ? 'module' as const : file.kind === 'module' ? 'resource' as const : file.kind, module_id: module?.id || null }
    }).sort((a, b) => a.path.localeCompare(b.path))
  })
  const view = computed<FileView | null>(() => {
    const original = cache.value[selected.value]
    const edit = changes.value[selected.value]
    if (edit?.encoding === 'utf8') return { revision: revision.value, path: selected.value, size: encoder.encode(edit.data).length, text: edit.data, preview: edit.data, editable: true, truncated: false }
    if (edit?.encoding === 'base64' && !original) {
      const bytes = Uint8Array.from(atob(edit.data), char => char.charCodeAt(0))
      let text: string | null = null
      if (bytes.length <= 1048576) try { const decoded = new TextDecoder('utf-8', { fatal: true }).decode(bytes); if (!decoded.includes('\0')) text = decoded } catch { /* Binary member. */ }
      return { revision: revision.value, path: selected.value, size: bytes.length, text, preview: text, editable: text !== null, truncated: false, draft: true }
    }
    return original || null
  })
  async function index() {
    if (!revision.value || !document.value) return
    const version = revision.value, own = ++generation
    indexBusy.value = true; error.value = ''
    try {
      const result = await api<{ revision: string; entries: ProjectFile[] }>(`${base}/files?revision=${version}`, 'GET', undefined, controller.signal)
      if (!disposed && own === generation && version === revision.value) { entries.value = result.entries; ready.value = true }
    } catch (cause) { if (!disposed && own === generation) error.value = cause instanceof Error ? cause.message : 'Could not load project files.' }
    finally { if (own === generation) indexBusy.value = false }
  }
  async function open(path: string) {
    selected.value = path; error.value = ''
    if (cache.value[path] || changes.value[path]) return
    const version = revision.value
    fileBusy.value = true
    try {
      const result = await api<FileView>(`${base}/file?revision=${version}&path=${encodeURIComponent(path)}`, 'GET', undefined, controller.signal)
      if (!disposed && version === revision.value) cache.value[path] = result
    } catch (cause) { if (!disposed) error.value = cause instanceof Error ? cause.message : 'Could not open project file.' }
    finally { if (!disposed) fileBusy.value = false }
  }
  function text(value: string) {
    if (!selected.value || encoder.encode(value).length > 1048576) { error.value = 'Text files are limited to 1 MiB.'; return }
    const path = selected.value
    if (!cache.value[path]?.draft && cache.value[path]?.text === value && entries.value.some(item => item.path === path)) delete changes.value[path]
    else changes.value[path] = { encoding: 'utf8', data: value }
  }
  function addModule(id: string) {
    if (!document.value || !moduleIDPattern.test(id)) throw new Error('Use a module name with letters, digits and underscores.')
    const path = `modules/${id}.s`
    if (document.value.modules?.some(module => module.id === id) || files.value.some(file => file.path.toLowerCase() === path.toLowerCase())) throw new Error('This module or file already exists.')
    document.value.modules ||= []
    document.value.modules.push({ id, path })
    changes.value[path] = { encoding: 'utf8', data: `package ${id}\n\n` }
    selected.value = path
  }
  async function upload(file: File, path: string) {
    if (!memberPath(path)) throw new Error('Use a relative project file path without traversal.')
    if (file.size > 16 * 1024 * 1024) throw new Error('Files are limited to 16 MiB.')
    const similar = files.value.find(item => item.path.toLowerCase() === path.toLowerCase())
    if (similar && similar.path !== path) throw new Error('A file already exists with a different letter case.')
    if (similar && !window.confirm(`Replace ${path} in your draft?`)) return false
    const data = await fileBase64(file)
    changes.value[path] = { encoding: 'base64', data }
    let text: string | null = null
    if (file.size <= 1048576) try { const value = new TextDecoder('utf-8', { fatal: true }).decode(await file.arrayBuffer()); if (!value.includes('\0')) text = value } catch { /* Binary file. */ }
    cache.value[path] = { revision: revision.value, path, size: file.size, text, preview: text, editable: text !== null, truncated: false, draft: true }
    selected.value = path
    return true
  }
  function remove() {
    if (!document.value || !selected.value) return
    const path = selected.value, linked = document.value.modules?.find(module => module.path === path)
    if (!window.confirm(`Remove ${linked ? 'module' : 'file'} ${linked?.id || path} and its contents from this notebook?`)) return
    if (linked) {
      document.value.modules = document.value.modules!.filter(module => module.path !== path)
      document.value.auto_imports = document.value.auto_imports?.filter(id => id !== linked.id)
    }
    if (entries.value.some(entry => entry.path === path)) changes.value[path] = null
    else delete changes.value[path]
    delete cache.value[path]; selected.value = ''
  }
  function autoImport(enabled: boolean) {
    const module = document.value?.modules?.find(module => module.path === selected.value)
    if (!module || !document.value) return
    const values = new Set(document.value.auto_imports || [])
    if (enabled) values.add(module.id); else values.delete(module.id)
    document.value.auto_imports = [...values]
  }
  async function relocate(path: string, moduleName?: string) {
    const from = selected.value, version = revision.value, targetDocument = document.value
    if (!targetDocument || !from || !ready.value) throw new Error('Open a file before moving it.')
    const linked = targetDocument.modules?.find(module => module.path === from)
    const moduleID = moduleIDFromName(moduleName ?? '')
    if (linked) {
      if (!moduleID) throw new Error('Use a module name that starts with a letter or underscore and contains only letters, digits, spaces, hyphens and underscores.')
      if (!moduleFilename.test(path)) throw new Error('Use a .s, .spu or .sputnik path for a module.')
      if (targetDocument.modules?.some(module => module !== linked && module.id === moduleID)) throw new Error('This module name already exists.')
      path = modulePathForID(path, moduleID)
    }
    if (!memberPath(path)) throw new Error('Use a relative project file path without traversal.')
    const lower = path.toLowerCase()
    if (files.value.some(file => file.path !== from && (file.path.toLowerCase() === lower || file.path.toLowerCase().startsWith(lower + '/') || lower.startsWith(file.path.toLowerCase() + '/')))) throw new Error('The destination conflicts with another project file.')
    // A saved deletion at the destination would otherwise be lost on rename.
    if (path !== from && changes.value[path] !== undefined) throw new Error('Save the existing change at the destination before moving another file there.')
    let edit = changes.value[from]
    if (!edit) {
      const blob = await apiBlob(`${base}/download?revision=${version}&path=${encodeURIComponent(from)}`)
      if (blob.size > 16777216) throw new Error('Files are limited to 16 MiB.')
      edit = { encoding: 'base64', data: await fileBase64(new File([blob], from.split('/').at(-1)!)) }
    }
    if (disposed || revision.value !== version || document.value !== targetDocument || selected.value !== from) throw new Error('The notebook changed while reading the file. Try again.')
    if (linked && moduleID && linked.id !== moduleID) {
      const text = edit.encoding === 'utf8' ? edit.data : new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(atob(edit.data), char => char.charCodeAt(0)))
      const renamed = text.replace(new RegExp(`^(\\s*package[ \\t]+)${linked.id}\\b`, 'm'), `$1${moduleID}`)
      if (encoder.encode(renamed).length > 1048576) throw new Error('Renaming a module requires a UTF-8 source within 1 MiB.')
      edit = { encoding: 'utf8', data: renamed }
    }
    if (path === from && (!linked || linked.id === moduleID)) return
    if (path !== from) {
      if (entries.value.some(entry => entry.path === from)) changes.value[from] = null
      else delete changes.value[from]
      delete cache.value[from]
    }
    changes.value[path] = edit
    if (linked && moduleID) {
      const old = linked.id
      linked.path = path; linked.id = moduleID
      targetDocument.auto_imports = targetDocument.auto_imports?.map(id => id === old ? moduleID : id)
      const visit = (components: import('./boards').BoardComponent[]) => {
        for (const component of components) {
          if (['action', 'periodic_work'].includes(component.kind) && component.module_id === old) component.module_id = moduleID
          for (const panel of component.panels || []) visit(panel.components)
        }
      }
      for (const board of targetDocument.boards || []) visit(board.components)
      for (const sheet of targetDocument.sheets) for (const cell of sheet.cells) {
        if (cell.cell_ui) { visit(cell.cell_ui.pre); visit(cell.cell_ui.post) }
      }
    }
    selected.value = path
  }
  function restore(edits: Record<string, FileEdit | null>, path = '') {
    reset(); changes.value = Object.assign(Object.create(null), JSON.parse(JSON.stringify(edits))); selected.value = path
    void index()
    if (path) void open(path)
  }
  function reset(keepSelection = false) {
    changes.value = Object.create(null); cache.value = Object.create(null); entries.value = []; ready.value = false
    if (!keepSelection) selected.value = ''
  }
  async function downloadFile() {
    const path = selected.value, edit = changes.value[path]
    if (edit) {
      const data = edit.encoding === 'utf8' ? new Blob([edit.data]) : new Blob([Uint8Array.from(atob(edit.data), value => value.charCodeAt(0))])
      download(data, path.split('/').at(-1)!)
    } else download(await apiBlob(`${base}/download?revision=${revision.value}&path=${encodeURIComponent(path)}`), path.split('/').at(-1)!)
  }
  async function archive(target = revision.value) { download(await apiBlob(`${base}/archive?revision=${target}`), archiveName(project().title)) }
  watch(revision, () => { cache.value = Object.create(null); void index(); if (selected.value && changes.value[selected.value] === undefined) void open(selected.value) })
  onUnmounted(() => { disposed = true; controller.abort() })
  return { selected, entries, files, changes, view, dirty, indexBusy, fileBusy, ready, error, index, open, text, addModule, upload, remove, autoImport, relocate, restore, reset, downloadFile, archive }
}
