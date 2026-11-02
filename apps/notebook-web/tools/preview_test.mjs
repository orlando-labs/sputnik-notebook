import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { mkdtemp, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import net from 'node:net'
import { APP, backend, stop, sleep, COMPILER } from './common.mjs'
const root = await mkdtemp(path.join(os.tmpdir(), 'notebook-preview-'))
const core = path.join(root, 'core')
const agent = spawn(path.resolve(APP, '../../build/sputnik-notebook-remote'), ['--mode', 'agent', '--root', core, '--worker', path.resolve(APP, '../../build/sputnik-notebook-worker')], { stdio: ['ignore', 'pipe', 'pipe'], detached: true })
let output = ''
agent.stdout.on('data', data => output += data)
agent.stderr.on('data', data => output += data)
const rpc = (method, params = {}) => new Promise((resolve, reject) => {
  const socket = net.createConnection(path.join(core, 'agent.sock'))
  let body = ''
  socket.on('error', reject)
  socket.on('connect', () => socket.write(JSON.stringify({ method, params }) + '\n'))
  socket.on('data', data => { body += data; if (body.includes('\n')) { socket.end(); resolve(JSON.parse(body.split('\n')[0])) } })
})
try {
  for (let i = 0; i < 300; i++) {
    assert.equal(agent.exitCode, null, output)
    try { if ((await rpc('health')).status === 200) break } catch {}
    await sleep(100)
  }
  const args = ['--database', path.join(root, 'web.sqlite'), '--core-root', core]
  let child
  if (process.argv.includes('--native')) {
    const target = path.join(APP, 'build/preview-native/preview')
    const build = spawnSync(COMPILER, ['build', 'test/preview_test.s', '-o', target, '--target', 'native', '--require-full-native', ...['ffi', 'net.connect', 'fs.read', 'fs.write', 'fs.metadata', 'random.secure', 'time.now'].flatMap(value => ['--grant', value])], { cwd: APP, encoding: 'utf8', timeout: 600000, maxBuffer: 10 * 1024 * 1024 })
    assert.equal(build.status, 0, build.stdout + build.stderr)
    child = spawn(target, args, { cwd: APP, stdio: ['ignore', 'pipe', 'pipe'] })
  } else child = backend('test/preview_test.s', args, process.env, ['ignore', 'pipe', 'pipe'])
  let result = ''
  child.stdout.on('data', data => result += data)
  child.stderr.on('data', data => result += data)
  const deadline = setTimeout(() => { void stop(child) }, 60000)
  const code = await new Promise(resolve => child.on('exit', resolve))
  clearTimeout(deadline)
  assert.equal(code, 0, result + '\nAgent:\n' + output)
  assert.match(result, /PASS notebook-web preview/)
  console.log(result.trim())
} finally { await stop(agent); await rm(root, { recursive: true, force: true }) }
