import { expect, test, type Page } from '@playwright/test'
import net from 'node:net'
import { readFile } from 'node:fs/promises'

async function login(page: Page, user = 'Alice') {
  await page.goto('/')
  await page.getByRole('button', { name: 'Continue with GitHub' }).click()
  await page.getByRole('button', { name: `Sign in as ${user}` }).click()
  await expect(page.getByTestId('account-name')).toHaveText(user)
}
async function request(page: Page, path: string, method = 'GET', data?: unknown) {
  const token = (await page.context().cookies()).find(cookie => cookie.name === 'orbit-csrf')?.value
  return page.request.fetch(path, { method, data, headers: { Accept: 'application/json', Origin: new URL(page.url()).origin,
    ...(token ? { 'X-CSRF-Token': decodeURIComponent(token) } : {}) } })
}
async function makeProject(page: Page) {
  const result = await request(page, '/api/projects', 'POST', { title: `Notebook ${crypto.randomUUID()}` })
  expect(result.status()).toBe(201)
  return (await result.json()).project
}
const pathFor = (id: string) => `/api/projects/${id}/notebook`
async function initialize(page: Page, id: string) {
  const response = await request(page, pathFor(id), 'POST', {})
  expect(response.status()).toBe(200)
  return (await response.json()).notebook
}
async function stored(page: Page, id: string) {
  const response = await request(page, pathFor(id))
  expect(response.status()).toBe(200)
  return (await response.json()).notebook
}
async function save(page: Page) {
  await page.getByRole('button', { name: 'Save notebook', exact: true }).click()
  await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved')
}
// This privileged IPC helper is test-only. The browser never receives the core ID/socket.
async function rpc(method: string, params = {}): Promise<any> {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(`${process.env.NOTEBOOK_WEB_TEST_CORE_ROOT}/agent.sock`)
    let body = ''
    socket.setTimeout(30_000, () => socket.destroy(new Error('Core test timeout')))
    socket.on('error', reject)
    socket.on('connect', () => socket.write(JSON.stringify({ method, params }) + '\n'))
    socket.on('data', chunk => {
      body += chunk
      if (!body.includes('\n')) return
      socket.end()
      const result = JSON.parse(body)
      if (result.status !== 200) reject(new Error(JSON.stringify(result)))
      else resolve(result.data)
    })
  })
}
async function coreProject(title: string) {
  const result = await rpc('project.list')
  return result.projects.find((project: any) => project.title === title)
}

test('legacy project initialization is explicit, idempotent, and saving is inert', async ({ page }) => {
  await login(page)
  const project = await makeProject(page)
  expect(await stored(page, project.id)).toBeNull()
  expect(await coreProject(project.title)).toBeUndefined()
  const initialized = await Promise.all([initialize(page, project.id), initialize(page, project.id)])
  expect(initialized[0]).toEqual(initialized[1])
  await page.goto(`/projects/${project.id}`)
  const source = page.getByRole('textbox', { name: 'Code cell 1', exact: true })
  await source.fill('answer = 21\nanswer * 2\n')
  await page.getByRole('button', { name: 'Text cell', exact: true }).click()
  await page.getByRole('textbox', { name: 'Text cell 2', exact: true }).fill('Experiment notes\nExpected result: 42.')
  await page.getByRole('button', { name: 'Move cell 2 up', exact: true }).click()
  await expect(page.getByRole('textbox', { name: 'Text cell 1', exact: true })).toHaveValue('Experiment notes\nExpected result: 42.')
  await page.getByRole('button', { name: 'New sheet', exact: true }).click()
  await page.getByRole('textbox', { name: 'Sheet title', exact: true }).fill('Second sheet')
  await page.getByRole('textbox', { name: 'Code cell 1', exact: true }).fill('"Saved without running"\n')
  await page.keyboard.press('ControlOrMeta+s')
  await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved')
  await page.reload()
  await expect(page.getByRole('textbox', { name: 'Sheet title', exact: true })).toHaveValue('Second sheet')
  await page.getByRole('navigation', { name: 'Sheets', exact: true }).getByRole('button', { name: 'Main', exact: false }).click()
  await expect(page.getByRole('textbox', { name: 'Code cell 2', exact: true })).toHaveValue('answer = 21\nanswer * 2\n')
  await expect(page.getByRole('textbox', { name: 'Text cell 1', exact: true })).toHaveValue('Experiment notes\nExpected result: 42.')
  page.once('dialog', dialog => dialog.accept())
  await page.getByRole('button', { name: 'Delete cell 1', exact: true }).click()
  await save(page)
  const document = JSON.parse((await stored(page, project.id)).document)
  expect(document.sheets).toHaveLength(2)
  expect(document.sheets[0].cells).toHaveLength(1)
  const internal = await coreProject(project.title)
  expect((await rpc('run.registry', { project_id: internal.id })).runs).toEqual([])
})

