// Development-only same-origin entry for Vite's cross-origin module server.
// The response retains the application's CSP, including its configured Vite origin.
const source = new URL(new URL(self.location.href).searchParams.get('source'))
if (!['http:', 'https:'].includes(source.protocol) || source.pathname !== '/src/audio-analysis-worker.ts' || source.username || source.password || source.hash || source.search !== '?worker_file&type=module') throw new Error('Invalid audio analysis module')
const pending = []
self.onmessage = event => pending.push(event)
await import(source.href)
for (const event of pending) self.onmessage(event)
