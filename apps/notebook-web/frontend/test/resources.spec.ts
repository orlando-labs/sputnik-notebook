import { expect, test, type Page } from '@playwright/test'
import net from 'node:net'

async function login(page: Page, user = 'Alice') {
  await page.goto('/'); await page.getByRole('button', { name: 'Continue with GitHub' }).click(); await page.getByRole('button', { name: `Sign in as ${user}` }).click(); await expect(page.getByTestId('account-name')).toHaveText(user)
}
async function request(page: Page, path: string, method = 'GET', data?: unknown) {
  const token = (await page.context().cookies()).find(cookie => cookie.name === 'orbit-csrf')?.value
  return page.request.fetch(path, { method, data, headers: { Accept: 'application/json', Origin: new URL(page.url()).origin, ...(token ? { 'X-CSRF-Token': decodeURIComponent(token) } : {}) } })
}
async function book(page: Page, source = '42\n', policy: Record<string, number> = {}) {
  const project = (await (await request(page, '/api/projects', 'POST', { title: `Resources ${crypto.randomUUID()}` })).json()).project
  const endpoint = `/api/projects/${project.id}/notebook`
  const initial = (await (await request(page, endpoint, 'POST', {})).json()).notebook
  const document = JSON.parse(initial.document); document.sheets[0].cells[0].source = source; document.resource_policy = policy; document.opaque = { retained: 'unchanged' }
  const response = await request(page, endpoint, 'PUT', { command_id: crypto.randomUUID(), base_revision: initial.revision, document: JSON.stringify(document) }); expect(response.status()).toBe(200)
  return { project, notebook: (await response.json()).notebook }
}
async function rpc(method: string, params = {}): Promise<any> {
  return new Promise((resolve, reject) => { const socket = net.createConnection(`${process.env.NOTEBOOK_WEB_TEST_CORE_ROOT}/agent.sock`); let body = ''; socket.on('error', reject); socket.on('connect', () => socket.write(JSON.stringify({ method, params }) + '\n')); socket.on('data', chunk => { body += chunk; if (body.includes('\n')) { socket.end(); const response = JSON.parse(body); response.status === 200 ? resolve(response.data) : reject(new Error(body)) } }) })
}

test('resource settings edit the portable book draft, inherit defaults and preserve saved limits', async ({ page }) => {
  await login(page); const { project } = await book(page)
  await page.goto(`/projects/${project.id}`); await expect(page.getByTestId('resource-summary')).toContainText('0 s used')
  await page.getByRole('button', { name: 'Resource limits…', exact: true }).click()
  const dialog = page.getByRole('dialog', { name: 'Resource limits', exact: true }); await expect(dialog.getByTestId('resource-usage')).toContainText('Unlimited')
  await dialog.getByLabel('Override One run', { exact: true }).check(); await dialog.getByLabel('One run limit', { exact: true }).fill('3')
  await dialog.getByRole('button', { name: 'Cancel', exact: true }).click(); await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved')
  await page.getByRole('button', { name: 'Resource limits…', exact: true }).click(); await expect(dialog.getByLabel('Override One run', { exact: true })).not.toBeChecked()
  await dialog.getByLabel('Override One run', { exact: true }).check(); await dialog.getByLabel('One run limit', { exact: true }).fill('3')
  await dialog.getByLabel('Override Notebook storage', { exact: true }).check(); await dialog.getByLabel('Notebook storage limit', { exact: true }).fill('1.5')
  for (const colorScheme of ['light', 'dark'] as const) { await page.emulateMedia({ colorScheme }); await dialog.evaluate(element => element.scrollTop = 0); await page.screenshot({ path: `../build/resources-${colorScheme}.png` }) }
  await page.setViewportSize({ width: 375, height: 900 }); expect(await dialog.evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true); await dialog.evaluate(element => element.scrollTop = 0); await page.screenshot({ path: '../build/resources-mobile.png' }); await page.setViewportSize({ width: 1280, height: 900 })
  await dialog.getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await expect(page.getByTestId('notebook-save-status')).toHaveText('Unsaved changes')
  const before = (await (await request(page, `/api/projects/${project.id}/resources`)).json()).resources; expect(before.effective.run_seconds).toBeNull()
  await page.getByRole('button', { name: 'Save notebook', exact: true }).click(); await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved')
  const response = await request(page, `/api/projects/${project.id}/resources`); expect(response.status()).toBe(200); const after = (await response.json()).resources
  expect(after.effective.run_seconds).toBe('3'); expect(after.effective.project_bytes).toBe('1572864'); expect(after.defaults.run_seconds).toBeNull(); expect(after.spent_ms).toBe('0')
  expect(JSON.stringify(after)).not.toMatch(/core_project_id|user_id|scopes|available_bytes|total_bytes/)
  const stored = (await (await request(page, `/api/projects/${project.id}/notebook`)).json()).notebook; expect(JSON.parse(stored.document).opaque.retained).toBe('unchanged')
  expect((await (await request(page, `/api/projects/${project.id}/execution`)).json()).runs).toEqual([])
  await page.reload(); await expect(page.getByTestId('resource-summary')).toContainText('One run: 3 s')
})