test('stale editor keeps its draft on conflict and reload requires explicit discard', async ({ page, context }) => {
  await login(page)
  const project = await makeProject(page)
  await initialize(page, project.id)
  await page.goto(`/projects/${project.id}`)
  const other = await context.newPage()
  await other.goto(`/projects/${project.id}`)
  await expect(other.getByRole('textbox', { name: 'Code cell 1', exact: true })).toBeVisible()
  await page.getByRole('textbox', { name: 'Code cell 1', exact: true }).fill('"First editor"')
  await save(page)
  await other.getByRole('textbox', { name: 'Code cell 1', exact: true }).fill('"My unsaved draft"')
  await other.getByRole('button', { name: 'Save notebook', exact: true }).click()
  await expect(other.getByRole('alert')).toContainText('notebook has changed')
  await expect(other.getByRole('textbox', { name: 'Code cell 1', exact: true })).toHaveValue('"My unsaved draft"')
  const download = other.waitForEvent('download')
  await other.getByRole('button', { name: 'Download draft JSON', exact: true }).click()
  const exported = await download
  expect(JSON.parse(await readFile((await exported.path())!, 'utf8')).sheets[0].cells[0].source).toBe('"My unsaved draft"')
  other.once('dialog', dialog => dialog.dismiss())
  await other.getByRole('button', { name: 'Reload saved version', exact: true }).click()
  await expect(other.getByRole('textbox', { name: 'Code cell 1', exact: true })).toHaveValue('"My unsaved draft"')
  other.once('dialog', dialog => dialog.accept())
  await other.getByRole('button', { name: 'Reload saved version', exact: true }).click()
  await expect(other.getByRole('textbox', { name: 'Code cell 1', exact: true })).toHaveValue('"First editor"')
  await expect(other.getByTestId('notebook-save-status')).toHaveText('All changes saved')
  await other.close()
})

test('cell exports suggest draft bindings and edit multiple declarations at once', async ({ page }) => {
  await login(page)
  const project = await makeProject(page)
  await initialize(page, project.id)
  await page.goto(`/projects/${project.id}`)
  const editor = page.getByRole('textbox', { name: 'Code cell 1', exact: true })
  const code = 'dataset = [1, 2]\nexport dataset as samples\nleft, right = [3, 4]\ndef build():\n  hidden = 5\n  hidden\ndataset.push!(6)\n'
  await editor.fill(code)
  const open = page.getByRole('button', { name: 'Exports for cell 1', exact: true })
  const dialog = page.getByRole('dialog', { name: 'Exports · Cell 1' })
  const choice = (name: string) => dialog.getByRole('checkbox', { name, exact: true })
  const apply = dialog.getByRole('button', { name: 'Apply', exact: true })
  await open.click()
  await expect(choice('dataset')).toBeChecked()
  await expect(dialog.getByRole('textbox', { name: 'Export name for dataset' })).toHaveValue('samples')
  await expect(choice('hidden')).toHaveCount(0)
  await expect(choice('left')).not.toBeChecked()
  await choice('left').check()
  await choice('right').check()
  const alias = dialog.getByRole('textbox', { name: 'Export name for right' })
  await alias.fill('samples')
  await apply.click()
  await expect(dialog.getByRole('alert')).toContainText('Duplicate export name')
  await alias.fill('right_value')
  await apply.click()
  await expect(dialog).toBeHidden()
  const base = code.replace('export dataset as samples\n', '')
  const updated = base + 'export dataset as samples, left, right as right_value\n'
  await expect(editor).toHaveValue(updated)
  await save(page)
  await page.reload()
  await expect(editor).toHaveValue(updated)
  await open.click()
  await expect(choice('left')).toBeChecked()
  await choice('dataset').uncheck()
  await choice('left').uncheck()
  await choice('right').uncheck()
  await apply.click()
  await expect(editor).toHaveValue(base)
  await save(page)
  expect(JSON.parse((await stored(page, project.id)).document).sheets[0].cells[0].source).toBe(base)
})

