import { expect, test, type Page } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { execFileSync } from 'node:child_process'
async function login(page: Page, user = 'Alice') {
  await page.goto('/'); await page.getByRole('button', { name: 'Continue with GitHub' }).click(); await page.getByRole('button', { name: `Sign in as ${user}` }).click(); await expect(page.getByTestId('account-name')).toHaveText(user)
}
async function request(page: Page, path: string, method = 'GET', data?: unknown) {
  const token = (await page.context().cookies()).find(cookie => cookie.name === 'orbit-csrf')?.value
  return page.request.fetch(path, { method, data, headers: { Accept: 'application/json', Origin: new URL(page.url()).origin, ...(token ? { 'X-CSRF-Token': decodeURIComponent(token) } : {}) } })
}
async function project(page: Page) {
  const created = (await (await request(page, '/api/projects', 'POST', { title: `Files ${crypto.randomUUID()}` })).json()).project
  await request(page, `/api/projects/${created.id}/notebook`, 'POST', {})
  return created
}
const base = (id: string) => `/api/projects/${id}/notebook`
async function stored(page: Page, id: string) { return (await (await request(page, base(id))).json()).notebook }
async function save(page: Page) { await page.getByRole('button', { name: 'Save notebook', exact: true }).click(); await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved') }
function zip(entries: Record<string, string | Buffer>, symlink = false) {
  return execFileSync('python3', ['-c', 'import sys,json,base64,io,zipfile\nv=json.load(sys.stdin); b=io.BytesIO()\nwith zipfile.ZipFile(b,"w",zipfile.ZIP_DEFLATED) as z:\n for name,data in v["entries"].items():\n  info=zipfile.ZipInfo(name); info.external_attr=(0o120777 if v["symlink"] else 0o100644)<<16; z.writestr(info,base64.b64decode(data))\nsys.stdout.buffer.write(b.getvalue())'], { input: JSON.stringify({ entries: Object.fromEntries(Object.entries(entries).map(([path, data]) => [path, Buffer.from(data).toString('base64')])), symlink }) })
}
async function bundle(page: Page) { const p = await project(page); return { p, document: (await stored(page, p.id)).document } }

test('module and binary file changes save atomically, preserve hidden resources and execute imported helper', async ({ page }) => {
  await login(page); const p = await project(page); await page.goto(`/projects/${p.id}`)
  await page.getByRole('button', { name: 'New module', exact: true }).click(); await page.getByLabel('Module name', { exact: true }).fill('helpers'); await page.getByRole('button', { name: 'Add to draft' }).click()
  await page.getByRole('textbox', { name: 'Module helpers', exact: true }).fill('package helpers\nexport answer\ndef answer(): 42\n')
  await page.getByLabel('Auto-import into sheets').check(); await save(page)
  await page.getByRole('button', { name: 'Add resource…', exact: true }).click(); await page.getByLabel('Resource file', { exact: true }).setInputFiles({ name: 'data.bin', mimeType: 'application/octet-stream', buffer: Buffer.from([0, 1, 255, 128]) }); await page.getByLabel('Project path', { exact: true }).fill('.hidden/data.bin'); await page.getByRole('button', { name: 'Add to draft' }).click(); await save(page)
  await page.reload(); await page.getByRole('navigation', { name: 'Project files', exact: true }).getByRole('button', { name: '.hidden/data.bin', exact: false }).click(); await expect(page.getByTestId('project-file-editor')).toContainText('Binary file · 4 bytes')
  const saved = await stored(page, p.id), files = await request(page, `${base(p.id)}/files?revision=${saved.revision}`)
  expect((await files.json()).entries.map((entry: any) => entry.path)).toEqual(['.hidden/data.bin', 'modules/helpers.s'])
  expect(await (await request(page, `${base(p.id)}/download?revision=${saved.revision}&path=.hidden%2Fdata.bin`)).body()).toEqual(Buffer.from([0, 1, 255, 128]))
  await page.getByRole('navigation', { name: 'Sheets', exact: true }).getByRole('button', { name: 'Main', exact: false }).click(); await page.getByRole('textbox', { name: 'Code cell 1', exact: true }).fill('answer()\n'); await save(page)
  await expect(page.getByRole('button', { name: 'Run cell 1', exact: true })).toBeEnabled(); await page.getByRole('button', { name: 'Run cell 1', exact: true }).click(); await expect(page.getByLabel('Cell result', { exact: true })).toContainText('42')
  await page.getByRole('navigation', { name: 'Project files' }).getByRole('button', { name: 'helpers', exact: false }).click(); page.once('dialog', dialog => dialog.accept()); await page.getByRole('button', { name: 'Delete module…' }).click(); await save(page)
  const current = JSON.parse((await stored(page, p.id)).document); expect(current.modules).toEqual([]); expect(current.auto_imports).toEqual([])
})

test('file conflicts keep the complete draft; export historical revision and recover draft bundle', async ({ page, context }) => {
  await login(page); const p = await project(page); const initial = await stored(page, p.id); await page.goto(`/projects/${p.id}`)
  await page.getByRole('button', { name: 'New module', exact: true }).click(); await page.getByLabel('Module name', { exact: true }).fill('draft'); await page.getByRole('button', { name: 'Add to draft' }).click(); await page.getByRole('textbox', { name: 'Module draft', exact: true }).fill('package draft\nexport value\ndef value(): 17\n')
  const other = await context.newPage(); await other.goto(`/projects/${p.id}`); await other.getByRole('textbox', { name: 'Code cell 1', exact: true }).fill('"newer revision"'); await save(other); await other.close()
  await page.getByRole('button', { name: 'Save notebook', exact: true }).click(); await expect(page.getByRole('alert').filter({ hasText: 'has changed' })).toBeVisible()
  await expect(page.getByRole('textbox', { name: 'Module draft', exact: true })).toHaveValue('package draft\nexport value\ndef value(): 17\n')
  const dl = page.waitForEvent('download'); await page.getByRole('button', { name: 'Export draft…' }).click(); const bytes = await readFile((await (await dl).path())!)
  const inspect = await request(page, '/api/imports/inspect', 'POST', { archive: bytes.toString('base64') }); expect(inspect.status()).toBe(200); expect((await inspect.json()).summary.modules).toBe(1)
  await page.getByRole('button', { name: 'Revisions…' }).click(); await expect(page.getByRole('dialog', { name: 'Saved revisions' }).getByRole('button', { name: /^Export revision/ })).toHaveCount(2)
  const old = await request(page, `${base(p.id)}/archive?revision=${initial.revision}`); expect(old.status()).toBe(200); expect((await request(page, '/api/imports/inspect', 'POST', { archive: (await old.body()).toString('base64') })).status()).toBe(200)
})

test('ZIP and folder imports retain full document, int64 metadata, files and idempotent receipts without running', async ({ page }) => {
  await login(page); const { document } = await bundle(page)
  const authored = document.replace('"version":1', '"version":1') .replace(/}$/, ',"future":{"max":9223372036854775807}}')
  const archive = zip({ 'Local.sputnikbook/project.json': authored, 'Local.sputnikbook/.settings': 'retained', 'Local.sputnikbook/resources/blob.bin': Buffer.from([0, 255, 3]) })
  await page.goto('/'); await page.getByRole('button', { name: 'Import Notebook…', exact: true }).click(); await page.getByLabel('Notebook ZIP', { exact: true }).setInputFiles({ name: 'Local.sputnikbook.zip', mimeType: 'application/zip', buffer: archive })
  await expect(page.getByRole('dialog', { name: 'Import Notebook', exact: true })).toContainText('2 files'); await page.screenshot({ path: '../build/notebook-import-light.png' }); await page.getByLabel('Project title', { exact: true }).fill('Imported full notebook'); await page.getByRole('button', { name: 'Import as new notebook', exact: true }).click(); await expect(page.getByTestId('project-heading')).toHaveText('Imported full notebook')
  const id = page.url().split('/').at(-1)!, first = await stored(page, id)
  expect(first.document).toBe(authored)
  await page.getByRole('textbox', { name: 'Code cell 1', exact: true }).fill('"int64 metadata retained"'); await save(page); expect((await stored(page, id)).document).toContain('9223372036854775807')
  const revisions = await request(page, `${base(id)}/revisions`); expect((await revisions.json()).revisions).toHaveLength(2)
  const exported = await request(page, `${base(id)}/archive?revision=${first.revision}`); expect(exported.status()).toBe(200)
  const inspected = await request(page, '/api/imports/inspect', 'POST', { archive: (await exported.body()).toString('base64') }); const { fingerprint } = await inspected.json()
  const command = { command_id: 'import_' + crypto.randomUUID().replaceAll('-', ''), title: 'Idempotent import', fingerprint, archive: (await exported.body()).toString('base64') }
  const [once, twice] = await Promise.all([request(page, '/api/imports', 'POST', command), request(page, '/api/imports', 'POST', command)])
  expect(once.status()).toBe(200); expect((await twice.json()).project.id).toBe((await once.json()).project.id)
  expect((await (await request(page, `/api/imports/${command.command_id}`)).json()).state).toBe('complete')
  const folder = { entries: [{ path: 'Folder.sputnikbook/project.json', data: Buffer.from(authored).toString('base64') }, { path: 'Folder.sputnikbook/.resource', data: Buffer.from('hidden').toString('base64') }] }
  expect((await request(page, '/api/imports/inspect', 'POST', folder)).status()).toBe(200)
  const registry = await request(page, `/api/projects/${id}/execution`); expect((await registry.json()).runs).toEqual([])
})

