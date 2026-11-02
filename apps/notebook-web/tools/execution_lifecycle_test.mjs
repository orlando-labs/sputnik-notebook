// Integration check: the HTTP process owns neither accepted runs nor workers.
import assert from 'node:assert/strict'
import net from 'node:net'
import path from 'node:path'
import { open, mkdir, writeFile } from 'node:fs/promises'
import { spawn } from 'node:child_process'
import { createRequire } from 'node:module'
import { APP, COMPILER, sleep, stop } from './common.mjs'

const require = createRequire(path.join(APP, 'frontend/package.json'))
const { chromium } = require('@playwright/test')
const coreRoot = `${process.platform === 'darwin' ? '/private/tmp' : '/tmp'}/sputnik-web-life-${process.pid}`
const database = path.join(APP, `build/lifecycle-${process.pid}.sqlite`)
await mkdir(path.join(APP, 'build'), { recursive: true })
const log = await open(path.join(APP, 'build/execution-lifecycle.log'), 'w')
const stdio = ['ignore', log.fd, log.fd]
const listener = net.createServer()
await new Promise(resolve => listener.listen(0, '127.0.0.1', resolve))
const port = listener.address().port
await new Promise(resolve => listener.close(resolve))
const origin = `http://127.0.0.1:${port}`
function startAgent() { return spawn(path.resolve(APP, '../../build/sputnik-notebook-remote'), [
  '--mode', 'agent', '--root', coreRoot,
  '--worker', path.resolve(APP, '../../build/sputnik-notebook-worker'), '--sputnik', COMPILER,
], { cwd: APP, stdio, detached: process.platform !== 'win32' }) }
let agent = startAgent()
let web, browser
async function until(read, predicate, label, timeout = 20_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = await read()
    if (predicate(value)) return value
    await sleep(100)
  }
  throw new Error(`Timed out: ${label}`)
}
function core(method, params) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(path.join(coreRoot, 'agent.sock'))
    let reply = ''
    socket.setTimeout(5000, () => socket.destroy(new Error('Core request timed out')))
    socket.on('connect', () => socket.write(JSON.stringify({ method, params }) + '\n'))
    socket.on('error', reject)
    socket.on('data', chunk => {
      reply += chunk
      if (!reply.includes('\n')) return
      socket.end()
      try {
        const parsed = JSON.parse(reply.split('\n')[0])
        assert.equal(parsed.status, 200, JSON.stringify(parsed))
        resolve(parsed.data)
      } catch (error) { reject(error) }
    })
  })
}
async function startWeb() {
  web = spawn(process.execPath, [path.join(APP, 'tools/smoke_server.mjs'), '--mode', 'production',
    '--port', String(port), '--database', database, '--core-root', coreRoot, '--external-core'],
  { cwd: APP, stdio, detached: process.platform !== 'win32' })
  await until(async () => {
    assert.equal(web.exitCode, null, 'Web process exited during startup')
    try { return (await fetch(origin)).status } catch { return 0 }
  }, status => status === 200, 'web readiness', 45_000)
}
try {
  await startWeb()
  browser = await chromium.launch({ headless: true, ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH } : {}) })
  const page = await browser.newPage()
  await page.goto(origin)
  await page.getByRole('button', { name: 'Continue with GitHub' }).click()
  await page.getByRole('button', { name: 'Sign in as Alice' }).click()
  await page.getByTestId('account-name').waitFor()
  async function request(route, method = 'GET', data) {
    const token = (await page.context().cookies()).find(cookie => cookie.name === 'orbit-csrf').value
    const response = await page.request.fetch(origin + route, { method, data,
      headers: { Accept: 'application/json', Origin: origin, 'X-CSRF-Token': decodeURIComponent(token) } })
    assert.ok(response.ok(), `${method} ${route}: ${response.status()} ${await response.text()}`)
    return response.json()
  }
  const { project } = await request('/api/projects', 'POST', { title: 'Independent web lifetime' })
  const notebookPath = `/api/projects/${project.id}/notebook`
  const base = `/api/projects/${project.id}/execution`
  const initial = (await request(notebookPath, 'POST', {})).notebook
  const document = JSON.parse(initial.document)
  document.sheets[0].cells = [{ id: '1', kind: 'code', mode: 'manual', source: 'import task\nprint "working"\ntask.sleep(12000)\n42\n' }]
  let saved = (await request(notebookPath, 'PUT', { command_id: crypto.randomUUID(), base_revision: initial.revision, document: JSON.stringify(document) })).notebook
  await page.goto(`${origin}/projects/${project.id}`)
  await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
  await page.getByLabel('Cell output', { exact: true }).waitFor()
  const first = (await request(base)).runs[0]
  await until(() => request(`${base}/runs/${first.id}`), value => value.run.state === 'running', 'first run running')
  let replayed = 0
  page.on('request', value => { if (value.method() === 'POST' && value.url().endsWith('/execution/runs')) replayed++ })
  await stop(web)
  assert.equal(agent.exitCode, null, 'Web shutdown must leave the independent agent alive')
  const whileOffline = await core('run.get', { run_id: first.id })
  assert.equal(whileOffline.id, first.id)
  assert.equal(whileOffline.epoch, first.runtime_epoch)
  assert.equal(whileOffline.state, 'running')
  await startWeb()
  await page.reload()
  await until(async () => page.getByLabel('Cell result', { exact: true }).textContent().catch(() => ''), value => value === '42', 'same run completion after web restart')
  const reattached = (await request(base)).runs
  assert.equal(reattached.length, 1)
  assert.equal(reattached[0].id, first.id)
  assert.equal(reattached[0].runtime_epoch, first.runtime_epoch)
  assert.equal(replayed, 0)

  // Only this disposable agent's own worker PID is used for fault injection.
  document.sheets[0].cells[0].source = 'import task\ntask.sleep(60000)\n84\n'
  saved = (await request(notebookPath, 'PUT', { command_id: crypto.randomUUID(), base_revision: saved.revision, document: JSON.stringify(document) })).notebook
  const crashed = (await request(`${base}/runs`, 'POST', { command_id: crypto.randomUUID(), revision: saved.revision, sheet_id: 'main', cell_id: '1', action: 'run' })).run
  await until(() => request(`${base}/runs/${crashed.id}`), value => value.run.state === 'running', 'fault injection run running')
  const trusted = await core('run.get', { run_id: crashed.id })
  const internal = await core('run.registry', { project_id: trusted.project })
  const worker = internal.runtimes.find(value => value.epoch === crashed.runtime_epoch)
  assert.ok(Number(worker.worker_pid) > 1)
  process.kill(Number(worker.worker_pid), 'SIGKILL')
  const interrupted = (await until(() => request(`${base}/runs/${crashed.id}`), value => value.run.state === 'interrupted', 'interruption classification')).run
  assert.match(interrupted.error, /interrupted/)
  await page.reload()
  await until(() => page.getByTestId('execution-status').textContent(), value => value === 'Restart required', 'restart gate')
  assert.equal(await page.getByRole('button', { name: 'Run All', exact: true }).isDisabled(), true)
  await request(`${base}/restart`, 'POST', { command_id: crypto.randomUUID(), sheet_id: 'main', runtime_epoch: crashed.runtime_epoch })
  document.sheets[0].cells[0].source = '84\n'
  saved = (await request(notebookPath, 'PUT', { command_id: crypto.randomUUID(), base_revision: saved.revision, document: JSON.stringify(document) })).notebook
  const fresh = (await request(`${base}/runs`, 'POST', { command_id: crypto.randomUUID(), revision: saved.revision, sheet_id: 'main', cell_id: '1', action: 'run' })).run
  assert.notEqual(fresh.runtime_epoch, crashed.runtime_epoch)
  const completed = (await until(() => request(`${base}/runs/${fresh.id}`), value => value.run.state === 'succeeded', 'explicit restart recovery')).run
  assert.equal(completed.cells.find(cell => cell.id === '1').result, '84')
  document.version = 4
  document.inputs = []
  document.dependencies = []
  document.modules = [{ id: 'jobs', path: 'modules/jobs.s' }]
  document.boards = [{ id: 'dashboard', title: 'Scheduled work', sheet: 'main', columns: 2, components: [{ id: 'ticks', kind: 'periodic_work', title: 'Server ticks', module_id: 'jobs', function: 'tick', period_seconds: .1, retention: 'tail', tail_limit: 2 }] }]
  const module = 'package jobs\nclass Counter:\n  def init(): @value = 0\n  def next():\n    @value += 1\n    @value\nState = Counter()\ndef tick(): State.next()\nexport tick\n'
  saved = (await request(notebookPath, 'PUT', { command_id: crypto.randomUUID(), base_revision: saved.revision, document: JSON.stringify(document), changes: { 'modules/jobs.s': { encoding: 'utf8', data: module } } })).notebook
  const serviceCommand = { command_id: crypto.randomUUID(), revision: saved.revision, board_id: 'dashboard', component_id: 'ticks', operation: 'start' }
  await request(`${base}/services`, 'POST', serviceCommand)
  const beforeGatewayStop = (await until(() => request(`${base}/services`), value => Number(value.services[0]?.runs) >= 1, 'first server tick')).services[0]
  let servicePosts = 0
  page.on('request', value => { if (value.method() === 'POST' && value.url().endsWith('/execution/services')) servicePosts++ })
  await stop(web)
  assert.equal(agent.exitCode, null)
  const offline = await until(() => core('service.list', { project_id: trusted.project }), value => value.services[0].runs > Number(beforeGatewayStop.runs) + 1, 'ticks without HTTP gateway')
  assert.equal(offline.services[0].enabled, true)
  await startWeb()
  await page.reload()
  await page.getByRole('navigation', { name: 'Boards', exact: true }).getByRole('button', { name: 'Scheduled work', exact: true }).click()
  const reattachedService = (await request(`${base}/services`)).services[0]
  assert.equal(reattachedService.enabled, true)
  assert.ok(Number(reattachedService.runs) >= offline.services[0].runs)
  assert.equal(servicePosts, 0, 'Board reattachment cannot configure a schedule')
  const oldAgentPID = agent.pid
  await stop(agent)
  agent = startAgent()
  await until(async () => { try { return await core('health', {}) } catch { return {} } }, value => value.agent_pid !== oldAgentPID && value.agent_pid > 0, 'new independent agent')
  const restartedService = (await request(`${base}/services`)).services[0]
  assert.equal(restartedService.enabled, false)
  assert.equal(restartedService.running, false)
  assert.match(restartedService.status, /Start to resume/)
  assert.ok(Number(restartedService.runs) >= Number(reattachedService.runs))
  assert.equal(restartedService.history_count, '2')
  // A durable old Start receipt is evidence of acceptance, not new authority
  // to enable a schedule after restart.
  await request(`${base}/services`, 'POST', serviceCommand)
  await sleep(350)
  assert.equal((await request(`${base}/services`)).services[0].runs, restartedService.runs)
  assert.equal((await request(`${base}/services`)).services[0].enabled, false)
  await request(`${base}/services`, 'POST', { ...serviceCommand, command_id: crypto.randomUUID() })
  await until(() => request(`${base}/services`), value => Number(value.services[0].runs) > Number(restartedService.runs), 'explicit service resume')
  await request(`${base}/services`, 'POST', { ...serviceCommand, command_id: crypto.randomUUID(), operation: 'pause' })
  await until(() => request(`${base}/services`), value => !value.services[0].running, 'paused service drain')
  await writeFile(path.join(APP, 'build/execution-lifecycle-report.json'), JSON.stringify({
    web_restart: { same_run: true, same_epoch: true, replayed_requests: replayed, result: '42' },
    worker_crash: { state: interrupted.state, requires_explicit_restart: true, new_epoch: true, result: '84' },
    service: { continued_without_gateway: true, reconnect_mutations: servicePosts, agent_restart_paused: true, retained_history: true, old_start_receipt_inert: true, explicit_resume: true },
  }, null, 2) + '\n')
  console.log('PASS: independent web restart reattaches to one physical run; worker crash requires explicit restart into a new epoch.')
  console.log('PASS: server service survives gateway shutdown; agent restart retains history, pauses scheduling and requires a new explicit Start.')
} finally {
  if (browser) await browser.close()
  await stop(web)
  await stop(agent)
  await log.close()
}
