import { expect, test, type Page } from '@playwright/test'

const endpoint = (token: string) => '/api/public/sessions/' + token
async function request(page: Page, path: string, method = 'GET', data?: unknown) {
  const token = (await page.context().cookies()).find(cookie => cookie.name === 'orbit-csrf')?.value
  return page.request.fetch(path, { method, data, headers: { Accept: 'application/json', Origin: new URL(page.url()).origin, ...(token ? { 'X-CSRF-Token': decodeURIComponent(token) } : {}) } })
}
async function start(page: Page, command = crypto.randomUUID()) {
  const response = await request(page, '/api/public/sessions', 'POST', { template_id: 'starter', command_id: command })
  expect(response.status(), await response.text()).toBe(200)
  return response.json()
}
const dialog = (page: Page) => page.getByRole('dialog', { name: 'Public notebook', exact: true })
async function open(page: Page) { await page.goto('/'); await page.getByRole('button', { name: 'Try Getting started', exact: true }).click(); await expect(dialog(page).getByLabel('Preview code cell 1', { exact: true })).toHaveValue('message = "Hello, Sputnik!"\nmessage\n') }
async function edit(page: Page, source: string) {
  await dialog(page).getByLabel('Preview code cell 1', { exact: true }).fill(source)
  await dialog(page).getByRole('button', { name: 'Save preview copy', exact: true }).click()
  await expect(dialog(page).getByRole('status').filter({ hasText: 'Preview copy saved' })).toBeVisible()
}

test('guest opens the pinned public template inertly, edits/runs explicitly and discards its private copy', async ({ page }) => {
  await page.goto('/')
  const bootstrap = (await (await request(page, '/api/session')).json())
  expect(bootstrap.account).toBeNull(); expect(bootstrap.projects).toEqual([]); expect(bootstrap.public_templates).toEqual([{ id: 'starter', title: 'Getting started' }])
  expect((await request(page, '/api/projects')).status()).toBe(401)
  await open(page)
  await expect(dialog(page).getByTestId('preview-budget')).toContainText('Remaining: 60 s')
  expect(await dialog(page).getByLabel('Cell result', { exact: true }).count()).toBe(0)
  await edit(page, '6 * 7\n'); await dialog(page).getByRole('button', { name: 'Run preview sheet', exact: true }).click()
  await expect(dialog(page).getByLabel('Cell result', { exact: true })).toHaveText('42', { timeout: 15000 })
  for (const colorScheme of ['light', 'dark'] as const) for (const width of [1280, 375]) {
    await page.emulateMedia({ colorScheme }); await page.setViewportSize({ width, height: 1000 })
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    expect(await dialog(page).evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true)
    await dialog(page).screenshot({ path: `../build/public-${colorScheme}-${width}-${process.env.ORBIT_E2E_MODE || 'production'}-${process.env.ORBIT_E2E_NATIVE === '1' ? 'native' : 'vm'}.png` })
  }
  await dialog(page).getByRole('button', { name: 'Close preview', exact: true }).click()
  await page.getByRole('button', { name: 'Try Getting started', exact: true }).click()
  await expect(dialog(page).getByLabel('Preview code cell 1', { exact: true })).toHaveValue('message = "Hello, Sputnik!"\nmessage\n')
  await expect(dialog(page).getByLabel('Cell result', { exact: true })).toHaveCount(0)
  expect((await (await request(page, '/api/session')).json()).account).toBeNull()
  await dialog(page).getByRole('button', { name: 'Close preview', exact: true }).click()
})