test('imports reject unsafe archives and unauthorized file/dependency operations', async ({ page, browser }) => {
  await login(page); const { p, document } = await bundle(page), snapshot = await stored(page, p.id)
  for (const entries of [ { 'project.json': document, '../escape': 'bad' }, { 'project.json': document, '/absolute': 'bad' }, { 'project.json': document, 'a': 'bad', 'A': 'bad' }, { 'project.json': document, 'file': 'bad', 'file/child': 'bad' }, { 'project.json': '{}' } ]) {
    const response = await request(page, '/api/imports/inspect', 'POST', { archive: zip(entries).toString('base64') }); expect([400, 422]).toContain(response.status()); expect(await response.text()).not.toMatch(/\/private\/|agent.sock|core_project_id/)
  }
  expect([400, 422]).toContain((await request(page, '/api/imports/inspect', 'POST', { archive: zip({ 'project.json': document }, true).toString('base64') })).status())
  for (const changes of [{ '../escape': { encoding: 'utf8', data: 'x' } }, { 'bad': { encoding: 'base64', data: '?invalid?' } }, { 'a': { encoding: 'utf8', data: 'a' }, 'A': { encoding: 'utf8', data: 'b' } }]) expect([400, 422]).toContain((await request(page, base(p.id), 'PUT', { command_id: crypto.randomUUID(), base_revision: snapshot.revision, document, changes })).status())
  const other = await browser.newContext(); const bob = await other.newPage(); await login(bob, 'Bob'); const bobId = await bob.getByTestId('account-id').textContent(); await request(page, `/api/projects/${p.id}/memberships`, 'POST', { account_id: bobId, role: 'viewer' })
  await bob.goto(`/projects/${p.id}`); await bob.getByRole('button', { name: 'Dependencies…', exact: true }).click(); await expect(bob.getByRole('dialog', { name: 'Dependencies', exact: true })).toContainText('Only the project owner'); expect((await request(bob, `/api/projects/${p.id}/dependencies`, 'POST', { command_id: 'denied', action: 'install_sputnik', name: 'test/web-probe', version: '1.0.0', variant: '', allow_native: false, build_from_source: false, allow_native_large: false })).status()).toBe(403)
  await request(page, `/api/projects/${p.id}/memberships/${bobId}`, 'DELETE'); expect((await request(bob, `${base(p.id)}/files?revision=${snapshot.revision}`)).status()).toBe(404); expect((await request(bob, `${base(p.id)}/archive?revision=${snapshot.revision}`)).status()).toBe(404); expect((await request(bob, `/api/projects/${p.id}/dependencies`)).status()).toBe(404); await other.close()
})

