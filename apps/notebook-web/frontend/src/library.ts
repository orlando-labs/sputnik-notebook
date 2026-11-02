// Browser preferences mirror the desktop library, scoped to the signed-in account.
// A server timestamp is never presented as a notebook's last-opened time.
export type LibrarySort = 'lastOpened' | 'created' | 'name'
interface Preferences {
  sort: LibrarySort
  expanded: boolean
  lastOpened: Record<string, number>
}
const key = (accountId: string) => `sputnik.notebook.library.v1:${accountId}`

export function readLibrary(accountId: string): Preferences {
  const fallback: Preferences = { sort: 'lastOpened', expanded: true, lastOpened: {} }
  try {
    const saved = JSON.parse(localStorage.getItem(key(accountId)) || 'null')
    if (!saved || typeof saved !== 'object') return fallback
    return {
      sort: ['lastOpened', 'created', 'name'].includes(saved.sort) ? saved.sort : fallback.sort,
      expanded: typeof saved.expanded === 'boolean' ? saved.expanded : true,
      lastOpened: Object.fromEntries(Object.entries(saved.lastOpened || {}).filter(
        ([, time]) => typeof time === 'number' && Number.isSafeInteger(time) && time > 0,
      )) as Record<string, number>,
    }
  } catch { return fallback }
}

export function saveLibrary(accountId: string, preferences: Preferences) {
  try { localStorage.setItem(key(accountId), JSON.stringify(preferences)) }
  catch { /* The library remains usable when browser storage is unavailable. */ }
}

export function recordOpened(accountId: string, projectId: string) {
  const preferences = readLibrary(accountId)
  preferences.lastOpened[projectId] = Date.now()
  saveLibrary(accountId, preferences)
}

export function formatDate(seconds: number) {
  return new Date(seconds * 1000).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })
}
