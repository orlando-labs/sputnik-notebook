// Check the real application entry without sending requests to GitHub or core.
import { spawn } from 'node:child_process'
import net from 'node:net'
import { mkdtemp, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import assert from 'node:assert/strict'
import { APP, backend, stop, sleep } from './common.mjs'

const root = await mkdtemp(path.join(os.tmpdir(), 'notebook-web-main-'))
const listener = net.createServer()
await new Promise(resolve => listener.listen(0, '127.0.0.1', resolve))
const port = listener.address().port
await new Promise(resolve => listener.close(resolve))
const origin = `http://127.0.0.1:${port}`
const env = { ...process.env, ORBIT_ORIGIN: origin, ORBIT_PORT: String(port), NOTEBOOK_WEB_DATABASE: path.join(root, 'catalog.sqlite'),
  GITHUB_CLIENT_ID: 'not-used', GITHUB_CLIENT_SECRET: 'not-used', ORBIT_SESSION_SECRET: 'main-test-session-secret-at-least-32-bytes',
  ORBIT_CSRF_SECRET: 'main-test-csrf-secret-at-least-32-bytes', NOTEBOOK_CORE_ROOT: path.join(root, 'unstarted-core') }
const args = ['--mode', 'development']
const native = process.argv.includes('--native')
const server = native
  ? spawn(path.join(APP, 'build/native/notebook-web'), args, { cwd: APP, env, stdio: ['ignore', 'pipe', 'pipe'], detached: process.platform !== 'win32' })
  : backend('backend/main.s', args, env, ['ignore', 'pipe', 'pipe'])
let output = ''
server.stdout.on('data', value => { output += value })
server.stderr.on('data', value => { output += value })
try {
  let response
  for (let attempt = 0; attempt < 300; attempt++) {
    assert.equal(server.exitCode, null, output)
    try { response = await fetch(origin + '/api/session', { headers: { Accept: 'application/json' } }); break }
    catch { await sleep(100) }
  }
  assert.ok(response, 'main startup timed out\n' + output)
  assert.equal(response.status, 200, await response.clone().text())
  const data = await response.json()
  assert.equal(data.schema, 'notebook.web.v1')
  assert.equal(data.account, null)
  assert.deepEqual(data.projects, [])
  console.log(`PASS notebook-web real entry (${native ? 'full-native' : 'VM'}), lazy core client, empty private catalog`)
} finally { await stop(server); await rm(root, { recursive: true, force: true }) }
