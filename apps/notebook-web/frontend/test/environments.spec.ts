import { expect, test, type Page } from '@playwright/test'
import net from 'node:net'

async function login(page: Page, user = 'Alice') { await page.goto('/'); await page.getByRole('button', { name: 'Continue with GitHub' }).click(); await page.getByRole('button', { name: `Sign in as ${user}` }).click(); await expect(page.getByTestId('account-name')).toHaveText(user) }
async function request(page: Page, url: string, method = 'GET', data?: unknown) { const token = (await page.context().cookies()).find(item => item.name === 'orbit-csrf')?.value; return page.request.fetch(url, { method, data, headers: { Accept: 'application/json', Origin: new URL(page.url()).origin, ...(token ? { 'X-CSRF-Token': decodeURIComponent(token) } : {}) } }) }
const captureSuffix = `${process.env.ORBIT_E2E_MODE || 'production'}-${process.env.ORBIT_E2E_NATIVE === '1' ? 'native' : 'vm'}`
const base = (id: string) => `/api/projects/${id}`
async function json(page: Page, url: string) { const response = await request(page, url); expect(response.status(), await response.text()).toBe(200); return response.json() }
async function rpc(method: string, params = {}): Promise<any> { return new Promise((resolve, reject) => { const socket = net.createConnection(`${process.env.NOTEBOOK_WEB_TEST_CORE_ROOT}/agent.sock`); let text = ''; socket.setTimeout(30000, () => socket.destroy(new Error('Core timeout'))); socket.on('error', reject); socket.on('connect', () => socket.write(JSON.stringify({ method, params }) + '\n')); socket.on('data', chunk => { text += chunk; if (!text.includes('\n')) return; socket.end(); const value = JSON.parse(text.split('\n')[0]!); value.status === 200 ? resolve(value.data) : reject(new Error(JSON.stringify(value))) }) }) }
async function setup(page: Page, files: Record<string, string> = {}) {
  const p = (await (await request(page, '/api/projects', 'POST', { title: 'Environment ' + crypto.randomUUID() })).json()).project
  const initial = (await (await request(page, base(p.id) + '/notebook', 'POST', {})).json()).notebook
  const doc = JSON.parse(initial.document); doc.sheets[0].cells[0].source = '"explicit run"\n'
  const saved = await request(page, base(p.id) + '/notebook', 'PUT', { command_id: crypto.randomUUID(), base_revision: initial.revision, document: JSON.stringify(doc), changes: Object.fromEntries(Object.entries(files).map(([name, data]) => [name, { encoding: 'utf8', data }])) }); expect(saved.status(), await saved.text()).toBe(200)
  await page.goto(`/projects/${p.id}`); await expect(page.getByLabel('Code cell 1', { exact: true })).toBeVisible()
  return { ...p, revision: (await saved.json()).notebook.revision }
}
const modal = (page: Page) => page.getByRole('dialog', { name: 'Environments and worker settings', exact: true })
async function show(page: Page) { await page.getByRole('button', { name: 'Environments…', exact: true }).click(); await expect(modal(page).getByLabel('Environment for next worker')).toBeVisible() }
async function settings(page: Page, id: string) { return json(page, base(id) + '/worker-settings?sheet=main') }
async function configure(page: Page, id: string, extra: Record<string, unknown> = {}) { const current = await settings(page, id); return request(page, base(id) + '/worker-settings', 'PUT', { command_id: crypto.randomUUID(), revision: current.revision, sheet_id: 'main', base_version: current.version, runtime_epoch: current.runtime_epoch, grants: [], environment_id: 'keep', ...extra }) }
async function coreID(page: Page, id: string) { const { projects } = await rpc('project.list'); const ids = []; for (const p of projects) { const record = await rpc('project.get', { project_id: p.id }); if (JSON.parse(record.document).title === (await json(page, base(id))).project.title) ids.push(p.id) } expect(ids).toHaveLength(1); return ids[0] }

test('operator defaults deny preparation and arbitrary server paths, grants and unknown sheets', async ({ page }) => {
  await login(page); const p = await setup(page); await show(page)
  const state = await json(page, base(p.id) + '/environments'); expect(state.environments).toEqual([])
  expect(JSON.stringify(await settings(page, p.id))).not.toMatch(/directory|\/Users\/|\/private\/|core_project_id/)
  if (!state.preparation_allowed) { await expect(modal(page)).toContainText('Preparation is disabled'); expect((await request(page, base(p.id) + '/environments', 'POST', { command_id: crypto.randomUUID(), revision: p.revision, retry: false })).status()).toBe(403) }
  expect((await configure(page, p.id, { grants: ['fs.read=/'] })).status()).toBe(422)
  expect((await configure(page, p.id, { environment_id: '/private/tmp/other' })).status()).toBe(422)
  expect((await configure(page, p.id, { environment_directory: '/' })).status()).toBe(400)
  expect((await request(page, base(p.id) + '/worker-settings?sheet=absent')).status()).toBe(404)
  expect((await json(page, base(p.id) + '/execution')).runs).toEqual([])
  for (const scheme of ['light', 'dark'] as const) for (const width of [1280, 375]) { await page.emulateMedia({ colorScheme: scheme }); await page.setViewportSize({ width, height: 1000 }); expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true); await page.screenshot({ path: `../build/environments-${scheme}-${width}-${captureSuffix}.png` }) }
})

