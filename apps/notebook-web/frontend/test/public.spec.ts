import { expect, test, type Page } from '@playwright/test'
import { mkdir, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

const starter = 'message = "Hello, Sputnik!"\nmessage\n'
const openPath = '/api/public/sessions'
const lease = (token: string) => openPath + '/' + token
const endpoint = (token: string) => '/api/projects/guest_' + token
const workspace = (page: Page) => page.getByTestId('notebook-workspace')
const openButton = (page: Page) => page.getByRole('button', { name: 'Open Getting started', exact: true })
const source = (page: Page) => workspace(page).getByRole('textbox', { name: 'Code cell 1', exact: true })
const runAll = (page: Page) => workspace(page).getByRole('button', { name: 'Run All', exact: true })

async function request(page: Page, path: string, method = 'GET', data?: unknown, headers?: Record<string, string>) {
  const token = (await page.context().cookies()).find(cookie => cookie.name === 'orbit-csrf')?.value
  return page.request.fetch(path, { method, data, headers: { Accept: 'application/json', Origin: new URL(page.url()).origin, ...(token ? { 'X-CSRF-Token': decodeURIComponent(token) } : {}), ...headers } })
}
async function start(page: Page, command = crypto.randomUUID()) {
  const response = await request(page, openPath, 'POST', { template_id: 'starter', command_id: command })
  expect(response.status(), await response.text()).toBe(200)
  return response.json()
}
async function open(page: Page, navigate = true) {
  if (navigate) await page.goto('/')
  const opening = page.waitForResponse(response => new URL(response.url()).pathname === openPath && response.request().method() === 'POST' && response.ok())
  await openButton(page).click()
  const copy = await (await opening).json()
  await expect(source(page)).toHaveValue(starter)
  await expect(runAll(page)).toBeEnabled()
  return copy
}
async function close(page: Page) {
  await page.getByRole('button', { name: 'Close demo notebook', exact: true }).click()
  await expect(openButton(page)).toBeEnabled()
}
async function save(page: Page) {
  await workspace(page).getByRole('button', { name: 'Save notebook', exact: true }).click()
  await expect(workspace(page).getByTestId('notebook-save-status')).toHaveText('All changes saved')
}
async function edit(page: Page, code: string) { await source(page).fill(code); await save(page) }
async function registry(page: Page, token: string) {
  const response = await request(page, endpoint(token) + '/execution')
  expect(response.status(), await response.text()).toBe(200)
  return response.json()
}
async function run(page: Page, token: string, revision: string, command: string) {
  return request(page, endpoint(token) + '/execution/runs', 'POST', { command_id: command, revision, sheet_id: 'main', cell_id: '1', action: 'run_all' })
}

test('guest opens the full book inertly, adds a sheet, edits, runs and exports it', async ({ page }) => {
  const copy = await open(page)
  const bootstrap = await (await request(page, '/api/session')).json()
  expect(bootstrap.account).toBeNull()
  expect(bootstrap.projects).toEqual([])
  expect(bootstrap.public_templates).toEqual([{ id: 'starter', title: 'Getting started' }])
  await expect(page.getByRole('dialog', { name: 'Public notebook' })).toHaveCount(0)
  await expect(workspace(page).getByTestId('resource-summary')).toContainText('60 s remaining')
  expect((await registry(page, copy.session_id)).runs).toEqual([])
  await workspace(page).getByRole('button', { name: 'New sheet', exact: true }).click()
  await workspace(page).getByRole('textbox', { name: 'Sheet title', exact: true }).fill('Experiment')
  await edit(page, '6 * 7\n')
  await runAll(page).click()
  await expect(workspace(page).getByLabel('Cell result', { exact: true })).toHaveText('42', { timeout: 15000 })
  for (const colorScheme of ['light', 'dark'] as const) for (const width of [1280, 375]) {
    await page.emulateMedia({ colorScheme })
    await page.setViewportSize({ width, height: 1000 })
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
  }
  const download = page.waitForEvent('download')
  await workspace(page).getByRole('button', { name: 'Export saved…', exact: true }).click()
  expect((await download).suggestedFilename()).toBe('Getting started.sputnikbook.zip')
  await close(page)
  expect((await request(page, endpoint(copy.session_id) + '/notebook')).status()).toBe(404)
  await open(page, false)
  await expect(workspace(page).getByRole('navigation', { name: 'Sheets' }).getByRole('button', { name: /Experiment/ })).toHaveCount(0)
  await close(page)
})

test('the guest editor saves bundled files and uses the real board and parameter controls', async ({ page }) => {
  const copy = await open(page)
  const base = endpoint(copy.session_id)
  await workspace(page).getByRole('button', { name: 'New module', exact: true }).click()
  const dialog = page.getByRole('dialog', { name: 'New module', exact: true })
  await dialog.getByLabel('Module name').fill('helpers')
  await dialog.getByRole('button', { name: 'Add to draft', exact: true }).click()
  await save(page)
  const { notebook } = await (await request(page, base + '/notebook')).json()
  const { entries } = await (await request(page, base + '/notebook/files?revision=' + notebook.revision)).json()
  expect(entries.map((entry: { path: string }) => entry.path)).toContain('modules/helpers.s')
  await workspace(page).getByRole('navigation', { name: 'Boards', exact: true }).getByRole('button', { name: 'Order calculator', exact: true }).click()
  await expect(workspace(page).getByLabel('Quantity', { exact: true }).last()).toBeVisible()
  await workspace(page).getByRole('button', { name: 'Run Sheet', exact: true }).click()
  const total = workspace(page).getByRole('region', { name: 'Total at 6 per item', exact: true })
  await expect(total.getByText('42', { exact: true })).toBeVisible({ timeout: 15000 })
  await workspace(page).getByRole('textbox', { name: 'Quantity', exact: true }).fill('8')
  await workspace(page).getByRole('button', { name: 'Apply', exact: true }).click()
  await expect(total.getByText('48', { exact: true })).toBeVisible({ timeout: 15000 })
  expect((await registry(page, copy.session_id)).runs.some((record: { sheet_id: string }) => record.sheet_id === 'order')).toBe(true)
  await close(page)
})

test('guest upload dialogs accept small files and folders and reject larger drafts locally', async ({ page }, testInfo) => {
  const copy = await open(page)
  const base = endpoint(copy.session_id)
  await workspace(page).getByRole('button', { name: 'Add resource…', exact: true }).click()
  const resource = page.getByRole('dialog', { name: 'Add resource', exact: true })
  await expect(resource).toContainText('256 KiB per file')
  const input = resource.getByLabel('Resource file', { exact: true })
  await input.setInputFiles({ name: 'too-large.csv', mimeType: 'text/csv', buffer: Buffer.alloc(256 * 1024 + 1) })
  await resource.getByRole('button', { name: 'Add to draft', exact: true }).click()
  await expect(resource.getByRole('alert')).toHaveText('Files are limited to 256 KiB each.')
  await input.setInputFiles({ name: 'sample.csv', mimeType: 'text/csv', buffer: Buffer.from('quantity\n7\n') })
  await resource.getByRole('button', { name: 'Add to draft', exact: true }).click()
  await expect(resource).toBeHidden()

  const oversizedFolder = testInfo.outputPath('large-batch')
  await mkdir(oversizedFolder, { recursive: true })
  await Promise.all(Array.from({ length: 5 }, (_, i) => writeFile(join(oversizedFolder, i + '.csv'), Buffer.alloc(256 * 1024))))
  const sampleFolder = testInfo.outputPath('samples')
  await mkdir(sampleFolder, { recursive: true })
  await writeFile(join(sampleFolder, 'small.csv'), 'quantity\n3\n')
  await workspace(page).getByRole('button', { name: 'Attach folder…', exact: true }).click()
  const folder = page.getByRole('dialog', { name: 'Attach folder', exact: true })
  await expect(folder).toContainText('1 MiB of file changes per save')
  await folder.getByLabel('Folder to attach').setInputFiles(oversizedFolder)
  await folder.getByRole('button', { name: 'Add to draft', exact: true }).click()
  await expect(folder.getByRole('alert')).toHaveText('Save up to 1 MiB of file changes at a time.')
  await folder.getByLabel('Folder to attach').setInputFiles(sampleFolder)
  await folder.getByRole('button', { name: 'Add to draft', exact: true }).click()
  await expect(folder).toBeHidden()
  await save(page)
  const { notebook } = await (await request(page, base + '/notebook')).json()
  const listing = await request(page, base + '/notebook/files?revision=' + notebook.revision)
  const { entries } = await listing.json()
  expect(entries.map((entry: { path: string }) => entry.path)).toEqual(['resources/sample.csv', 'resources/samples/small.csv'])
  await close(page)
})

test('the guest API enforces file, batch and media limits at the decoded byte boundaries', async ({ page }) => {
  test.setTimeout(60000)
  const copy = await open(page), base = endpoint(copy.session_id)
  const { notebook } = await (await request(page, base + '/notebook')).json()
  const encode = (size: number) => Buffer.alloc(size).toString('base64')
  const member = (size: number) => ({ encoding: 'base64', data: encode(size) })
  const changes = Object.fromEntries(Array.from({ length: 4 }, (_, i) => ['resources/' + i + '.bin', member(256 * 1024)]))
  const saveFiles = (command_id: string, files: Record<string, { encoding: string; data: string }>) =>
    request(page, base + '/notebook', 'PUT', { command_id, base_revision: notebook.revision, document: notebook.document, changes: files })
  async function rejected(response: Awaited<ReturnType<typeof request>>, code: string) {
    expect(response.status()).toBe(413)
    expect((await response.json()).error.code).toBe(code)
  }
  try {
    await rejected(await saveFiles('oversized-binary', { 'resources/large.bin': member(256 * 1024 + 1) }), 'public_file_too_large')
    await rejected(await saveFiles('oversized-text', { 'docs/large.md': { encoding: 'utf8', data: 'я'.repeat(128 * 1024 + 1) } }), 'public_file_too_large')
    const tooMany = { ...changes, 'resources/extra.bin': member(1) }
    await rejected(await saveFiles('oversized-batch', tooMany), 'public_upload_too_large')
    await rejected(await request(page, base + '/notebook/draft-archive', 'POST', { base_revision: notebook.revision, document: notebook.document, changes: tooMany }), 'public_upload_too_large')
    const atLimit = await saveFiles('accepted-batch', changes)
    expect(atLimit.status(), await atLimit.text()).toBe(200)

    const document = JSON.parse(notebook.document)
    document.inputs.push({ id: 'sample_file', title: 'Sample file', type: 'string', default: '' })
    document.boards[0].components.push({ id: 'upload_file', kind: 'file_input', title: 'Sample file', input: 'sample_file', p1: { extensions: 'csv' } })
    const authored = await request(page, base + '/notebook', 'PUT', {
      command_id: 'author-media', base_revision: (await atLimit.json()).notebook.revision, document: JSON.stringify(document),
    })
    expect(authored.status(), await authored.text()).toBe(200)
    const { revision, version } = await (await request(page, base + '/inputs')).json()
    const media = {
      command_id: 'oversized-media', revision, base_version: version,
      board_id: 'order_board', component_id: 'upload_file', operation: 'replace',
      extension: 'csv', name: 'sample.csv', data: encode(256 * 1024 + 1),
    }
    await rejected(await request(page, base + '/media-inputs', 'POST', media), 'public_file_too_large')
    const accepted = await request(page, base + '/media-inputs', 'POST', { ...media, command_id: 'small-media', data: Buffer.from('quantity\n7\n').toString('base64') })
    expect(accepted.status(), await accepted.text()).toBe(200)
  } finally { await close(page) }
})

test('guest books are isolated and grants, installs and account APIs remain restricted', async ({ page, browser, baseURL }) => {
  await page.goto('/')
  const alice = await start(page), a = endpoint(alice.session_id)
  const other = await browser.newContext({ baseURL }), bob = await other.newPage()
  try {
    await bob.goto('/')
    const copy = await start(bob), b = endpoint(copy.session_id)
    expect(copy.session_id).not.toBe(alice.session_id)
    expect((await request(bob, a + '/notebook')).status()).toBe(404)
    expect((await request(page, b + '/execution')).status()).toBe(404)
    expect((await request(page, lease(copy.session_id), 'DELETE')).status()).toBe(404)
    expect((await page.request.post(a + '/execution/runs', { data: {} })).status()).toBe(403)
    expect((await request(page, a + '/execution/runs', 'POST', {}, { Origin: 'https://attacker.invalid' })).status()).toBe(403)
    expect((await request(page, openPath, 'POST', { template_id: 'private', command_id: 'unlisted' })).status()).toBe(404)
    expect((await request(page, openPath, 'POST', { template_id: 'starter', command_id: 'forged', source_project: 'private', user_id: 'admin', profile: 'unlimited', public_ip: 'forged' })).status()).toBe(400)
    expect((await request(page, '/api/projects', 'POST', { title: 'Not authenticated' })).status()).toBe(401)
    expect((await request(page, '/api/projects/private/notebook')).status()).toBe(401)
    for (const path of ['/dependencies', '/environments', '/memberships', '/preview-sessions']) expect((await request(page, a + path, 'POST', {})).status()).toBe(401)
    expect((await request(page, a + '/worker-settings', 'PUT', {})).status()).toBe(401)
    const notebook = (await (await request(page, a + '/notebook')).json()).notebook
    expect(JSON.stringify(notebook)).not.toMatch(/core_project_id|source_project|anonymous_|ip_key|agent\.sock|\/private\//)
    const document = JSON.parse(notebook.document)
    document.dependencies = [{ name: 'disallowed', source: 'vendor/dependency' }]
    expect((await request(page, a + '/notebook', 'PUT', { command_id: 'dependencies', base_revision: notebook.revision, document: JSON.stringify(document) })).status()).toBe(400)
    expect((await request(page, a + '/notebook', 'PUT', { command_id: 'bundled-env', base_revision: notebook.revision, document: notebook.document, changes: { 'requirements.txt': { encoding: 'utf8', data: 'example\n' } } })).status()).toBe(422)
    await request(bob, lease(copy.session_id), 'DELETE')
  } finally { await request(page, lease(alice.session_id), 'DELETE'); await other.close() }
})

test('lost opening and run responses use the original opening or run receipt', async ({ page }) => {
  await page.goto('/')
  let opens = 0, token = ''
  await page.route('**/api/public/sessions', async route => {
    opens++
    const response = await route.fetch()
    expect(response.status()).toBe(200)
    const opened = (await response.json()).session_id
    if (opens === 1) {
      token = opened
      await route.fulfill({ status: 503, contentType: 'application/json', body: '{"error":{"message":"Lost opening reply"}}' })
    } else { expect(opened).toBe(token); await route.fulfill({ response }) }
  })
  await openButton(page).click()
  await page.getByRole('button', { name: 'Retry opening Getting started', exact: true }).click()
  await expect(source(page)).toHaveValue(starter)
  expect(opens).toBe(2)
  await page.unroute('**/api/public/sessions')
  let posts = 0
  await page.route('**/api/projects/guest_*/execution/runs', async route => {
    posts++
    const response = await route.fetch()
    expect(response.status()).toBe(200)
    await route.fulfill({ status: 503, contentType: 'application/json', body: '{"error":{"message":"Lost run reply"}}' })
  })
  await runAll(page).click()
  await expect(workspace(page).getByLabel('Cell result', { exact: true })).toHaveText('"Hello, Sputnik!"', { timeout: 15000 })
  expect(posts).toBe(1)
  expect((await registry(page, token)).runs).toHaveLength(1)
  expect(await page.evaluate(() => [...Object.keys(localStorage), ...Object.keys(sessionStorage)])).toEqual([])
  await close(page)
})

test('live output stays visible and the idle editor only renews its compact lease', async ({ page }) => {
  const copy = await open(page)
  const base = endpoint(copy.session_id), heartbeat = lease(copy.session_id) + '/lease'
  let notebookReads = 0, registryReads = 0, resultReads = 0
  page.on('request', request => {
    if (request.method() !== 'GET') return
    const path = new URL(request.url()).pathname
    if (path === base + '/notebook') notebookReads++
    if (path === base + '/execution') registryReads++
    if (path.startsWith(base + '/execution/runs/')) resultReads++
  })
  const nextHeartbeat = () => page.waitForResponse(response => new URL(response.url()).pathname === heartbeat && response.ok(), { timeout: 12000 })
  await edit(page, 'import task\nprint "demo working"\ntask.sleep(4000)\n42\n')
  await runAll(page).click()
  await expect(workspace(page).getByText('demo working', { exact: false })).toBeVisible()
  await expect(workspace(page).getByLabel('Cell result', { exact: true })).toHaveText('42', { timeout: 15000 })
  await nextHeartbeat()
  const counts = [notebookReads, registryReads, resultReads]
  for (let i = 0; i < 2; i++) {
    const status = await (await nextHeartbeat()).json()
    expect(Object.keys(status).sort()).toEqual(['lease_seconds', 'renewed', 'resources', 'runs'])
    expect(status.runs[0].state).toBe('succeeded')
  }
  expect([notebookReads, registryReads, resultReads]).toEqual(counts)
  await expect(workspace(page).getByLabel('Cell result', { exact: true })).toHaveText('42')
  await close(page)
})

test('fresh browser sessions share the IP ledger despite client forwarding headers', async ({ page, browser, baseURL }) => {
  await page.goto('/')
  const first = await start(page)
  const other = await browser.newContext({ baseURL })
  try {
    const response = await run(page, first.session_id, first.revision, 'ip-charge')
    expect(response.status()).toBe(200)
    await expect.poll(async () => (await registry(page, first.session_id)).runs[0]?.state).toBe('succeeded')
    const { resources } = await registry(page, first.session_id)
    expect(BigInt(resources.ip_remaining_ms)).toBeLessThan(BigInt(first.resources.ip_remaining_ms))
    const fresh = await other.newPage()
    await fresh.goto('/')
    const opened = await request(fresh, openPath, 'POST', { template_id: 'starter', command_id: 'new-cookie' }, { 'X-Forwarded-For': '192.0.2.42' })
    expect(opened.status()).toBe(200)
    const copy = await opened.json()
    expect(copy.resources.spent_ms).toBe('0')
    expect(BigInt(copy.resources.ip_remaining_ms)).toBeLessThanOrEqual(BigInt(resources.ip_remaining_ms))
    await request(fresh, lease(copy.session_id), 'DELETE')
  } finally { await request(page, lease(first.session_id), 'DELETE'); await other.close() }
})

test('a tighter authored limit stops the worker and the cookie budget survives a fresh copy', async ({ page }) => {
  await page.goto('/')
  const copy = await start(page), base = endpoint(copy.session_id)
  const initial = (await (await request(page, base + '/notebook')).json()).notebook
  const document = JSON.parse(initial.document)
  document.resource_policy = { total_run_seconds: 1, run_seconds: 600, project_bytes: 1073741824 }
  document.sheets[0].cells[0].source = 'import task\ntask.sleep(10000)\n42\n'
  const saved = await request(page, base + '/notebook', 'PUT', { command_id: 'tighter', base_revision: initial.revision, document: JSON.stringify(document) })
  expect(saved.status()).toBe(200)
  expect((await run(page, copy.session_id, (await saved.json()).notebook.revision, 'quota-run')).status()).toBe(200)
  await expect.poll(async () => (await registry(page, copy.session_id)).runs[0]?.state, { timeout: 10000 }).toBe('force-stopped')
  const spent = (await registry(page, copy.session_id)).resources.spent_ms
  expect(BigInt(spent)).toBeGreaterThanOrEqual(1000n)
  await request(page, lease(copy.session_id), 'DELETE')
  const fresh = await start(page)
  expect(BigInt(fresh.resources.spent_ms)).toBeGreaterThanOrEqual(BigInt(spent))
  expect(BigInt(fresh.resources.remaining_ms)).toBeLessThan(60000n)
  expect(fresh.resources.effective.total_run_seconds).toBe('60')
  expect(fresh.resources.effective.run_seconds).toBe('60')
  expect(fresh.resources.effective.project_bytes).toBe('67108864')
  await request(page, lease(fresh.session_id), 'DELETE')
})

test('lease expiry and hidden tabs discard guest books', async ({ page }) => {
  test.setTimeout(45000)
  await page.goto('/')
  const first = await start(page)
  await expect.poll(async () => (await request(page, endpoint(first.session_id) + '/notebook')).status(), { timeout: 22000, intervals: [500] }).toBe(404)
  expect((await request(page, lease(first.session_id) + '/lease', 'POST', {})).status()).toBe(404)
  await open(page, false)
  await page.evaluate(() => {
    Object.defineProperty(document, 'hidden', { value: true, configurable: true })
    document.dispatchEvent(new Event('visibilitychange'))
  })
  await expect(workspace(page)).toHaveCount(0)
  await expect(page.getByRole('alert')).toContainText('closed when this tab was hidden')
})

test('admission serializes concurrent opens and bounds repeated copies', async ({ page }) => {
  await page.goto('/')
  const responses = await Promise.all(['first', 'second'].map(command_id => request(page, openPath, 'POST', { template_id: 'starter', command_id })))
  expect(responses.map(response => response.status()).sort()).toEqual([200, 429])
  const active = await responses.find(response => response.status() === 200)!.json()
  await request(page, lease(active.session_id), 'DELETE')
  for (let i = 1; i < 10; i++) {
    const next = await start(page, 'copy_' + i)
    await request(page, lease(next.session_id), 'DELETE')
  }
  expect((await request(page, openPath, 'POST', { template_id: 'starter', command_id: 'too_many' })).status()).toBe(429)
})

test('the real 60-second limit stops the worker and persists across copies', async ({ page }) => {
  test.skip(process.env.NOTEBOOK_WEB_TEST_PUBLIC_FULL !== '1', 'Full-duration real-worker acceptance.')
  test.setTimeout(95000)
  const copy = await open(page)
  await edit(page, 'import task\ntask.sleep(70000)\n42\n')
  await runAll(page).click()
  await expect(workspace(page).getByTestId('resource-summary')).toContainText('· 0 s remaining', { timeout: 78000 })
  await expect.poll(async () => (await registry(page, copy.session_id)).runs.map((run: { state: string }) => run.state)).toEqual(['force-stopped'])
  expect(BigInt((await registry(page, copy.session_id)).resources.spent_ms)).toBeGreaterThanOrEqual(60000n)
  await expect(runAll(page)).toBeDisabled()
  await close(page)
  await openButton(page).click()
  await expect(source(page)).toHaveValue(starter)
  await expect(workspace(page).getByTestId('resource-summary')).toContainText('· 0 s remaining')
  await expect(runAll(page)).toBeDisabled()
  await close(page)
})
