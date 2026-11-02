export type Role = 'owner' | 'editor' | 'viewer'
export interface Project {
  id: string
  title: string
  owner_account_id: string
  role: Role
  permissions: { read: boolean; write: boolean; execute: boolean; manage: boolean }
  created_at: number
  updated_at: number
  import_pending?: boolean
  import_command_id?: string | null
}
export interface Snapshot {
  sign_in_available?: boolean
  public_templates?: { id: string; title: string }[]
  schema: 'notebook.web.v1'
  host: 'server'
  account: { id: string; provider: 'github'; uid: string; login: string; name: string | null } | null
  projects: Project[]
  project: Project | null
  auth_error: boolean
}
export interface Membership { account_id: string; role: 'editor' | 'viewer' }
export class APIError extends Error {
  constructor(message: string, readonly status: number, readonly code = 'request_failed') { super(message) }
}

function project(value: Project): boolean {
  return typeof value?.id === 'string' && typeof value.title === 'string' &&
    typeof value.owner_account_id === 'string' && ['owner', 'editor', 'viewer'].includes(value.role) &&
    ['read', 'write', 'execute', 'manage'].every(key => typeof value.permissions?.[key as keyof Project['permissions']] === 'boolean') &&
    Number.isSafeInteger(value.created_at) && Number.isSafeInteger(value.updated_at)
}
export function snapshot(value: unknown): Snapshot {
  const data = value as Snapshot
  if (data?.schema !== 'notebook.web.v1' || data.host !== 'server' || typeof data.auth_error !== 'boolean' ||
      data.sign_in_available !== undefined && typeof data.sign_in_available !== 'boolean' ||
      data.public_templates !== undefined && (!Array.isArray(data.public_templates) || data.public_templates.length > 16 || !data.public_templates.every(item => typeof item?.id === 'string' && typeof item.title === 'string')) ||
      !Array.isArray(data.projects) || !data.projects.every(project) || (data.project !== null && !project(data.project)) ||
      (data.account !== null && (typeof data.account?.id !== 'string' || data.account.provider !== 'github' ||
        typeof data.account.uid !== 'string' || typeof data.account.login !== 'string' ||
        (data.account.name !== null && typeof data.account.name !== 'string')))) {
    throw new Error('Could not read the notebook session. Reload the page.')
  }
  return data
}
async function responseFor(path: string, method = 'GET', data?: unknown, signal?: AbortSignal): Promise<Response> {
  const headers: Record<string, string> = { Accept: 'application/json' }
  if (method !== 'GET') {
    const token = document.cookie.split('; ').find(value => value.startsWith('orbit-csrf='))?.slice('orbit-csrf='.length)
    if (!token) throw new Error('Reload the page to refresh your session.')
    headers['X-CSRF-Token'] = decodeURIComponent(token)
  }
  if (data !== undefined) headers['Content-Type'] = 'application/json'
  const response = await fetch(path, { method, headers, credentials: 'same-origin', cache: 'no-store', signal,
    body: data === undefined ? undefined : JSON.stringify(data) })
  if (!response.ok) {
    let message = `Request failed (${response.status}).`
    let code = 'request_failed'
    try { const error = (await response.json()).error; message = error?.message || message; code = error?.code || code } catch { /* The server may return plain text. */ }
    throw new APIError(message, response.status, code)
  }
  return response
}
export async function api<T>(path: string, method = 'GET', data?: unknown, signal?: AbortSignal): Promise<T> {
  const response = await responseFor(path, method, data, signal)
  return response.status === 204 ? undefined as T : response.json()
}
export async function apiBlob(path: string, method = 'GET', data?: unknown): Promise<Blob> {
  return (await responseFor(path, method, data)).blob()
}
