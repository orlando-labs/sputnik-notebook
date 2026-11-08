import { expect, test, type Page } from '@playwright/test'
import { readFile } from 'node:fs/promises'
async function login(page: Page, user = 'Alice') { await page.goto('/'); await page.getByRole('button', { name: 'Continue with GitHub' }).click(); await page.getByRole('button', { name: `Sign in as ${user}` }).click(); await expect(page.getByTestId('account-name')).toHaveText(user) }
async function request(page: Page, path: string, method = 'GET', data?: unknown) {
  const token = (await page.context().cookies()).find(cookie => cookie.name === 'orbit-csrf')?.value
  return page.request.fetch(path, { method, data, headers: { Accept: 'application/json', Origin: new URL(page.url()).origin, ...(token ? { 'X-CSRF-Token': decodeURIComponent(token) } : {}) } })
}
const endpoint = (id: string) => `/api/projects/${id}/notebook`
async function stored(page: Page, id: string) { return (await (await request(page, endpoint(id))).json()).notebook }
async function book(page: Page, extra: any = {}, changes = {}) {
  const created = await request(page, '/api/projects', 'POST', { title: 'Editor ' + crypto.randomUUID() }); expect(created.status()).toBe(201); const project = (await created.json()).project
  const initial = (await (await request(page, endpoint(project.id), 'POST', {})).json()).notebook
  const document = Object.assign(JSON.parse(initial.document), extra, { future: { exact: '__exact__' } })
  const response = await request(page, endpoint(project.id), 'PUT', { command_id: crypto.randomUUID(), base_revision: initial.revision, document: JSON.stringify(document).replace('"__exact__"', '9223372036854775807'), changes }); expect(response.status(), await response.text()).toBe(200)
  await page.goto(`/projects/${project.id}`); await expect(page.getByLabel('Code cell 1', { exact: true })).toBeVisible()
  return project
}
async function save(page: Page) { await page.getByRole('button', { name: 'Save notebook', exact: true }).click(); await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved') }
async function localReady(page: Page) { await expect(page.getByTestId('draft-journal-status')).toHaveText(/Local recovery copy saved/) }
async function reloadDraft(page: Page) { page.once('dialog', dialog => dialog.accept()); await page.reload(); await page.getByTestId('draft-recovery').locator('summary').click(); await page.screenshot({ path: '../build/draft-recovery-light-1280.png', fullPage: true }); await page.getByRole('button', { name: 'Restore local draft', exact: true }).first().click() }
async function addModule(page: Page, id = 'helpers') { await page.getByRole('button', { name: 'New module', exact: true }).click(); await page.getByLabel('Module name', { exact: true }).fill(id); await page.getByRole('button', { name: 'Add to draft', exact: true }).click() }
const sheetNav = (page: Page) => page.getByRole('navigation', { name: 'Sheets', exact: true })
const files = (page: Page) => page.getByRole('navigation', { name: 'Project files', exact: true })

test('sheet duplicate/reorder/delete preserves metadata, fresh identities and board controllers without execution', async ({ page }) => {
  await login(page)
  const p = await book(page, { version: 4, inputs: [], dependencies: [], boards: [{ id: 'b', title: 'Report', sheet: 'main', columns: 2, components: [] }], sheets: [{ id: 'main', title: 'Main', future: { keep: true }, cells: [{ id: '1', kind: 'code', source: 'score = 1\n', mode: 'manual' }, { id: '2', kind: 'text', source: 'Notes', formatting: { version: 1, runs: [{ start: 0, length: 5, bold: true }] }, future: 7 }] }] })
  await expect(page.getByRole('button', { name: 'Delete sheet…', exact: true })).toBeDisabled()
  await page.getByRole('button', { name: 'Duplicate sheet', exact: true }).click(); await expect(page.getByLabel('Sheet title', { exact: true })).toHaveValue('Main copy')
  await page.getByRole('button', { name: 'Move sheet up', exact: true }).click(); await expect(sheetNav(page).getByRole('button').first()).toContainText('Main copy')
  await sheetNav(page).getByRole('button', { name: /^Main 2$/ }).click(); await page.getByRole('button', { name: 'Delete sheet…', exact: true }).click()
  const dialog = page.getByRole('dialog', { name: 'Delete sheet Main', exact: true }); await expect(dialog).toContainText('1 linked boards'); await dialog.getByRole('button', { name: 'Cancel', exact: true }).click(); await expect(sheetNav(page).getByRole('button')).toHaveCount(2)
  await page.getByRole('button', { name: 'Delete sheet…', exact: true }).click(); await dialog.getByRole('button', { name: 'Delete from draft', exact: true }).click(); await save(page)
  const saved = await stored(page, p.id), d = JSON.parse(saved.document); expect(d.sheets).toHaveLength(1); expect(d.sheets[0].cells.map((cell: any) => cell.id)).not.toContain('1'); expect(d.sheets[0].cells.map((cell: any) => cell.id)).not.toContain('2'); expect(d.boards[0].sheet).toBe(d.sheets[0].id); expect(d.sheets[0].future.keep).toBe(true); expect(d.sheets[0].cells[1].formatting.runs[0].bold).toBe(true); expect(saved.document).toContain('9223372036854775807')
  expect((await (await request(page, `/api/projects/${p.id}/execution`)).json()).runs).toEqual([])
  for (const colorScheme of ['light', 'dark'] as const) for (const width of [1280, 375, 320]) { await page.emulateMedia({ colorScheme }); await page.setViewportSize({ width, height: 900 }); expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true); if (width !== 320) await page.screenshot({ path: `../build/editor-operations-${colorScheme}-${width}.png`, fullPage: true }) }
})