test('a lost save response retries the same durable command', async ({ page }) => {
  await login(page)
  const project = await makeProject(page)
  await initialize(page, project.id)
  await page.goto(`/projects/${project.id}`)
  await page.getByRole('textbox', { name: 'Code cell 1', exact: true }).fill('42\n')
  const bodies: any[] = []
  let committed: any
  await page.route(`**${pathFor(project.id)}`, async route => {
    if (route.request().method() !== 'PUT') return route.continue()
    bodies.push(route.request().postDataJSON())
    if (bodies.length === 1) {
      const response = await route.fetch()
      expect(response.status()).toBe(200)
      committed = await response.json()
      await route.abort('failed')
    } else await route.continue()
  })
  await page.getByRole('button', { name: 'Save notebook', exact: true }).click()
  await expect(page.getByRole('alert')).toBeVisible()
  await page.getByRole('button', { name: 'Retry save', exact: true }).click()
  await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved')
  expect(bodies).toHaveLength(2)
  expect(bodies[1]).toEqual(bodies[0])
  expect(await stored(page, project.id)).toEqual(committed.notebook)
  const repeated = await request(page, pathFor(project.id), 'PUT', bodies[0])
  expect(repeated.status()).toBe(200)
  expect((await repeated.json()).notebook).toEqual(committed.notebook)
})

test('document API enforces ACL, CSRF, validation and private identifiers', async ({ page, browser, baseURL }) => {
  await login(page)
  const project = await makeProject(page)
  const initial = await initialize(page, project.id)
  const path = pathFor(project.id)
  const command = { command_id: crypto.randomUUID(), base_revision: initial.revision, document: initial.document }
  const other = await browser.newContext({ baseURL })
  try {
    const bob = await other.newPage()
    await login(bob, 'Bob')
    const bobId = (await (await request(bob, '/api/session')).json()).account.id
    expect((await request(bob, path)).status()).toBe(404)
    expect((await request(bob, path, 'POST', {})).status()).toBe(404)
    expect((await request(bob, path, 'PUT', command)).status()).toBe(404)
    expect((await page.request.put(path, { data: command })).status()).toBe(403)
    await request(page, `/api/projects/${project.id}/memberships`, 'POST', { account_id: bobId, role: 'viewer' })
    expect((await request(bob, path)).status()).toBe(200)
    expect((await request(bob, path, 'POST', {})).status()).toBe(403)
    expect((await request(bob, path, 'PUT', command)).status()).toBe(403)
    await bob.goto(`/projects/${project.id}`)
    await expect(bob.getByRole('textbox', { name: 'Code cell 1', exact: true })).toHaveAttribute('readonly')
    await expect(bob.getByRole('button', { name: 'Save notebook', exact: true })).toHaveCount(0)
    await request(page, `/api/projects/${project.id}/memberships`, 'POST', { account_id: bobId, role: 'editor' })
    const edited = JSON.parse(initial.document)
    edited.sheets[0].cells[0].source = '"Collaborator"'
    expect((await request(bob, path, 'PUT', { ...command, document: JSON.stringify(edited) })).status()).toBe(200)
    const invalid = await request(page, path, 'PUT', { ...command, command_id: crypto.randomUUID(), base_revision: (await stored(page, project.id)).revision, document: '{}' })
    expect(invalid.status()).toBe(400)
    expect(await invalid.text()).not.toMatch(/\/private\/|core_project_id|revisions\/|agent.sock/)
    expect((await request(page, path, 'PUT', { ...command, core_project_id: 'forged' })).status()).toBe(400)
    expect((await request(page, path, 'POST', { project_id: 'forged' })).status()).toBe(400)
    const current = await stored(page, project.id)
    expect(JSON.parse(current.document).sheets[0].cells[0].source).toBe('"Collaborator"')
    expect(JSON.stringify(current)).not.toMatch(/core_project_id|owner_account_id|directory|agent.sock/)
    await request(page, `/api/projects/${project.id}/memberships/${bobId}`, 'DELETE')
    expect((await request(bob, path)).status()).toBe(404)
    expect((await request(bob, path, 'PUT', { ...command, base_revision: current.revision })).status()).toBe(404)
  } finally { await other.close() }
})