test('core stops a real run at its cumulative quota, shows exhaustion and retains history', async ({ page }) => {
  await login(page); const { project, notebook } = await book(page, 'import task\ntask.sleep(60000)\n42\n', { total_run_seconds: 1 })
  await page.goto(`/projects/${project.id}`); await expect(page.getByTestId('resource-summary')).toContainText('1 s remaining')
  await page.getByRole('button', { name: 'Run All', exact: true }).click(); await expect(page.getByTestId('resource-summary')).toContainText('Execution budget exhausted', { timeout: 15000 }); await expect(page.getByRole('button', { name: 'Run All', exact: true })).toBeDisabled()
  const endpoint = `/api/projects/${project.id}/execution`, state = (await (await request(page, endpoint)).json()); expect(state.resources.remaining_ms).toBe('0'); expect(BigInt(state.resources.spent_ms)).toBeGreaterThanOrEqual(1000n)
  const run = state.runs.at(-1); await expect.poll(async () => (await (await request(page, `${endpoint}/runs/${run.id}`)).json()).run.state).toBe('force-stopped')
  expect((await request(page, endpoint + '/runs', 'POST', { command_id: crypto.randomUUID(), revision: notebook.revision, sheet_id: 'main', cell_id: '1', action: 'run_all' })).status()).toBe(403)
  await page.reload(); await expect(page.getByTestId('resource-summary')).toContainText('0 s remaining'); expect((await request(page, endpoint + '/history')).status()).toBe(200)
})

test('storage quota rejects Run without accepting work and is visible in resource settings', async ({ page }) => {
  await login(page); const { project } = await book(page, '42\n', { project_bytes: 1048576 })
  await page.goto(`/projects/${project.id}`); await page.getByRole('button', { name: 'Run All', exact: true }).click()
  await expect(page.getByTestId('execution-message')).toContainText('storage limit')
  expect((await (await request(page, `/api/projects/${project.id}/execution`)).json()).runs).toEqual([])
  await page.getByRole('button', { name: 'Resource limits…', exact: true }).click(); const dialog = page.getByRole('dialog', { name: 'Resource limits', exact: true })
  await expect(dialog.getByTestId('resource-usage')).toContainText('Stored:'); await expect(dialog.getByLabel('Notebook storage limit', { exact: true })).toHaveValue('1')
})

