// Test-only orchestration. OAuth provider and application both execute Sputnik.
import http from 'node:http'
import net from 'node:net'
import path from 'node:path'
import { readFile, realpath, mkdir, open } from 'node:fs/promises'
import { parseArgs } from 'node:util'
import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import os from 'node:os'
import { packageFixture } from './package_fixture.mjs'
import { APP, COMPILER, backend, vite, stop, sleep } from './common.mjs'

const { values } = parseArgs({ options: { mode: { type: 'string', default: 'production' }, port: { type: 'string', default: '3000' }, 'native-backend': { type: 'boolean', default: false }, database: { type: 'string' }, 'core-root': { type: 'string' }, 'without-core': { type: 'boolean', default: false }, 'external-core': { type: 'boolean', default: false } } })
if (!['development', 'production'].includes(values.mode)) throw new Error('Invalid smoke mode')
if (values['without-core'] && values['external-core']) throw new Error('Choose either --without-core or --external-core')
const origin = `http://127.0.0.1:${Number(values.port)}`
async function freePort() {
  const server = net.createServer()
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  const port = server.address().port
  await new Promise(resolve => server.close(resolve))
  return port
}
async function ready(port) {
  return new Promise(resolve => {
    const socket = net.connect(port, '127.0.0.1')
    socket.once('connect', () => { socket.destroy(); resolve(true) })
    socket.once('error', () => resolve(false))
  })
}
const providerPort = await freePort(), backendPort = await freePort(), vitePort = await freePort()
const compilerStamp = createHash('sha256').update(await readFile(COMPILER)).digest('hex').slice(0, 12)
const env = { ...process.env, ORBIT_ORIGIN: origin, VITE_ORIGIN: `http://127.0.0.1:${vitePort}`, SPUTNIK_VM_CACHE: path.join(APP, `build/smoke-${values.mode}-${compilerStamp}-cache`) }
await mkdir(path.join(APP, 'build'), { recursive: true })
const log = await open(path.join(APP, `build/smoke-${values.mode}.log`), 'w')
const stdio = ['ignore', log.fd, log.fd]
const children = []
let ending = false
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { ending = true })
let edge, registry
try {
  if (process.env.NOTEBOOK_WEB_PACKAGE_FIXTURE === '1') { registry = await packageFixture(COMPILER); env.SPUTNIK_PKG_REGISTRY = registry.origin; delete env.SPUTNIK_PKG_CREDENTIALS }
  // Keep test services in the runner's process group. A forced runner shutdown
  // must also terminate its services, even when JavaScript finally cannot run.
  children.push(backend(path.join(APP, 'test/github_fixture.s'), ['--port', String(providerPort), '--callback-origin', origin], { ...env, SPUTNIK_VM_CACHE: env.SPUTNIK_VM_CACHE + '-provider' }, stdio, false))
  if (values.mode === 'development') children.push(vite(env, stdio, false))
  const database = path.resolve(values.database || path.join(APP, 'build', `smoke-${process.pid}.sqlite`))
  // macOS Unix socket names are limited to 104 bytes; checkout paths are longer.
  const temporary = process.platform === 'darwin' ? '/private/tmp' : os.tmpdir()
  const coreRoot = path.resolve(values['core-root'] || process.env.NOTEBOOK_WEB_TEST_CORE_ROOT || path.join(temporary, `sputnik-web-${createHash('sha256').update(database).digest('hex').slice(0, 16)}`))
  env.SPUTNIK_PKG_HOME = process.env.NOTEBOOK_WEB_TEST_PACKAGE_HOME || path.join(coreRoot, 'packages')
  if (!values['without-core'] && !values['external-core']) {
    children.push(spawn(path.resolve(APP, '../../build/sputnik-notebook-remote'),
      ['--mode', 'agent', '--root', coreRoot, '--worker', path.resolve(APP, '../../build/sputnik-notebook-worker'), '--sputnik', COMPILER],
      { cwd: APP, env, stdio, detached: false }))
  }
  const backendArgs = ['--database', database, '--mode', values.mode, '--origin', origin, '--port', String(backendPort), '--vite-origin', env.VITE_ORIGIN, '--github-origin', `http://127.0.0.1:${providerPort}`]
  if (!values['without-core']) backendArgs.push('--core-root', coreRoot)
  if (process.env.NOTEBOOK_WEB_TEST_PUBLIC === '1') backendArgs.push('--public-fixture')
  if (process.env.NOTEBOOK_WEB_TEST_PUBLIC_ONLY === '1') backendArgs.push('--public-only')
  if (process.env.NOTEBOOK_WEB_TEST_ENVIRONMENTS === '1') backendArgs.push('--allow-environment-preparation', '--web-worker-grants', 'time.now,random.secure')
  children.push(values['native-backend']
    ? spawn(path.join(APP, 'build/fixture-native/fixture'), backendArgs, { cwd: APP, env, stdio, detached: false })
    : backend(path.join(APP, 'test/app_fixture.s'), backendArgs, env, stdio, false))
  for (let attempt = 0; ; attempt++) {
    if (children.some(child => child.exitCode !== null || child.signalCode !== null)) throw new Error('Smoke child exited; inspect build/smoke-' + values.mode + '.log')
    let coreReady = values['without-core']
    if (!coreReady) {
      try { await realpath(path.join(coreRoot, 'agent.sock')); coreReady = true } catch { /* Agent is starting. */ }
    }
    if (coreReady && await ready(providerPort) && await ready(backendPort) && (values.mode !== 'development' || await ready(vitePort))) break
    if (attempt > 450 || ending) throw new Error('Smoke startup timed out or was stopped')
    await sleep(100)
  }
  const root = path.join(APP, 'frontend/dist/assets')
  edge = http.createServer(async (request, response) => {
    const reject = () => { response.writeHead(404, { 'Content-Type': 'application/json' }); response.end('{}') }
    let pathname
    try { pathname = decodeURIComponent(new URL(request.url, origin).pathname) } catch { return reject() }
    if (pathname.startsWith('/assets/')) {
      if (values.mode !== 'production') return reject()
      try {
        const file = await realpath(path.join(root, pathname.slice('/assets/'.length)))
        if (!file.startsWith(await realpath(root) + path.sep)) return reject()
        const body = await readFile(file)
        const type = { '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' }[path.extname(file)] || 'application/octet-stream'
        response.writeHead(200, { 'Content-Type': type, 'Content-Length': body.length, 'Cache-Control': 'public, max-age=31536000, immutable' })
        return response.end(body)
      } catch { return reject() }
    }
    if (pathname.startsWith('/.vite/') || pathname === '/favicon.ico') return reject()
    const proxy = http.request({ hostname: '127.0.0.1', port: backendPort, method: request.method, path: request.url, headers: { ...request.headers, connection: 'close' } }, upstream => {
      response.writeHead(upstream.statusCode, upstream.headers)
      upstream.pipe(response)
    })
    proxy.on('error', () => { response.writeHead(502); response.end() })
    request.pipe(proxy)
  })
  await new Promise(resolve => edge.listen(Number(values.port), '127.0.0.1', resolve))
  console.log(`Offline GitHub fixture / ${values.mode}: ${origin}`)
  while (!ending) await sleep(200)
} finally {
  if (edge) { edge.closeAllConnections(); await new Promise(resolve => edge.close(resolve)) }
  await Promise.all(children.map(child => stop(child, false)))
  if (registry) await registry.close()
  await log.close()
}