test('two anonymous visitors are isolated; CSRF, forged authority and private APIs remain rejected', async ({ page, browser, baseURL }) => {
  await page.goto('/'); const first = await start(page)
  const other = await browser.newContext({ baseURL }), bob = await other.newPage()
  try {
    await bob.goto('/'); const second = await start(bob)
    expect(second.session_id).not.toBe(first.session_id)
    expect((await request(bob, endpoint(first.session_id))).status()).toBe(404)
    expect((await request(page, endpoint(second.session_id), 'DELETE')).status()).toBe(404)
    expect((await page.request.post(endpoint(first.session_id) + '/lease', { data: {} })).status()).toBe(403)
    expect((await page.request.post(endpoint(first.session_id) + '/lease', { data: {}, headers: { Origin: 'https://attacker.invalid' } })).status()).toBe(403)
    expect((await request(page, '/api/public/sessions', 'POST', { template_id: 'private', command_id: 'unlisted' })).status()).toBe(404)
    expect((await request(page, '/api/public/sessions', 'POST', { template_id: 'starter', command_id: 'forged', source_project: 'private', user_id: 'admin', profile: 'unlimited' })).status()).toBe(400)
    expect((await request(page, '/api/projects', 'POST', { title: 'Not authenticated' })).status()).toBe(401)
    expect((await request(page, '/api/preview-sessions/' + first.session_id)).status()).toBe(401)
    for (const suffix of ['/packages', '/environments', '/worker-settings']) expect((await request(page, endpoint(first.session_id) + suffix, 'POST', {})).status()).toBe(404)
    const read = (await (await request(page, endpoint(first.session_id))).json())
    const text = JSON.stringify(read)
    expect(text).not.toMatch(/core_project_id|source_project|anonymous_|agent\.sock|\/private\//)
    const doc = JSON.parse(read.notebook.document); doc.dependencies = [{ name: 'malicious', source: '/etc' }]
    expect((await request(page, endpoint(first.session_id) + '/notebook', 'PUT', { command_id: 'dependencies', base_revision: read.notebook.revision, document: JSON.stringify(doc) })).status()).toBe(400)
    await request(bob, endpoint(second.session_id), 'DELETE')
  } finally { await request(page, endpoint(first.session_id), 'DELETE'); await other.close() }
})

test('lost opening/run replies recover the same commands only on explicit retry or receipt check', async ({ page }) => {
  await page.goto('/'); let opens = 0, original = ''
  await page.route('**/api/public/sessions', async route => {
    opens++; const response = await route.fetch()
    expect(response.status()).toBe(200)
    const token = (await response.json()).session_id
    if (opens === 1) { original = token; await route.fulfill({ status: 503, contentType: 'application/json', body: '{"error":{"message":"Lost opening reply"}}' }) }
    else { expect(token).toBe(original); await route.fulfill({ response }) }
  })
  await page.getByRole('button', { name: 'Try Getting started', exact: true }).click()
  await expect(dialog(page).getByRole('button', { name: 'Retry opening public copy', exact: true })).toBeVisible(); expect(opens).toBe(1)
  await dialog(page).getByRole('button', { name: 'Retry opening public copy', exact: true }).click(); await expect(dialog(page).getByLabel('Preview code cell 1', { exact: true })).toBeVisible(); expect(opens).toBe(2)
  await page.unroute('**/api/public/sessions')
  let posts = 0
  await page.route('**/api/public/sessions/*/runs', async route => { posts++; const response = await route.fetch(); expect(response.status()).toBe(200); await route.fulfill({ status: 503, contentType: 'application/json', body: '{"error":{"message":"Lost run reply"}}' }) })
  await dialog(page).getByRole('button', { name: 'Run preview sheet', exact: true }).click()
  await expect(dialog(page).getByLabel('Cell result', { exact: true })).toHaveText('"Hello, Sputnik!"', { timeout: 15000 }); expect(posts).toBe(1)
  expect((await (await request(page, endpoint(original))).json()).runs).toHaveLength(1)
  expect(await page.evaluate(() => [...Object.keys(localStorage), ...Object.keys(sessionStorage)].filter(key => /public|preview/i.test(key)))).toEqual([])
  await dialog(page).getByRole('button', { name: 'Close preview', exact: true }).click()
  expect((await request(page, endpoint(original))).status()).toBe(404)
})

test('tighter book quota stops work; fresh copies keep charged visitor time and the public/storage ceilings', async ({ page }) => {
  await open(page)
  // Authored metadata can only reduce the public limit. The public endpoint
  // retains normal exact document Save/CAS validation without server grants.
  let opened: any
  await dialog(page).getByRole('button', { name: 'Close preview', exact: true }).click(); opened = await start(page)
  const initial = (await (await request(page, endpoint(opened.session_id))).json()).notebook
  const document = JSON.parse(initial.document); document.resource_policy = { total_run_seconds: 1, run_seconds: 600, project_bytes: 1073741824 }; document.sheets[0].cells[0].source = 'import task\ntask.sleep(10000)\n42\n'
  const saved = await request(page, endpoint(opened.session_id) + '/notebook', 'PUT', { command_id: 'tighter', base_revision: initial.revision, document: JSON.stringify(document) }); expect(saved.status()).toBe(200)
  const run = (await (await request(page, endpoint(opened.session_id) + '/runs', 'POST', { command_id: 'quota-run', revision: (await saved.json()).notebook.revision, sheet_id: 'main', cell_id: '1', action: 'run_all' })).json()).run
  await expect.poll(async () => (await (await request(page, endpoint(opened.session_id) + '/runs/' + run.id)).json()).run.state, { timeout: 15000 }).toBe('force-stopped')
  const spent = (await (await request(page, endpoint(opened.session_id))).json()).resources.spent_ms
  expect(BigInt(spent)).toBeGreaterThanOrEqual(1000n)
  await request(page, endpoint(opened.session_id), 'DELETE')
  const fresh = await start(page)
  expect(BigInt(fresh.resources.spent_ms)).toBeGreaterThanOrEqual(BigInt(spent)); expect(BigInt(fresh.resources.remaining_ms)).toBeLessThan(60000n)
  expect(fresh.resources.effective.total_run_seconds).toBe('60'); expect(fresh.resources.effective.run_seconds).toBe('60'); expect(fresh.resources.effective.project_bytes).toBe('67108864')
  await request(page, endpoint(fresh.session_id), 'DELETE')
})

test('lease expiry and hidden/disconnected views discard public copies without replay', async ({ page }) => {
  test.setTimeout(45000)
  await page.goto('/'); const first = await start(page)
  await expect.poll(async () => (await request(page, endpoint(first.session_id))).status(), { timeout: 22000, intervals: [500] }).toBe(404)
  expect((await request(page, endpoint(first.session_id) + '/lease', 'POST', {})).status()).toBe(404)
  await page.getByRole('button', { name: 'Try Getting started', exact: true }).click(); await expect(dialog(page).getByLabel('Preview code cell 1', { exact: true })).toBeVisible()
  await page.evaluate(() => { Object.defineProperty(document, 'hidden', { value: true, configurable: true }); document.dispatchEvent(new Event('visibilitychange')) })
  await expect(dialog(page).getByLabel('Preview code cell 1', { exact: true })).toHaveCount(0)
  await expect(dialog(page).getByRole('alert')).toContainText('discarded')
  await dialog(page).getByRole('button', { name: 'Close preview', exact: true }).click()
})

test('admission serializes concurrent opens and bounds repeated copies for the same anonymous visitor', async ({ page }) => {
  await page.goto('/')
  const responses = await Promise.all(['first', 'second'].map(command_id => request(page, '/api/public/sessions', 'POST', { template_id: 'starter', command_id })))
  expect(responses.map(response => response.status()).sort()).toEqual([200, 429])
  const active = await responses.find(response => response.status() === 200)!.json(); await request(page, endpoint(active.session_id), 'DELETE')
  for (let i = 1; i < 10; i++) { const next = await start(page, 'copy_' + i); await request(page, endpoint(next.session_id), 'DELETE') }
  expect((await request(page, '/api/public/sessions', 'POST', { template_id: 'starter', command_id: 'too_many' })).status()).toBe(429)
})

test('actual 60-second aggregate ceiling survives a fresh copy', async ({ page }) => {
  test.skip(process.env.NOTEBOOK_WEB_TEST_PUBLIC_FULL !== '1', 'One full-duration real-worker acceptance is run in native production.')
  test.setTimeout(95000)
  const opening = page.waitForResponse(response => response.url().endsWith('/api/public/sessions') && response.request().method() === 'POST' && response.status() === 200)
  await open(page)
  const token = (await (await opening).json()).session_id
  await edit(page, 'import task\ntask.sleep(70000)\n42\n')
  await dialog(page).getByRole('button', { name: 'Run preview sheet', exact: true }).click()
  await expect(dialog(page).getByTestId('preview-budget')).toContainText('Remaining: 0 s', { timeout: 78000 })
  await expect.poll(async () => (await (await request(page, endpoint(token))).json()).runs.map((run: { state: string }) => run.state)).toEqual(['force-stopped'])
  expect(BigInt((await (await request(page, endpoint(token))).json()).resources.spent_ms)).toBeGreaterThanOrEqual(60000n)
  await expect(dialog(page).getByRole('button', { name: 'Run preview sheet', exact: true })).toBeDisabled()
  await dialog(page).getByRole('button', { name: 'Open fresh preview', exact: true }).click()
  await expect(dialog(page).getByLabel('Preview code cell 1', { exact: true })).toHaveValue('message = "Hello, Sputnik!"\nmessage\n')
  await expect(dialog(page).getByTestId('preview-budget')).toContainText('Remaining: 0 s')
  await expect(dialog(page).getByRole('button', { name: 'Run preview sheet', exact: true })).toBeDisabled()
  await dialog(page).getByRole('button', { name: 'Close preview', exact: true }).click()
})
