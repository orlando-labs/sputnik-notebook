import { computed, onMounted, onUnmounted, ref, watch, type Ref } from 'vue'
import { api, APIError, type Project } from './api'
import { newId, type NotebookDocument } from './notebook'
import type { InputState } from './inputs'
interface Command { cell: string | null; body: { command_id: string; revision: string; base_version: string; values: Record<string, string> } }
export function useInputRuntime(accountId: string, project: () => Project, document: Ref<NotebookDocument | null>, revision: Ref<string>, sheet: Ref<string>, inputVersion: Readonly<Ref<string>>, refreshed: () => Promise<void>, guest = false) {
  const base = `/api/projects/${encodeURIComponent(project().id)}/inputs`
  const key = `sputnik.inputs.pending.v1:${accountId}:${project().id}`
  const states = ref<Record<string, InputState>>({}), error = ref(''), busy = ref(false), loading = ref(false), pending = ref<Command | null>(null), unknown = ref(false)
  const drafts = ref<Record<string, boolean>>({})
  const dirty = computed(() => Object.values(drafts.value).some(Boolean))
  let disposed = false, again = false, refreshPromise: Promise<void> | null = null
  let timer: ReturnType<typeof setTimeout> | undefined
  const controller = new AbortController()
  if (!guest) try { const value = JSON.parse(sessionStorage.getItem(key) || 'null'); if (value && (value.cell === null || typeof value.cell === 'string') && typeof value.body?.command_id === 'string' && typeof value.body.revision === 'string' && typeof value.body.base_version === 'string' && value.body.values && typeof value.body.values === 'object' && Object.values(value.body.values).every(item => typeof item === 'string')) pending.value = value } catch { /* Server receipts remain authoritative. */ }
  function remember(command: Command | null) { clearTimeout(timer); pending.value = command; unknown.value = false; if (guest) return; try { if (command) sessionStorage.setItem(key, JSON.stringify(command)); else sessionStorage.removeItem(key) } catch { /* Optional journal. */ } }
  async function receipt() {
    if (!pending.value) return false
    const result = await api<{ command: { state: string } }>(`${base}/commands/${pending.value.body.command_id}`, 'GET', undefined, controller.signal)
    if (result.command.state === 'accepted') { remember(null); return true }
    unknown.value = true; return false
  }
  async function read() {
    if (!document.value || !revision.value || disposed) return
    const current = revision.value
    const cells = document.value.sheets.find(item => item.id === sheet.value)?.cells.filter(cell => cell.kind === 'code' && !!cell.cell_ui?.inputs.length).map(cell => cell.id) || []
    const scopes = ['project', ...cells]
    for (const key of Object.keys(states.value)) if (!scopes.includes(key)) delete states.value[key]
    let bytes = 0
    // Limit concurrent reads: each response can contain a bounded config form.
    for (let index = 0; index < scopes.length; index += 4) await Promise.all(scopes.slice(index, index + 4).map(async scope => {
      const state = await api<InputState>(base + (scope === 'project' ? '' : `?cell=${encodeURIComponent(scope)}`), 'GET', undefined, controller.signal)
      bytes += new TextEncoder().encode(JSON.stringify(state.values)).length
      if (bytes > 32 * 1024 * 1024) throw new Error('The visible parameter values exceed the 32 MiB display limit.')
      if (!disposed && current === revision.value) states.value[scope] = state
    }))
  }
  function refresh(): Promise<void> {
    if (disposed || !document.value) return Promise.resolve()
    if (refreshPromise) { again = true; return refreshPromise }
    loading.value = true
    refreshPromise = (async () => {
      try { do { again = false; await receipt(); await read() } while (again && !disposed) }
      catch (cause) { if (!disposed) { error.value = cause instanceof Error ? cause.message : 'Could not load accepted parameters.'; if (cause instanceof APIError && [401, 403, 404].includes(cause.status)) states.value = {} } }
      finally { loading.value = false; refreshPromise = null; if (!disposed && pending.value && !window.document.hidden) { clearTimeout(timer); timer = setTimeout(() => { void refresh() }, 1500) } }
    })()
    return refreshPromise
  }
  async function send(command: Command): Promise<boolean> {
    if (busy.value) return false
    busy.value = true; error.value = ''; remember(command)
    let accepted = false
    try { await api(base + (command.cell === null ? '' : `?cell=${encodeURIComponent(command.cell)}`), 'PUT', command.body); accepted = true; remember(null) }
    catch (cause) {
      error.value = cause instanceof Error ? cause.message : 'Could not apply parameters. Your draft is kept.'
      if (cause instanceof APIError && cause.status < 500) remember(null)
      else try { accepted = await receipt() } catch { /* Keep the exact uncertain command. */ }
    } finally {
      if (refreshPromise) await refreshPromise
      await refresh(); await refreshed(); busy.value = false
    }
    if (accepted) error.value = ''
    return accepted
  }
  function apply(cell: string | null, values: Record<string, string>, version: string) {
    if (pending.value) return Promise.resolve(false)
    return send({ cell, body: { command_id: newId('inputs'), revision: revision.value, base_version: version, values } })
  }
  function retry() { return pending.value && unknown.value ? send(pending.value) : Promise.resolve(false) }
  function dirtyForm(id: string, value: boolean) { if (value) drafts.value[id] = true; else delete drafts.value[id] }
  function resetDrafts() { drafts.value = {} }
  watch([revision, sheet, inputVersion], () => { void refresh() })
  function focus() { if (!window.document.hidden) void refresh() }
  onMounted(() => { window.addEventListener('focus', focus); window.document.addEventListener('visibilitychange', focus) })
  onUnmounted(() => { disposed = true; clearTimeout(timer); controller.abort(); window.removeEventListener('focus', focus); window.document.removeEventListener('visibilitychange', focus) })
  return { states, error, busy, loading, pending, unknown, dirty, refresh, apply, retry, dirtyForm, resetDrafts }
}