test('module rename and binary resource move commit atomically and reject path/case collisions', async ({ page }) => {
  await login(page); const p = await book(page)
  await addModule(page); await page.getByLabel('Module helpers', { exact: true }).fill('package helpers\nexport answer\ndef answer(): 42\n'); await page.getByLabel('Auto-import into sheets').check(); await save(page)
  await page.getByRole('button', { name: 'Rename or move…', exact: true }).click()
  let dialog = page.getByRole('dialog', { name: 'Rename or move module', exact: true })
  await dialog.getByLabel('New module name').fill('renamed-helper module')
  await expect(dialog).toContainText('modules/renamed_helper_module.s')
  await dialog.getByLabel('Destination path').fill('lib/helpers.s')
  await expect(dialog).toContainText('lib/renamed_helper_module.s')
  await page.screenshot({ path: '../build/move-module-light-1280.png', fullPage: true })
  await dialog.getByRole('button', { name: 'Update notebook draft', exact: true }).click()
  await expect(page.getByLabel('Module renamed_helper_module', { exact: true })).toHaveValue('package renamed_helper_module\nexport answer\ndef answer(): 42\n')
  await save(page)
  let current = await stored(page, p.id)
  expect(JSON.parse(current.document).modules).toEqual([{ id: 'renamed_helper_module', path: 'lib/renamed_helper_module.s' }])
  expect(JSON.parse(current.document).auto_imports).toEqual(['renamed_helper_module'])
  await page.getByRole('button', { name: 'Add resource…', exact: true }).click(); await page.getByLabel('Resource file', { exact: true }).setInputFiles({ name: 'data.bin', mimeType: 'application/octet-stream', buffer: Buffer.from([0, 255, 128, 42]) }); await page.getByRole('button', { name: 'Add to draft', exact: true }).click(); await save(page)
  await page.getByRole('button', { name: 'Rename or move…', exact: true }).click(); dialog = page.getByRole('dialog', { name: 'Rename or move file', exact: true }); await dialog.getByLabel('Destination path').fill('../escape'); await dialog.getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await expect(dialog.getByRole('alert')).toContainText('relative'); await dialog.getByLabel('Destination path').fill('LIB/RENAMED_HELPER_MODULE.s'); await dialog.getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await expect(dialog.getByRole('alert')).toContainText('conflicts'); await dialog.getByLabel('Destination path').fill('.hidden/moved.bin'); await dialog.getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await save(page)
  current = await stored(page, p.id); const index = (await (await request(page, `${endpoint(p.id)}/files?revision=${current.revision}`)).json()).entries; expect(index.map((item: any) => item.path)).toEqual(['.hidden/moved.bin', 'lib/renamed_helper_module.s']); expect(await (await request(page, `${endpoint(p.id)}/download?revision=${current.revision}&path=.hidden%2Fmoved.bin`)).body()).toEqual(Buffer.from([0, 255, 128, 42])); expect(current.document).toContain('9223372036854775807')
})

