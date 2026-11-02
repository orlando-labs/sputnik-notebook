import { parseNotebook } from './notebook'
import type { FileEdit } from './sources'

export interface SaveCommand { command_id: string; base_revision: string; document: string; changes: Record<string, FileEdit | null> }
export interface DraftRecord {
  id: string; account: string; project: string; updated: number; base_revision: string; base_document: string
  document: string; changes: Record<string, FileEdit | null>; pending: SaveCommand | null
  sheet: string; file: string; board: string
}
const lifetime = 30 * 86400000
export const journalLimit = 96 * 1024 * 1024
function base64(value: string) {
  if (value.length > 22369624 || value.length % 4 || /[^A-Za-z0-9+/=]/.test(value)) return false
  const padding = value.endsWith('==') ? 2 : value.endsWith('=') ? 1 : 0
  return !value.slice(0, value.length - padding).includes('=') && value.length / 4 * 3 - padding <= 16777216
}
let connection: Promise<IDBDatabase> | undefined
function database() {
  return connection ||= new Promise((resolve, reject) => {
    const request = indexedDB.open('sputnik-notebook-drafts-v1', 1)
    request.onupgradeneeded = () => { request.result.createObjectStore('drafts', { keyPath: 'id' }).createIndex('scope', ['account', 'project']) }
    request.onsuccess = () => { request.result.onversionchange = () => { request.result.close(); connection = undefined }; resolve(request.result) }
    request.onerror = () => { connection = undefined; reject(new Error('Local draft storage is unavailable. Export your draft before leaving.')) }
    request.onblocked = () => reject(new Error('Local draft storage is blocked by another tab.'))
  })
}
export function validDraft(value: DraftRecord, account: string, project: string): boolean {
  try {
    if (!value || value.account !== account || value.project !== project || typeof value.id !== 'string' || !Number.isFinite(value.updated) || value.updated < Date.now() - lifetime || value.updated > Date.now() + 60000) return false
    if (typeof value.document !== 'string' || typeof value.base_document !== 'string' || typeof value.sheet !== 'string' || typeof value.file !== 'string' || typeof value.board !== 'string') return false
    parseNotebook({ revision: value.base_revision, document: value.document }); parseNotebook({ revision: value.base_revision, document: value.base_document })
    const edits = (changes: Record<string, FileEdit | null>) => changes && typeof changes === 'object' && !Array.isArray(changes) && Object.entries(changes).length <= 2048 && Object.entries(changes).every(([path, edit]) =>
      !!path && new TextEncoder().encode(path).length <= 1024 && path.toLowerCase() !== 'project.json' && !/[\x00-\x1f\x7f\\:]/.test(path) && !path.startsWith('/') && path.split('/').every(part => !!part && part !== '.' && part !== '..') &&
      (edit === null || (edit && typeof edit.data === 'string' && (edit.encoding === 'utf8' ? new TextEncoder().encode(edit.data).length <= 1048576 : edit.encoding === 'base64' && base64(edit.data)))))
    if (!edits(value.changes)) return false
    if (value.pending && (!/^[a-zA-Z0-9_-]{1,128}$/.test(value.pending.command_id) || value.pending.base_revision !== value.base_revision || typeof value.pending.document !== 'string' || !edits(value.pending.changes))) return false
    if (value.pending) parseNotebook({ revision: value.base_revision, document: value.pending.document })
    return new Blob([JSON.stringify(value)]).size <= journalLimit
  } catch { return false }
}
export async function localDrafts(account: string, project: string) {
  const db = await database()
  return new Promise<DraftRecord[]>((resolve, reject) => {
    const transaction = db.transaction('drafts', 'readwrite'), store = transaction.objectStore('drafts')
    const request = store.index('scope').getAll(IDBKeyRange.only([account, project]))
    let records: DraftRecord[] = []
    request.onsuccess = () => {
      records = request.result.filter(value => validDraft(value, account, project)).sort((a, b) => b.updated - a.updated)
      for (const value of request.result) if (!records.includes(value)) store.delete(value.id)
    }
    transaction.oncomplete = () => resolve(records)
    transaction.onerror = () => reject(new Error('Could not read local drafts.'))
    transaction.onabort = () => reject(new Error('Could not read local drafts.'))
  })
}
export async function writeDraft(record: DraftRecord | null, id: string) {
  if (record && !validDraft(record, record.account, record.project)) throw new Error('This draft exceeds local recovery limits. Export it before leaving.')
  const db = await database()
  return new Promise<void>((resolve, reject) => {
    const transaction = db.transaction('drafts', 'readwrite'), store = transaction.objectStore('drafts')
    let full = false
    if (record) {
      const key = store.getKey(record.id)
      key.onsuccess = () => {
        if (key.result) store.put(record)
        else {
          const count = store.index('scope').count(IDBKeyRange.only([record.account, record.project]))
          count.onsuccess = () => { if (count.result >= 16) { full = true; transaction.abort() } else store.put(record) }
        }
      }
    } else store.delete(id)
    transaction.oncomplete = () => resolve()
    transaction.onerror = () => reject(new Error('Could not keep a local recovery copy. Export your draft before leaving.'))
    transaction.onabort = () => reject(new Error(full ? 'There are already 16 local drafts for this project. Export or delete an older copy to keep another.' : 'Local draft storage is full or unavailable. Export your draft before leaving.'))
  })
}
export async function removeDraft(record: DraftRecord) {
  const db = await database()
  return new Promise<void>((resolve, reject) => {
    const transaction = db.transaction('drafts', 'readwrite'), store = transaction.objectStore('drafts'), request = store.get(record.id)
    request.onsuccess = () => { if (request.result?.updated === record.updated && JSON.stringify(request.result) === JSON.stringify(record)) store.delete(record.id) }
    transaction.oncomplete = () => resolve()
    transaction.onerror = () => reject(new Error('Could not remove this local recovery copy.'))
    transaction.onabort = () => reject(new Error('Could not remove this local recovery copy.'))
  })
}