test('worker review is inert until confirmation; stale drafts survive and receipts recover a lost response', async ({ page }) => {
  await login(page); const p = await setup(page); await show(page); const before = await settings(page, p.id)
  await expect(modal(page).getByRole('button', { name: 'Review settings and reset…' })).toBeEnabled()
  const polled = page.waitForResponse(response => new URL(response.url()).pathname === base(p.id) + '/environments' && response.request().method() === 'GET')
  await modal(page).getByLabel('Environment for next worker').focus(); await polled; await expect(modal(page).getByLabel('Environment for next worker')).toBeFocused()
  await modal(page).getByRole('button', { name: 'Review settings and reset…' }).click(); expect(await settings(page, p.id)).toEqual(before)
  await modal(page).getByRole('button', { name: 'Keep editing settings' }).click()
  const newer = await configure(page, p.id, { grants: before.allowed_grants.slice(0, 1) }); expect(newer.status(), await newer.text()).toBe(200)
  await modal(page).getByRole('button', { name: 'Review settings and reset…' }).click(); await modal(page).getByRole('button', { name: 'Confirm settings and reset' }).click()
  if (before.allowed_grants.length) await expect(modal(page).getByRole('alert')).toContainText('changed')
  await modal(page).getByRole('button', { name: 'Reload settings' }).click(); await expect(modal(page).getByRole('button', { name: 'Review settings and reset…' })).toBeEnabled()
  let lost = false
  await page.route('**/worker-settings', async route => { if (route.request().method() === 'PUT' && !lost) { lost = true; await route.fetch(); await route.abort('failed') } else await route.continue() })
  await modal(page).getByRole('button', { name: 'Review settings and reset…' }).click(); await modal(page).getByRole('button', { name: 'Confirm settings and reset' }).click()
  await expect(modal(page)).toContainText('Command accepted'); await expect(modal(page).getByRole('button', { name: 'Retry pending runtime command' })).toHaveCount(0)
  expect((await json(page, base(p.id) + '/execution')).runs).toEqual([])
})

test('saved revision, active run and settings CAS reject reset without erasing worker state', async ({ page }) => {
  await login(page); const p = await setup(page); const stale = await settings(page, p.id)
  const saved = (await json(page, base(p.id) + '/notebook')).notebook; const doc = JSON.parse(saved.document); doc.sheets[0].cells[0].source = 'task.sleep(2.0)\n42\n'
  expect((await request(page, base(p.id) + '/notebook', 'PUT', { command_id: crypto.randomUUID(), base_revision: saved.revision, document: JSON.stringify(doc), changes: {} })).status()).toBe(200)
  expect((await configure(page, p.id, { revision: stale.revision })).status()).toBe(409)
  const current = await settings(page, p.id); const run = await request(page, base(p.id) + '/execution/runs', 'POST', { command_id: crypto.randomUUID(), revision: current.revision, sheet_id: 'main', cell_id: '1', action: 'run' }); expect(run.status(), await run.text()).toBe(200)
  expect((await configure(page, p.id)).status()).toBe(409)
  await expect.poll(async () => (await json(page, base(p.id) + '/execution')).runs.at(-1)?.state).toBe('succeeded')
  const idle = await settings(page, p.id); expect(idle.runtime_epoch).not.toBeNull()
  expect((await configure(page, p.id, { runtime_epoch: 'old-epoch' })).status()).toBe(409)
  const spent = (await json(page, base(p.id) + '/execution')).resources.spent_ms
  expect((await configure(page, p.id)).status()).toBe(200); expect((await settings(page, p.id)).runtime_epoch).toBeNull()
  expect((await json(page, base(p.id) + '/execution')).resources.spent_ms).toBe(spent)
})

test('owner-only settings preserve private grants and revocation closes drafts', async ({ page, browser, baseURL }) => {
  await login(page); const p = await setup(page); const bob = await browser.newContext({ baseURL }); const other = await bob.newPage(); await login(other, 'Bob'); const account = (await json(other, '/api/session')).account.id
  expect((await request(page, base(p.id) + '/memberships', 'POST', { account_id: account, role: 'editor' })).status()).toBe(200)
  await other.goto(`/projects/${p.id}`); await show(other); await expect(modal(other)).toContainText('Only the project owner'); expect((await configure(other, p.id)).status()).toBe(403)
  const cid = await coreID(page, p.id); const current = await rpc('worker.settings', { project_id: cid, sheet_id: 'main' }); await rpc('worker.configure', { project_id: cid, command_id: crypto.randomUUID(), sheet_id: 'main', base_version: current.version, runtime_epoch: current.runtime_epoch, grants: ['fs.read=/private/operator-only'], environment_directory: '' })
  const publicSettings = await settings(page, p.id); expect(publicSettings.preserved_grants).toBe(1); expect(JSON.stringify(publicSettings)).not.toContain('operator-only'); expect((await configure(page, p.id)).status()).toBe(200)
  expect((await rpc('worker.settings', { project_id: cid, sheet_id: 'main' })).grants).toEqual(['fs.read=/private/operator-only'])
  expect((await request(page, base(p.id) + '/memberships/' + account, 'DELETE')).status()).toBe(204)
  await expect(modal(other)).not.toBeVisible({ timeout: 10000 }); await bob.close()
})

