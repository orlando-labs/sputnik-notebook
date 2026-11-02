import path from 'node:path'
import { APP, backend, vite, secrets, sourceStamp, sleep, stop } from './common.mjs'

for (const key of ['GITHUB_CLIENT_ID', 'GITHUB_CLIENT_SECRET']) {
  if (!process.env[key]) throw new Error(`Set ${key} for your GitHub OAuth App; see README.md.`)
}
const env = { ...await secrets(), ...process.env, ORBIT_MODE: 'development' }
env.SPUTNIK_VM_CACHE ||= path.join(APP, 'build/dev-vm-cache')
console.log(`Sputnik Notebook: ${env.ORBIT_ORIGIN || 'http://127.0.0.1:3000'}`)
let ending = false
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { ending = true })
const frontend = vite(env)
let server = backend(path.join(APP, 'backend/main.s'), [], env)
try {
  let stamp = await sourceStamp(env.SPUTNIK_VM_CACHE)
  while (!ending) {
    await sleep(500)
    if (frontend.exitCode !== null || frontend.signalCode !== null) throw new Error('Vite stopped')
    const next = await sourceStamp(env.SPUTNIK_VM_CACHE)
    if (stamp !== next) {
      await stop(server)
      stamp = next
      server = backend(path.join(APP, 'backend/main.s'), [], env)
    }
  }
} finally {
  await stop(server)
  await stop(frontend)
}
