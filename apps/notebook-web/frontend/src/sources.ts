import { computed, onUnmounted, ref, watch, type Ref } from 'vue'
import { api, apiBlob, type Project } from './api'
import { download } from './rich'
import type { NotebookDocument } from './notebook'
import { base64ByteLength, guestUpload } from './upload-limits'

export interface FileEdit { encoding: 'utf8' | 'base64'; data: string }
export interface ProjectFile { path: string; size: number; digest: string; kind: 'module' | 'dependency' | 'resource'; module_id: string | null }
export interface FileView { revision: string; path: string; size: number; text: string | null; preview: string | null; editable: boolean; truncated: boolean; draft?: boolean }
const encoder = new TextEncoder()
const moduleIDPattern = /^[A-Za-z_][A-Za-z0-9_]{0,63}$/
const moduleFilename = /[^/]*(\.(?:s|spu|sputnik))$/
const memberLimit = 16 * 1024 * 1024
const bundleLimit = 64 * 1024 * 1024
export const markdownDocument = (path: string) => path.startsWith('docs/') && /\.md$/i.test(path)
export const attachment = (file: ProjectFile) => file.kind === 'resource' && !markdownDocument(file.path)
const editSize = (edit: FileEdit) => edit.encoding === 'utf8' ? encoder.encode(edit.data).length : base64ByteLength(edit.data)
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
export function useSources(project: () => Project, document: Ref<NotebookDocument | null>, revision: Ref<string>, guest = false) {
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
  const fileLimit = guest ? guestUpload.fileBytes : memberLimit
  const fileLabel = guest ? guestUpload.fileLabel : '16 MiB'
  const textLimit = guest ? guestUpload.fileBytes : 1048576
  const textLabel = guest ? guestUpload.fileLabel : '1 MiB'
  const files = computed(() => {
    const values = new Map(entries.value.map(entry => [entry.path, entry]))
    for (const [path, edit] of Object.entries(changes.value)) {
      if (edit === null) { values.delete(path); continue }
      const module = document.value?.modules?.find(module => module.path === path)
      values.set(path, { path, size: editSize(edit), digest: '',
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
    if (edit?.encoding === 'base64') {
      const size = base64ByteLength(edit.data)
      let text: string | null = null
      if (size <= 1048576) try {
        const decoded = new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(atob(edit.data), char => char.charCodeAt(0)))
        if (!decoded.includes('\0')) text = decoded
      } catch { /* Binary member. */ }
      return { revision: revision.value, path: selected.value, size, text, preview: text, editable: text !== null, truncated: false, draft: true }
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
    if (!selected.value) return
    const size = encoder.encode(value).length
    if (size > textLimit) { error.value = `Text files are limited to ${textLabel}.`; return }
    const path = selected.value
    if (!cache.value[path]?.draft && cache.value[path]?.text === value && entries.value.some(item => item.path === path)) delete changes.value[path]
    else {
      try { verifyGuestBatch([{ path, size }]) }
      catch (cause) { error.value = (cause as Error).message; return }
      changes.value[path] = { encoding: 'utf8', data: value }
    }
    error.value = ''
  }
  function addModule(id: string) {
    if (!document.value || !moduleIDPattern.test(id)) throw new Error('Use a module name with letters, digits and underscores.')
    const path = `modules/${id}.s`
    if (document.value.modules?.some(module => module.id === id) || files.value.some(file => file.path.toLowerCase() === path.toLowerCase())) throw new Error('This module or file already exists.')
    const edit: FileEdit = { encoding: 'utf8', data: `package ${id}\n\n` }
    verifyGuestBatch([{ path, size: editSize(edit) }])
    document.value.modules ||= []
    document.value.modules.push({ id, path })
    changes.value[path] = edit
    selected.value = path
  }
  function verifyMembers(incoming: { path: string; size: number }[], excluded = new Set<string>()) {
    if (incoming.some(file => file.size > fileLimit)) throw new Error(`Files are limited to ${fileLabel} each.`)
    verifyGuestBatch(incoming, excluded)
    const existing = files.value.filter(file => !excluded.has(file.path))
    if (existing.length + incoming.length > 2048 || [...existing, ...incoming].reduce((sum, file) => sum + file.size, 0) > bundleLimit)
      throw new Error('A notebook accepts up to 2048 files and 64 MiB of bundled data.')
    const paths = new Set(existing.map(file => file.path.toLowerCase()))
    for (const { path } of incoming) {
      if (!memberPath(path)) throw new Error('Use a relative project file path without traversal.')
      const lower = path.toLowerCase()
      if ([...paths].some(other => other === lower || other.startsWith(lower + '/') || lower.startsWith(other + '/')))
        throw new Error(`The destination conflicts with a project file: ${path}`)
      paths.add(lower)
    }
  }
  function verifyGuestBatch(incoming: { path: string; size: number }[], excluded = new Set<string>()) {
    if (!guest) return
    const replaced = new Set([...excluded, ...incoming.map(file => file.path)])
    const staged = files.value.filter(file => changes.value[file.path] && !replaced.has(file.path))
    const size = [...staged, ...incoming].reduce((total, file) => total + file.size, 0)
    if (size > guestUpload.batchBytes) throw new Error(`Save up to ${guestUpload.batchLabel} of file changes at a time.`)
  }
  function addDocument(name: string) {
    const path = 'docs/' + (/\.md$/i.test(name) ? name : name + '.md')
    if (!name || name.includes('/') || name === '.' || name === '..') throw new Error('Enter a Markdown filename.')
    verifyMembers([{ path, size: 0 }])
    changes.value[path] = { encoding: 'utf8', data: '' }
    selected.value = path
  }
  async function upload(file: File, path: string) {
    const similar = files.value.find(item => item.path.toLowerCase() === path.toLowerCase())
    verifyMembers([{ path, size: file.size }], new Set([path]))
    if (similar && !window.confirm(`Replace ${path} in your draft?`)) return false
    const data = await fileBase64(file)
    changes.value[path] = { encoding: 'base64', data }
    selected.value = path
    return true
  }
  async function uploadFolder(items: File[], parent: string) {
    if (!items.length) throw new Error('Choose a folder containing files.')
    const root = items[0]!.webkitRelativePath.split('/')[0]
    if (!root || items.some(item => !item.webkitRelativePath.startsWith(root + '/'))) throw new Error('Choose one folder to attach.')
    const incoming = items.map(file => ({ file, path: parent + '/' + file.webkitRelativePath, size: file.size }))
    verifyMembers(incoming)
    const staged: Record<string, FileEdit> = Object.create(null)
    for (const { file, path } of incoming) staged[path] = { encoding: 'base64', data: await fileBase64(file) }
    if (!disposed) Object.assign(changes.value, staged)
  }
  function stageRemoval(path: string) {
    if (entries.value.some(entry => entry.path === path)) changes.value[path] = null
    else delete changes.value[path]
    delete cache.value[path]
  }
  function remove() {
    if (!document.value || !selected.value) return
    const path = selected.value, linked = document.value.modules?.find(module => module.path === path)
    if (!window.confirm(`Remove ${linked ? 'module' : 'file'} ${linked?.id || path} and its contents from this notebook?`)) return
    if (linked) {
      document.value.modules = document.value.modules!.filter(module => module.path !== path)
      document.value.auto_imports = document.value.auto_imports?.filter(id => id !== linked.id)
    }
    stageRemoval(path)
    selected.value = ''
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
    if (markdownDocument(from) && !markdownDocument(path)) throw new Error('Keep Markdown documents in docs/ with a .md extension.')
    const lower = path.toLowerCase()
    if (files.value.some(file => file.path !== from && (file.path.toLowerCase() === lower || file.path.toLowerCase().startsWith(lower + '/') || lower.startsWith(file.path.toLowerCase() + '/')))) throw new Error('The destination conflicts with another project file.')
    // A saved deletion at the destination would otherwise be lost on rename.
    if (path !== from && changes.value[path] !== undefined) throw new Error('Save the existing change at the destination before moving another file there.')
    let edit = changes.value[from]
    if (!edit) {
      const blob = await apiBlob(`${base}/download?revision=${version}&path=${encodeURIComponent(from)}`)
      if (blob.size > fileLimit) throw new Error(`Files are limited to ${fileLabel} each.`)
      edit = { encoding: 'base64', data: await fileBase64(new File([blob], from.split('/').at(-1)!)) }
    }
    if (disposed || revision.value !== version || document.value !== targetDocument || selected.value !== from) throw new Error('The notebook changed while reading the file. Try again.')
    if (linked && moduleID && linked.id !== moduleID) {
      const text = edit.encoding === 'utf8' ? edit.data : new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(atob(edit.data), char => char.charCodeAt(0)))
      const renamed = text.replace(new RegExp(`^(\\s*package[ \\t]+)${linked.id}\\b`, 'm'), `$1${moduleID}`)
      if (encoder.encode(renamed).length > textLimit) throw new Error(`Renaming a module requires a UTF-8 source within ${textLabel}.`)
      edit = { encoding: 'utf8', data: renamed }
    }
    if (path === from && (!linked || linked.id === moduleID)) return
    verifyGuestBatch([{ path, size: editSize(edit) }], new Set([from]))
    if (path !== from) stageRemoval(from)
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
  function folderMembers(path: string) {
    const members = files.value.filter(file => file.path.startsWith(path + '/'))
    if (!path || !members.length || members.some(file => !attachment(file))) throw new Error('Choose a folder containing only attachments.')
    return members
  }
  function removeFolder(path: string) {
    const members = folderMembers(path)
    if (!window.confirm(`Remove ${path} and its ${members.length} files from this notebook?`)) return
    for (const file of members) stageRemoval(file.path)
    if (selected.value.startsWith(path + '/')) selected.value = ''
  }
  async function moveFolder(from: string, to: string) {
    if (from === to) return
    if (!memberPath(to) || to.toLowerCase().startsWith(from.toLowerCase() + '/'))
      throw new Error('Choose a destination outside the folder.')
    const members = folderMembers(from), version = revision.value
    const moved = members.map(file => ({ ...file, path: to + file.path.slice(from.length), original: file.path }))
    if (moved.some(file => !attachment(file) || changes.value[file.path] !== undefined))
      throw new Error('The destination conflicts with documentation or an existing draft.')
    verifyMembers(moved, new Set(moved.map(file => file.original)))
    const staged: Record<string, FileEdit> = Object.create(null)
    for (const file of moved) {
      const edit = changes.value[file.original]
      if (edit) staged[file.path] = edit
      else {
        const blob = await apiBlob(`${base}/download?revision=${version}&path=${encodeURIComponent(file.original)}`)
        staged[file.path] = { encoding: 'base64', data: await fileBase64(new File([blob], file.path.split('/').at(-1)!)) }
      }
    }
    if (disposed || revision.value !== version) throw new Error('The notebook changed while reading the folder. Try again.')
    for (const file of moved) stageRemoval(file.original)
    Object.assign(changes.value, staged)
    if (selected.value.startsWith(from + '/')) selected.value = to + selected.value.slice(from.length)
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
  return { selected, entries, files, changes, view, dirty, indexBusy, fileBusy, ready, error, index, open, text, addModule, addDocument, upload, uploadFolder, remove, removeFolder, moveFolder, autoImport, relocate, restore, reset, downloadFile, archive }
}