test('temporary public-limits preview edits only its copy and recovers a lost run reply without replay', async ({ page }) => {
  await login(page); const { project, notebook } = await book(page, '42\n', { run_seconds: 180, total_run_seconds: 180 })
  await page.goto(`/projects/${project.id}`); await page.getByRole('button', { name: 'Temporary preview…', exact: true }).click()
  const dialog = page.getByRole('dialog', { name: 'Temporary preview', exact: true }); await expect(dialog.getByTestId('preview-budget')).toContainText('Remaining: 60 s'); await expect(dialog.getByTestId('preview-budget')).toContainText('One run: 60 s')
  for (const colorScheme of ['light', 'dark'] as const) { await page.emulateMedia({ colorScheme }); await page.screenshot({ path: `../build/preview-${colorScheme}.png` }) }
  await page.setViewportSize({ width: 375, height: 900 }); expect(await dialog.evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true); await page.screenshot({ path: '../build/preview-mobile.png' }); await page.setViewportSize({ width: 1280, height: 900 })
  await dialog.getByLabel('Preview code cell 1', { exact: true }).fill('99\n'); await dialog.getByRole('button', { name: 'Save preview copy', exact: true }).click(); await expect(dialog.getByRole('status').filter({ hasText: 'Preview copy saved' })).toBeVisible()
  let posts = 0
  await page.route('**/api/preview-sessions/*/runs', async route => { if (route.request().method() !== 'POST') return route.continue(); posts++; const response = await route.fetch(); expect(response.status()).toBe(200); await route.fulfill({ status: 503, contentType: 'application/json', body: '{"error":{"message":"Lost reply"}}' }) })
  await dialog.getByRole('button', { name: 'Run preview sheet', exact: true }).click(); await expect(dialog.getByLabel('Cell result', { exact: true })).toHaveText('99', { timeout: 15000 }); expect(posts).toBe(1); await page.unroute('**/api/preview-sessions/*/runs')
  expect((await (await request(page, `/api/projects/${project.id}/notebook`)).json()).notebook.revision).toBe(notebook.revision)
  await dialog.getByRole('button', { name: 'Close preview', exact: true }).click(); await page.getByRole('button', { name: 'Temporary preview…', exact: true }).click(); await expect(dialog.getByLabel('Preview code cell 1', { exact: true })).toHaveValue('42\n'); await expect(dialog.getByTestId('preview-budget')).toContainText('Remaining: 60 s'); await expect(dialog.getByLabel('Cell result', { exact: true })).toHaveCount(0)
  expect(await page.evaluate(() => [...Object.keys(localStorage), ...Object.keys(sessionStorage)].filter(key => /preview/i.test(key)))).toEqual([])
  await dialog.getByRole('button', { name: 'Close preview', exact: true }).click()
})

test('public profile cannot lift the 60-second ceiling and preview Stop/ACL/CSRF remain enforced', async ({ page, browser, baseURL }) => {
  await login(page); const { project } = await book(page, 'import task\ntask.sleep(60000)\n42\n')
  await rpc('policy.configure', { scope: 'profile', id: 'public', limits: { persistence: 'durable', run_seconds: 600, total_run_seconds: 600 } })
  const other = await browser.newContext({ baseURL })
  try {
    const bob = await other.newPage(); await login(bob, 'Bob'); expect((await request(bob, `/api/projects/${project.id}/resources`)).status()).toBe(404)
    const bobId = (await (await request(bob, '/api/session')).json()).account.id
    expect((await request(page, `/api/projects/${project.id}/memberships`, 'POST', { account_id: bobId, role: 'viewer' })).status()).toBe(200)
    expect((await request(bob, `/api/projects/${project.id}/resources`)).status()).toBe(200); expect((await request(bob, `/api/projects/${project.id}/preview-sessions`, 'POST', {})).status()).toBe(403)
    const opened = await request(page, `/api/projects/${project.id}/preview-sessions`, 'POST', {}), session = await opened.json(), endpoint = `/api/preview-sessions/${session.session_id}`
    expect(session.resources.remaining_ms).toBe('60000'); expect(session.resources.effective.run_seconds).toBe('60'); expect((await request(bob, endpoint)).status()).toBe(404)
    expect((await page.request.post(endpoint + '/lease', { data: {} })).status()).toBe(403)
    const run = (await (await request(page, endpoint + '/runs', 'POST', { command_id: crypto.randomUUID(), revision: session.revision, sheet_id: 'main', cell_id: '1', action: 'run_all' })).json()).run
    expect((await request(bob, `${endpoint}/runs/${run.id}/stop`, 'POST', { command_id: crypto.randomUUID(), runtime_epoch: run.runtime_epoch, force: true })).status()).toBe(404)
    expect((await request(page, `${endpoint}/runs/${run.id}/stop`, 'POST', { command_id: crypto.randomUUID(), runtime_epoch: run.runtime_epoch, force: true })).status()).toBe(200)
    await expect.poll(async () => (await (await request(page, `${endpoint}/runs/${run.id}`)).json()).run.state).toBe('force-stopped')
    expect((await request(page, endpoint, 'DELETE')).status()).toBe(200); expect((await request(page, endpoint)).status()).toBe(404)
  } finally { await rpc('policy.configure', { scope: 'profile', id: 'public', limits: { persistence: 'session', run_seconds: 60, total_run_seconds: 60, project_bytes: 67108864, max_run_bytes: 8388608, lease_seconds: 15, session_seconds: 900 } }); await other.close() }
})