test('independent concurrent edits combine explicitly and a second server race still uses CAS', async ({ page, context }) => {
  await login(page); const p = await book(page), other = await context.newPage(); await other.goto(`/projects/${p.id}`); await expect(other.getByLabel('Code cell 1', { exact: true })).toBeVisible()
  await other.getByLabel('Sheet title', { exact: true }).fill('Remote title'); await save(other)
  await page.getByLabel('Code cell 1', { exact: true }).fill('"Local source"'); await page.getByRole('button', { name: 'Save notebook', exact: true }).click(); await page.getByRole('button', { name: 'Review saved changes…', exact: true }).click()
  const dialog = page.getByRole('dialog', { name: 'Review saved changes', exact: true }); await expect(dialog).toContainText('No overlapping changes'); await dialog.getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await expect(page.getByLabel('Sheet title', { exact: true })).toHaveValue('Remote title'); await expect(page.getByLabel('Code cell 1', { exact: true })).toHaveValue('"Local source"'); expect(JSON.parse((await stored(page, p.id)).document).sheets[0].cells[0].source).toBe('')
  await other.getByLabel('Sheet title', { exact: true }).fill('Raced again'); await save(other)
  await page.getByRole('button', { name: 'Save notebook', exact: true }).click(); await page.getByRole('button', { name: 'Review saved changes…', exact: true }).click(); await expect(dialog).toContainText('No overlapping changes'); await dialog.getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await save(page)
  const saved = await stored(page, p.id); expect(JSON.parse(saved.document).sheets[0].title).toBe('Raced again'); expect(JSON.parse(saved.document).sheets[0].cells[0].source).toBe('"Local source"'); expect(saved.document).toContain('9223372036854775807'); await other.close()
})

test('source and file conflicts require choices, cancel keeps the draft and review fits mobile', async ({ page, context }) => {
  await login(page); const p = await book(page, {}, { 'resources/note.txt': { encoding: 'utf8', data: 'original' } }); const other = await context.newPage(); await other.goto(`/projects/${p.id}`)
  await files(page).getByRole('button', { name: /resources\/note.txt/ }).click(); await page.getByLabel('File resources/note.txt', { exact: true }).fill('local file'); await sheetNav(page).getByRole('button', { name: /^Main/ }).click(); await page.getByLabel('Code cell 1', { exact: true }).fill('"Local conflict"')
  await files(other).getByRole('button', { name: /resources\/note.txt/ }).click(); await other.getByLabel('File resources/note.txt', { exact: true }).fill('remote file'); await sheetNav(other).getByRole('button', { name: /^Main/ }).click(); await other.getByLabel('Code cell 1', { exact: true }).fill('"Remote conflict"'); await save(other)
  await page.getByRole('button', { name: 'Save notebook', exact: true }).click(); await page.getByRole('button', { name: 'Review saved changes…', exact: true }).click(); const dialog = page.getByRole('dialog', { name: 'Review saved changes', exact: true }); await expect(dialog.locator('fieldset')).toHaveCount(2); await expect(dialog.getByRole('button', { name: 'Update notebook draft', exact: true })).toBeDisabled()
  await dialog.getByRole('button', { name: 'Cancel', exact: true }).click(); await expect(page.getByLabel('Code cell 1', { exact: true })).toHaveValue('"Local conflict"'); await page.getByRole('button', { name: 'Review saved changes…', exact: true }).click()
  const localDownload = page.waitForEvent('download'); await dialog.getByRole('button', { name: 'Download your file', exact: true }).click(); expect(await readFile((await (await localDownload).path())!, 'utf8')).toBe('local file'); const savedDownload = page.waitForEvent('download'); await dialog.getByRole('button', { name: 'Download saved file', exact: true }).click(); expect(await readFile((await (await savedDownload).path())!, 'utf8')).toBe('remote file');
  for (const colorScheme of ['light', 'dark'] as const) for (const width of [1280, 375, 320]) { await page.emulateMedia({ colorScheme }); await page.setViewportSize({ width, height: 900 }); expect(await dialog.evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true); if (width !== 320) await page.screenshot({ path: `../build/save-conflict-${colorScheme}-${width}.png`, fullPage: true }) }
  await dialog.locator('fieldset').filter({ hasText: 'Local conflict' }).getByRole('radio', { name: 'Your draft', exact: true }).check(); await dialog.locator('fieldset').filter({ hasText: 'local file' }).getByRole('radio', { name: 'Saved version', exact: true }).check(); await dialog.getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await save(page)
  const saved = await stored(page, p.id); expect(JSON.parse(saved.document).sheets[0].cells[0].source).toBe('"Local conflict"'); expect(await (await request(page, `${endpoint(p.id)}/download?revision=${saved.revision}&path=resources%2Fnote.txt`)).text()).toBe('remote file'); await other.close()
})