test('registry packages install, recover an accepted response loss, and remove through owner UI', async ({ page }) => {
  await login(page); const p = await project(page); await page.goto(`/projects/${p.id}`); await page.getByRole('button', { name: 'Dependencies…', exact: true }).click()
  await page.getByLabel('Registry package', { exact: true }).fill('test/web-probe'); await page.getByRole('button', { name: 'Find package', exact: true }).click(); await expect(page.getByLabel('Version', { exact: true })).toHaveValue('1.0.0'); await expect(page.getByLabel('Build', { exact: true })).toHaveValue('source')
  let lost = false
  await page.route(`**/api/projects/${p.id}/dependencies`, async route => { if (!lost && route.request().method() === 'POST') { lost = true; await route.fetch(); await route.abort('failed') } else await route.continue() })
  await page.getByRole('button', { name: 'Install package', exact: true }).click(); await expect(page.getByRole('list', { name: 'Installed packages' })).toContainText('web-probe', { timeout: 20_000 }); await expect(page.getByRole('list', { name: 'Installed packages' }).locator('strong')).toHaveText('web-probe'); await expect(page.getByRole('button', { name: 'Remove package test/web-probe', exact: true })).toBeEnabled(); expect(lost).toBe(true)
  const jobs = (await (await request(page, `/api/projects/${p.id}/dependencies`)).json()).jobs; expect(jobs).toHaveLength(1); expect(jobs[0].state).toBe('succeeded')
  await expect(page.getByRole('list', { name: 'Installed packages' })).toContainText('Shared')
  page.once('dialog', dialog => dialog.accept()); await page.getByRole('button', { name: 'Remove package test/web-probe', exact: true }).click(); await expect(page.getByRole('dialog', { name: 'Dependencies', exact: true })).toContainText('No Sputnik packages installed.')
  await page.getByRole('button', { name: 'Find package', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Use installed package', exact: true })).toBeEnabled()
  await page.getByLabel('Package storage', { exact: true }).selectOption('local')
  await page.getByRole('button', { name: 'Install package', exact: true }).click()
  await expect(page.getByRole('list', { name: 'Installed packages' })).toContainText('This notebook', { timeout: 20_000 })
  const mutation = { command_id: 'policy', action: 'install_sputnik', name: 'test/web-probe', version: '1.0.0', variant: 'source', allow_native: true, build_from_source: false, allow_native_large: false }
  expect((await request(page, `/api/projects/${p.id}/dependencies`, 'POST', mutation)).status()).toBe(403)
  expect((await request(page, `/api/projects/${p.id}/dependencies`, 'POST', { ...mutation, allow_native: false, name: '/private/tmp/package' })).status()).toBe(422)
  expect((await request(page, `/api/projects/${p.id}/dependencies`, 'POST', { ...mutation, allow_native: false, local_source: '/private/tmp' })).status()).toBe(400)
})

test('native builds explain required permissions, reset consent per build and link to worker grants', async ({ page }) => {
  await login(page); const p = await project(page)
  await page.route(`**/api/projects/${p.id}/dependencies`, route => route.fulfill({ json: { can_manage: true, native_allowed: true, package_scopes: ['shared', 'local'], packages: [], jobs: [] } }))
  await page.route(`**/api/projects/${p.id}/dependencies/catalog?*`, route => {
    const version = new URL(route.request().url()).searchParams.get('version')
    return route.fulfill({ json: version ? { recommended_variant: 'native-a', artifacts: ['native-a', 'native-b'].map(variant => ({ variant, shared_installed: variant === 'native-b', size: 90_000_000, runtime_grants: ['ffi.call=*', 'ffi.load=*', 'fs.read=/models'], target: { os: 'linux', arch: 'x86_64' }, host_selection: { compatible: true, reason: '', allow_native: true, build_from_source: false } })) } : { versions: [{ version: '1.0.0', yanked: false }] } })
  })
  await page.route(`**/api/projects/${p.id}/worker-settings?*`, async route => {
    const response = await route.fetch()
    await route.fulfill({ response, json: { ...await response.json(), allowed_grants: ['ffi.call=*', 'ffi.load=*', 'time.now=*', 'fs.read=*'] } })
  })
  await page.goto(`/projects/${p.id}`); await page.getByRole('button', { name: 'Dependencies…', exact: true }).click()
  await page.getByLabel('Registry package', { exact: true }).fill('torch'); await page.getByRole('button', { name: 'Find package', exact: true }).click()
  const storage = page.getByLabel('Package storage', { exact: true })
  await expect(storage).toHaveValue('shared')
  await expect(page.getByLabel('Build', { exact: true })).toHaveValue('native-b')
  await expect(page.getByRole('button', { name: 'Use installed package', exact: true })).toBeDisabled()
  await expect(page.getByLabel('Allow packages up to 2 GiB', { exact: true })).toHaveCount(0)
  await storage.selectOption('local')
  await page.getByLabel('Build', { exact: true }).selectOption('native-a')
  const install = page.getByRole('button', { name: 'Install package', exact: true })
  await expect(install).toBeDisabled(); await expect(page.getByRole('dialog', { name: 'Dependencies', exact: true })).toContainText('requires explicit permission')
  await page.getByLabel('Allow native package', { exact: true }).check(); await expect(install).toBeDisabled()
  await page.getByLabel('Allow packages up to 2 GiB', { exact: true }).check(); await expect(install).toBeEnabled()
  await page.getByLabel('Build', { exact: true }).selectOption('native-b'); await expect(install).toBeDisabled(); await expect(page.getByLabel('Allow native package', { exact: true })).not.toBeChecked()
  await expect(page.getByLabel('Required worker grants', { exact: true })).toContainText('fs.read=/models')
  await page.getByRole('button', { name: 'Add package grants…', exact: true }).click()
  const settings = page.getByRole('dialog', { name: 'Environments and worker settings', exact: true })
  await expect(settings.getByRole('button', { name: 'Remove grant ffi.call=*', exact: true })).toBeVisible()
  await expect(settings.getByRole('button', { name: 'Remove grant ffi.load=*', exact: true })).toBeVisible()
  await expect(settings).toContainText('Review unavailable grants: fs.read=/models')
  await settings.getByLabel('Search available grants').fill('time')
  await expect(settings.getByRole('option', { name: 'fs.read=*', exact: true })).toHaveCount(0)
  await settings.getByLabel('Available grant', { exact: true }).selectOption('time.now=*')
  await settings.getByRole('button', { name: 'Add to draft', exact: true }).click()
  await expect(settings.getByRole('button', { name: 'Remove grant time.now=*', exact: true })).toBeVisible()
})

test('import resumes the same command across reload and accepted response loss', async ({ page }) => {
  await login(page); const { document } = await bundle(page)
  const archive = zip({ 'Resume.sputnikbook/project.json': document, 'Resume.sputnikbook/resources/data.txt': 'imported once' })
  const title = `Resume ${crypto.randomUUID()}`
  await page.goto('/'); await page.getByRole('button', { name: 'Import Notebook…', exact: true }).click()
  const select = async () => { const input = page.getByLabel('Notebook ZIP', { exact: true }); await expect(input).toBeEnabled(); await input.setInputFiles({ name: 'Resume.sputnikbook.zip', mimeType: 'application/zip', buffer: archive }); await expect(page.getByRole('dialog', { name: 'Import Notebook', exact: true })).toContainText('1 files') }
  await select(); await page.getByLabel('Project title', { exact: true }).fill(title)
  let attempts = 0; const commands: string[] = []
  await page.route('**/api/imports', async route => { commands.push(route.request().postDataJSON().command_id); attempts++; if (attempts === 2) await route.fetch(); await route.abort('failed') })
  await page.getByRole('button', { name: 'Import as new notebook', exact: true }).click(); await expect(page.getByRole('alert')).toContainText('Failed to fetch')
  await page.reload(); await page.getByRole('button', { name: 'Import Notebook…', exact: true }).click(); await expect(page.getByRole('dialog', { name: 'Import Notebook', exact: true })).toContainText('An import is pending')
  await select(); await page.getByRole('button', { name: 'Resume import', exact: true }).click(); await expect(page.getByRole('alert')).toContainText('Failed to fetch')
  await page.getByRole('button', { name: 'Check import status', exact: true }).click(); await expect(page.getByTestId('project-heading')).toHaveText(title)
  expect(commands).toHaveLength(2); expect(commands[0]).toBe(commands[1])
  expect((await (await request(page, '/api/projects')).json()).projects.filter((item: any) => item.title === title)).toHaveLength(1)
})

test('file save retries retain command identity and source layout fits desktop and mobile themes', async ({ page }) => {
  await login(page); const p = await project(page); await page.goto(`/projects/${p.id}`)
  await page.getByRole('button', { name: 'New module', exact: true }).click(); await page.getByLabel('Module name', { exact: true }).fill('analysis'); await page.getByRole('button', { name: 'Add to draft' }).click()
  await page.getByRole('textbox', { name: 'Module analysis', exact: true }).fill('package analysis\nexport calculate\ndef calculate(value): value * 2\n')
  let lost = false; const commands: any[] = []
  await page.route(`**${base(p.id)}`, async route => { if (route.request().method() !== 'PUT') return route.continue(); commands.push(route.request().postDataJSON()); if (!lost) { lost = true; await route.fetch(); await route.abort('failed') } else await route.continue() })
  await page.getByRole('button', { name: 'Save notebook', exact: true }).click(); await expect(page.getByRole('alert')).toContainText('Failed to fetch'); await page.getByRole('button', { name: 'Retry save', exact: true }).click(); await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved')
  expect(commands).toHaveLength(2); expect(commands[1]).toEqual(commands[0]); expect((await (await request(page, `${base(p.id)}/revisions`)).json()).revisions).toHaveLength(2)
  const errors: string[] = []; page.on('pageerror', error => errors.push(error.message))
  for (const colorScheme of ['light', 'dark'] as const) {
    await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' })
    for (const width of [1280, 375, 320]) {
      await page.setViewportSize({ width, height: 900 })
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
      if (width !== 320) await page.screenshot({ path: `../build/notebook-sources-${colorScheme}-${width}.png`, fullPage: true })
      await page.getByRole('button', { name: 'Dependencies…', exact: true }).click()
      expect(await page.getByRole('dialog', { name: 'Dependencies', exact: true }).evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true)
      if (width === 1280 || width === 375) await page.screenshot({ path: `../build/notebook-dependencies-${colorScheme}-${width}.png` })
      await page.getByRole('button', { name: 'Close dependencies', exact: true }).click()
    }
  }
  expect(errors).toEqual([])
})
