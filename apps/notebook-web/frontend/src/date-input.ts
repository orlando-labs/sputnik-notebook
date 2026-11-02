import type { BoardComponent } from './boards'
export function validZone(zone: string) { try { new Intl.DateTimeFormat('en-CA', { timeZone: zone }).format(); return !!zone } catch { return false } }
export function validDate(text: string) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(text) || text.startsWith('0000')) return false
  const date = new Date(text + 'T00:00:00Z'); return Number.isFinite(date.valueOf()) && date.toISOString().slice(0, 10) === text
}
export function validTimestamp(text: string) { return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(text) && validDate(text.slice(0, 10)) && Number.isFinite(Date.parse(text)) && new Date(text).toISOString().replace('.000', '') === text }
export function localTime(instant: string, zone: string) {
  if (!validTimestamp(instant) || !validZone(zone)) return ''
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: zone, calendar: 'gregory', numberingSystem: 'latn', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' }).formatToParts(new Date(instant))
  const get = (type: string) => parts.find(p => p.type === type)!.value.padStart(type === 'year' ? 4 : 2, '0')
  return `${get('year')}-${get('month')}-${get('day')}T${get('hour')}:${get('minute')}:${get('second')}`
}
export function timeCandidates(local: string, zone: string) {
  if (!validZone(zone)) throw new Error('Choose a valid IANA time zone in the designer.')
  if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(local)) local += ':00'
  if (!validTimestamp(local + 'Z')) throw new Error('Enter a complete valid local date and time.')
  const wall = Date.parse(local + 'Z'), offsets = new Set<number>()
  for (let hours = -48; hours <= 48; hours += 6) {
    const probe = wall + hours * 3600000, iso = new Date(probe).toISOString().replace('.000', '')
    if (!validTimestamp(iso)) continue
    offsets.add(Date.parse(localTime(iso, zone) + 'Z') - probe)
  }
  const found = [...offsets].map(offset => new Date(wall - offset).toISOString().replace('.000', '')).filter(iso => validTimestamp(iso) && localTime(iso, zone) === local).sort()
  if (!found.length) throw new Error('This local time does not exist because the clock changes. Choose another time.')
  return found
}
export function dateSettingsError(component: BoardComponent, accepted?: string) {
  const mode = component.date_mode ?? 'date_time', zone = String(component.date_time_zone ?? 'UTC')
  if (!['date', 'date_time'].includes(String(mode)) || !validZone(zone)) return 'Choose a date mode and a valid IANA time zone.'
  if (accepted !== undefined && !(mode === 'date' ? validDate(accepted) : validTimestamp(accepted))) return mode === 'date' ? 'The String default must be a valid YYYY-MM-DD date.' : 'The String default must be a YYYY-MM-DDTHH:MM:SSZ UTC timestamp.'
  return ''
}