test('local recovery restores full source and binary drafts after reload and resolves a changed base explicitly', async ({ page }) => {
  await login(page); const p = await book(page); const original = await stored(page, p.id)
  await page.getByLabel('Code cell 1', { exact: true }).fill('"Recover 😀"'); await page.getByRole('button', { name: 'Add resource…', exact: true }).click(); await page.getByLabel('Resource file', { exact: true }).setInputFiles({ name: 'draft.bin', mimeType: 'application/octet-stream', buffer: Buffer.from([0, 255, 1]) }); await page.getByRole('button', { name: 'Add to draft', exact: true }).click(); await localReady(page)
  const remote = JSON.parse(original.document); remote.sheets[0].title = 'New base'; const updated = await request(page, endpoint(p.id), 'PUT', { command_id: crypto.randomUUID(), base_revision: original.revision, document: JSON.stringify(remote) }); expect(updated.status()).toBe(200)
  await reloadDraft(page); await expect(page.getByTestId('project-file-editor')).toContainText('Binary file · 3 bytes'); await expect(page.getByRole('button', { name: 'Save notebook', exact: true })).toBeDisabled(); await page.getByRole('button', { name: 'Review saved changes…', exact: true }).click(); const dialog = page.getByRole('dialog', { name: 'Review saved changes', exact: true }); await dialog.getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await expect(page.getByLabel('Code cell 1', { exact: true })).toHaveValue('"Recover 😀"'); await expect(page.getByLabel('Sheet title', { exact: true })).toHaveValue('New base'); await save(page)
  const current = await stored(page, p.id); expect(await (await request(page, `${endpoint(p.id)}/download?revision=${current.revision}&path=resources%2Fdraft.bin`)).body()).toEqual(Buffer.from([0, 255, 1])); await page.reload(); await expect(page.getByTestId('draft-recovery')).toHaveCount(0)
})

test('uncertain save survives reload with the original command, preserves newer edits and adds no duplicate revision', async ({ page }) => {
  await login(page); const p = await book(page); const bodies: any[] = []
  await page.route(`**${endpoint(p.id)}`, async route => { if (route.request().method() !== 'PUT') return route.continue(); bodies.push(route.request().postDataJSON()); if (bodies.length === 1) { expect((await route.fetch()).status()).toBe(200); await route.abort('failed') } else await route.continue() })
  await page.getByLabel('Code cell 1', { exact: true }).fill('"Committed once"'); await page.getByRole('button', { name: 'Save notebook', exact: true }).click(); await expect(page.getByTestId('pending-save')).toBeVisible(); await page.getByLabel('Code cell 1', { exact: true }).fill('"Newer local edit"'); await localReady(page); await reloadDraft(page); await expect(page.getByLabel('Code cell 1', { exact: true })).toHaveValue('"Newer local edit"')
  await page.getByRole('button', { name: 'Retry original save', exact: true }).click(); await expect(page.getByTestId('pending-save')).toHaveCount(0); expect(bodies).toHaveLength(2); expect(bodies[1]).toEqual(bodies[0]); await expect(page.getByTestId('notebook-save-status')).toHaveText('Unsaved changes'); expect(JSON.parse((await stored(page, p.id)).document).sheets[0].cells[0].source).toBe('"Committed once"'); await save(page); expect(JSON.parse((await stored(page, p.id)).document).sheets[0].cells[0].source).toBe('"Newer local edit"'); expect((await (await request(page, `${endpoint(p.id)}/revisions`)).json()).revisions).toHaveLength(4)
})

test('separate tabs keep independent journals and other projects cannot see their recovery copies', async ({ page, context }) => {
  await login(page); const p = await book(page), other = await context.newPage(); await other.goto(`/projects/${p.id}`); await expect(other.getByLabel('Code cell 1', { exact: true })).toBeVisible()
  await page.getByLabel('Code cell 1', { exact: true }).fill('"First tab"'); await localReady(page); await other.getByLabel('Code cell 1', { exact: true }).fill('"Second tab"'); await localReady(other); page.once('dialog', dialog => dialog.accept()); await page.reload(); const recovery = page.getByTestId('draft-recovery'); await expect(recovery).toContainText('2 local recovery copies'); await recovery.locator('summary').click(); await expect(recovery.getByRole('button', { name: 'Restore local draft', exact: true })).toHaveCount(2)
  const another = await context.newPage(); await another.goto('/'); const q = await book(another); expect(q.id).not.toBe(p.id); await expect(another.getByTestId('draft-recovery')).toHaveCount(0); await another.close(); await other.close()
})