test('preparation is explicit, saved-only and exposes safe generations with retry and ready binding', async ({ page }) => {
  test.setTimeout(90000)
  test.skip(process.env.NOTEBOOK_WEB_TEST_ENVIRONMENTS !== '1', 'Operator preparation disabled in this configuration')
  await login(page); const p = await setup(page, { 'requirements.txt': '' }); await show(page)
  expect((await json(page, base(p.id) + '/environments')).environments).toEqual([])
  await modal(page).getByRole('button', { name: 'Prepare saved environment' }).click()
  await expect.poll(async () => (await json(page, base(p.id) + '/environments')).environments[0]?.state, { timeout: 60000 }).toBe('ready')
  await modal(page).getByRole('button', { name: 'Reload settings' }).click(); const ready = (await json(page, base(p.id) + '/environments')).environments[0]
  await page.setViewportSize({ width: 1280, height: 1000 }); await modal(page).evaluate(element => element.scrollTop = 0)
  await page.screenshot({ path: `../build/environment-ready-${captureSuffix}.png` })
  await page.setViewportSize({ width: 375, height: 1000 }); expect(await modal(page).evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true)
  await page.screenshot({ path: `../build/environment-ready-phone-${captureSuffix}.png` })
  const details = await json(page, base(p.id) + '/environments/' + ready.id); expect(JSON.stringify(details)).not.toMatch(/directory|\/Users\/|\/private\/|https?:|stdout|stderr|spec/)
  await modal(page).getByLabel('Environment for next worker').selectOption(ready.id); await modal(page).getByRole('button', { name: 'Review settings and reset…' }).click(); await modal(page).getByRole('button', { name: 'Confirm settings and reset' }).click()
  await expect.poll(async () => (await settings(page, p.id)).environment_id).toBe(ready.id); expect((await json(page, base(p.id) + '/execution')).runs).toEqual([])
  await modal(page).getByRole('button', { name: 'Done', exact: true }).click(); const saved = (await json(page, base(p.id) + '/notebook')).notebook
  expect((await request(page, base(p.id) + '/notebook', 'PUT', { command_id: crypto.randomUUID(), base_revision: saved.revision, document: saved.document, changes: { 'requirements.txt': { encoding: 'utf8', data: '--invalid-notebook-test-option\n' } } })).status()).toBe(200)
  await page.reload(); await show(page); await modal(page).getByRole('button', { name: 'Prepare saved environment' }).click()
  await expect.poll(async () => (await json(page, base(p.id) + '/environments')).environments[0]?.state, { timeout: 60000 }).toBe('failed')
  await modal(page).getByRole('button', { name: 'Reload settings' }).click(); await expect(modal(page).getByRole('button', { name: 'Retry saved environment' })).toBeEnabled()
  const failed = (await json(page, base(p.id) + '/environments')).environments[0]; await modal(page).getByRole('button', { name: 'Retry saved environment' }).click()
  await expect(modal(page)).toContainText('Preparation requested')
  await expect.poll(async () => (await json(page, base(p.id) + '/environments')).environments.find((item: any) => item.id === failed.id)?.state, { timeout: 60000 }).toBe('failed')
})

test('storage admission rejects settings and preparation, while temporary copies cannot change runtime privileges', async ({ page }) => {
  await login(page); const p = await setup(page); const cid = await coreID(page, p.id)
  const before = await settings(page, p.id)
  await rpc('policy.configure', { scope: 'project', id: cid, limits: { project_bytes: 1 } })
  try {
    expect((await configure(page, p.id)).status()).toBe(507)
    expect(await settings(page, p.id)).toEqual(before)
    if (process.env.NOTEBOOK_WEB_TEST_ENVIRONMENTS === '1') expect((await request(page, base(p.id) + '/environments', 'POST', { command_id: crypto.randomUUID(), revision: p.revision, retry: false })).status()).toBe(507)
  } finally { await rpc('policy.configure', { scope: 'project', id: cid, limits: {} }) }
  const temporary = await rpc('session.open', { source_project: cid, user_id: 'runtime-test', profile: 'public' })
  const current = await rpc('worker.settings', { project_id: temporary.project_id, sheet_id: 'main' })
  await expect(rpc('worker.configure', { project_id: temporary.project_id, command_id: crypto.randomUUID(), sheet_id: 'main', base_version: current.version, runtime_epoch: null, grants: ['time.now'], environment_directory: '' })).rejects.toThrow('403')
  await expect(rpc('environment.prepare', { project_id: temporary.project_id, command_id: crypto.randomUUID() })).rejects.toThrow('403')
  const policy = await rpc('policy.get', { project_id: temporary.project_id }); expect(policy.effective.total_run_seconds).toBe(60)
  await rpc('session.close', { project_id: temporary.project_id })
})