test('web edits preserve bundled files, formatting and unknown metadata without execution', async ({ page }) => {
  await login(page)
  const project = await makeProject(page)
  const initial = await initialize(page, project.id)
  const internal = await coreProject(project.title)
  const document = JSON.parse(initial.document)
  document.modules = [{ id: 'helpers', path: 'modules/helpers.s' }]
  document.custom_metadata = { retained: ['future', 42] }
  document.version = 4
  document.inputs = []
  document.boards = []
  document.dependencies = []
  document.sheets[0].cells.push({ id: '2', kind: 'text', source: 'Formatted text', formatting: { version: 2, runs: [], paragraphs: [] } })
  const files = { 'modules/helpers.s': Buffer.from('package helpers\nexport answer\ndef answer(): 42\n').toString('base64'), 'resources/data.txt': Buffer.from('preserved resource').toString('base64') }
  await rpc('project.put', { project_id: internal.id, command_id: 'seed-files', base_revision: initial.revision, document: JSON.stringify(document), files })
  await page.goto(`/projects/${project.id}`)
  await expect(page.getByRole('textbox', { name: 'Text cell 2', exact: true })).toBeEditable()
  await page.getByRole('textbox', { name: 'Code cell 1', exact: true }).fill('value = 42\n')
  await save(page)
  const saved = await stored(page, project.id)
  const snapshot = await rpc('revision.get', { project_id: internal.id, revision: saved.revision })
  expect(snapshot.files).toEqual(files)
  expect(JSON.parse(snapshot.document).custom_metadata).toEqual(document.custom_metadata)
  expect(JSON.parse(snapshot.document).sheets[0].cells[1]).toEqual(document.sheets[0].cells[1])
  expect((await rpc('run.registry', { project_id: internal.id })).runs).toEqual([])
})

test('editor layout, navigation guard and offline loading recovery', async ({ page }) => {
  const errors: string[] = []
  page.on('pageerror', error => errors.push(error.message))
  await login(page)
  const project = await makeProject(page)
  await initialize(page, project.id)
  await page.goto(`/projects/${project.id}`)
  await page.getByRole('textbox', { name: 'Code cell 1', exact: true }).fill('amount = 21\namount * 2\n')
  await page.getByRole('button', { name: 'Text cell', exact: true }).click()
  await page.getByRole('textbox', { name: 'Text cell 2', exact: true }).fill('A saved notebook with code and notes.')
  await save(page)
  await page.getByTestId('project-heading').click()
  for (const colorScheme of ['light', 'dark'] as const) {
    await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' })
    for (const width of [1280, 375, 320]) {
      await page.setViewportSize({ width, height: 900 })
      await page.evaluate(() => { window.scrollTo(0, 0); return new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))) })
      await expect(page.locator('.topbar')).toHaveCount(1)
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
      if (width !== 320) await page.screenshot({ path: `../build/notebook-editor-${colorScheme}-${width}.png`, fullPage: true })
    }
  }
  await page.getByRole('textbox', { name: 'Text cell 2', exact: true }).fill('Do not discard this draft.')
  page.once('dialog', dialog => dialog.dismiss())
  await page.getByRole('link', { name: 'Notebook Library', exact: true }).click()
  await expect(page.getByRole('textbox', { name: 'Text cell 2', exact: true })).toHaveValue('Do not discard this draft.')
  await save(page)
  await page.route(`**${pathFor(project.id)}`, route => route.fulfill({ status: 503, contentType: 'application/json', body: JSON.stringify({ error: { message: 'The notebook service is unavailable.' } }) }))
  await page.reload()
  await expect(page.getByRole('alert')).toContainText('unavailable')
  await expect(page.getByRole('button', { name: 'Create notebook', exact: true })).toHaveCount(0)
  await page.unroute(`**${pathFor(project.id)}`)
  await page.getByRole('button', { name: 'Retry loading', exact: true }).click()
  await expect(page.getByRole('textbox', { name: 'Text cell 2', exact: true })).toHaveValue('Do not discard this draft.')
  expect(errors).toEqual([])
})