test('recovery respects account/ACL and unavailable local storage does not block explicit Save', async ({ page, browser, baseURL }) => {
  await login(page); const p = await book(page); await page.getByLabel('Code cell 1', { exact: true }).fill('"private recovery"'); await localReady(page)
  const ownerContext = await browser.newContext({ baseURL }), owner = await ownerContext.newPage(); await login(owner)
  page.once('dialog', dialog => dialog.accept()); await page.getByRole('button', { name: 'Sign out', exact: true }).click(); await expect(page.getByRole('button', { name: 'Continue with GitHub' })).toBeVisible(); await login(page, 'Bob'); const bob = (await (await request(page, '/api/session')).json()).account.id
  await request(owner, `/api/projects/${p.id}/memberships`, 'POST', { account_id: bob, role: 'viewer' }); await page.goto(`/projects/${p.id}`); await expect(page.getByLabel('Code cell 1', { exact: true })).toHaveAttribute('readonly'); await expect(page.getByTestId('draft-recovery')).toHaveCount(0); await expect(page.getByRole('button', { name: 'Duplicate sheet', exact: true })).toHaveCount(0)
  await request(owner, `/api/projects/${p.id}/memberships/${bob}`, 'DELETE'); await page.reload(); await expect(page.getByTestId('draft-recovery')).toHaveCount(0); expect((await request(page, endpoint(p.id))).status()).toBe(404)
  await owner.addInitScript(() => { Object.defineProperty(window, 'indexedDB', { get() { throw new Error('Storage disabled') } }) }); await owner.goto(`/projects/${p.id}`); await owner.getByLabel('Code cell 1', { exact: true }).fill('"Saved without browser storage"'); await expect(owner.getByRole('status').filter({ hasText: /local recovery|Storage disabled/i }).first()).toBeVisible(); await save(owner); expect(JSON.parse((await stored(owner, p.id)).document).sheets[0].cells[0].source).toBe('"Saved without browser storage"'); await ownerContext.close()
})


test('restoring checks current edit access after a role downgrade and keeps the recovery copy', async ({ page, browser, baseURL }) => {
  await login(page); const p = await book(page)
  const bobContext = await browser.newContext({ baseURL }), bob = await bobContext.newPage(); await login(bob, 'Bob'); const account = (await (await request(bob, '/api/session')).json()).account.id
  await request(page, `/api/projects/${p.id}/memberships`, 'POST', { account_id: account, role: 'editor' }); await bob.goto(`/projects/${p.id}`); await bob.getByLabel('Code cell 1', { exact: true }).fill('"Editor recovery"'); await localReady(bob); bob.once('dialog', dialog => dialog.accept()); await bob.reload(); await bob.getByTestId('draft-recovery').locator('summary').click()
  const switcher = await bobContext.newPage(); await switcher.goto('/'); await switcher.getByRole('button', { name: 'Sign out', exact: true }).click(); await expect(switcher.getByRole('button', { name: 'Continue with GitHub' })).toBeVisible(); await login(switcher)
  await bob.getByRole('button', { name: 'Restore local draft', exact: true }).click(); await expect(bob.getByRole('status').filter({ hasText: 'Sign in with the same account' })).toBeVisible(); await expect(bob.getByLabel('Code cell 1', { exact: true })).toHaveValue('')
  await switcher.getByRole('button', { name: 'Sign out', exact: true }).click(); await expect(switcher.getByRole('button', { name: 'Continue with GitHub' })).toBeVisible(); await login(switcher, 'Bob')
  await request(page, `/api/projects/${p.id}/memberships`, 'POST', { account_id: account, role: 'viewer' }); await bob.getByRole('button', { name: 'Restore local draft', exact: true }).click(); await expect(bob.getByRole('status').filter({ hasText: 'Editing access is required' })).toBeVisible(); await expect(bob.getByLabel('Code cell 1', { exact: true })).toHaveValue(''); await expect(bob.getByRole('button', { name: 'Restore local draft', exact: true })).toBeVisible()
  await request(page, `/api/projects/${p.id}/memberships`, 'POST', { account_id: account, role: 'editor' }); await bob.getByRole('button', { name: 'Restore local draft', exact: true }).click(); await expect(bob.getByLabel('Code cell 1', { exact: true })).toHaveValue('"Editor recovery"'); await localReady(bob); await bobContext.close()
})
