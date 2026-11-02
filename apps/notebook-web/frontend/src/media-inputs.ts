import { onMounted, onUnmounted, ref } from 'vue'
import { api, APIError } from './api'
import { newId } from './notebook'
export interface MediaEdit { board_id: string; component_id: string; operation: 'replace' | 'append' | 'clear' | 'annotations'; extension: string; name: string; data: string }
interface Command extends MediaEdit { command_id: string; revision: string; base_version: string }
export interface MediaRuntime { projectId: string; revision: string; readable: boolean; canApply: boolean; version: string; values?: Record<string, string>; apply: (edit: MediaEdit, source?: { revision: string; version: string }) => Promise<boolean> }
const maxBytes = 16 * 1024 * 1024
export async function mediaFile(file: File): Promise<{ data: string; extension: string }> {
  if (!file.size || file.size > maxBytes) throw new Error('Choose a non-empty file up to 16 MiB.')
  const extension = file.name.split('.').at(-1)?.toLowerCase() || ''
  if (!/^[a-z0-9]{1,16}$/.test(extension)) throw new Error('Choose a file with an ordinary extension.')
  if (new TextEncoder().encode(file.name).length > 1024 || /[\x00-\x1f\x7f]/.test(file.name)) throw new Error('The file name is too long or contains control characters.')
  const bytes = new Uint8Array(await file.arrayBuffer())
  let binary = ''; for (let i = 0; i < bytes.length; i += 16384) binary += String.fromCharCode(...bytes.subarray(i, i + 16384))
  return { data: btoa(binary), extension }
}
function journal(key: string, value?: Command | null): Promise<Command | null> {
  return new Promise((resolve, reject) => {
    const open = indexedDB.open('sputnik-media-commands-v1', 1)
    open.onupgradeneeded = () => open.result.createObjectStore('commands')
    open.onerror = () => reject(new Error('Cannot open media command recovery storage.'))
    open.onsuccess = () => {
      const db = open.result, transaction = db.transaction('commands', value === undefined ? 'readonly' : 'readwrite'), store = transaction.objectStore('commands')
      const request = value === undefined ? store.get(key) : value === null ? store.delete(key) : store.put(value, key)
      transaction.oncomplete = () => { db.close(); resolve(value === undefined ? request.result || null : value) }
      transaction.onerror = transaction.onabort = () => { db.close(); reject(new Error('Cannot save media command recovery data.')) }
    }
  })
}
export function useMediaInputs(account: string, project: string, revision: () => string, version: () => string, confirmed: () => Promise<void>) {
  const key = `${account}:${project}`, base = `/api/projects/${encodeURIComponent(project)}/media-inputs`
  const pending = ref<Command | null>(null), busy = ref(false), checking = ref(false), unknown = ref(false), error = ref(''), ready = ref(false)
  let disposed = false
  async function complete() { await journal(key, null); pending.value = null; unknown.value = false; error.value = ''; if (!disposed) await confirmed() }
  async function check() {
    if (!pending.value || checking.value) return
    checking.value = true
    try {
      const result = await api<{ command: { state: string } }>(`${base}/commands/${encodeURIComponent(pending.value.command_id)}`)
      if (result.command.state === 'accepted') await complete()
      else unknown.value = true
    } catch (cause) { error.value = (cause as Error).message }
    finally { checking.value = false }
  }
  async function send(command: Command) {
    if (busy.value) return false
    busy.value = true; error.value = ''; unknown.value = false
    let accepted = false
    try {
      await journal(key, command); pending.value = command
      await api(base, 'POST', command); accepted = true; await complete()
    } catch (cause) {
      error.value = (cause as Error).message
      if (cause instanceof APIError && cause.status < 500) { await journal(key, null); pending.value = null }
      else if (pending.value) { await check(); accepted = pending.value === null }
    } finally { busy.value = false }
    return accepted
  }
  function apply(edit: MediaEdit, source?: { revision: string; version: string }) { return pending.value || !ready.value ? Promise.resolve(false) : send({ ...edit, command_id: newId('media'), revision: source?.revision || revision(), base_version: source?.version || version() }) }
  function retry() { return pending.value && unknown.value ? send(pending.value) : Promise.resolve(false) }
  onMounted(async () => {
    try {
      const saved = await journal(key)
      if (saved) {
        if (typeof saved.command_id !== 'string' || typeof saved.data !== 'string' || saved.data.length > 22369624 || !['replace','append','clear','annotations'].includes(saved.operation)) throw new Error('Invalid pending media command; its recovery data is kept.')
        pending.value = saved; await check()
      }
      ready.value = true
    } catch (cause) { error.value = (cause as Error).message }
  })
  onUnmounted(() => { disposed = true })
  return { pending, busy, checking, unknown, error, ready, apply, check, retry }
}
