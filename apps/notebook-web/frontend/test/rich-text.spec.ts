import { expect, test, type Page, type Locator } from '@playwright/test'
import { readFileSync } from 'node:fs'
const native = JSON.parse(readFileSync(new URL('../../../../tools/notebook-macos/Samples/Rich Text.sputnikbook/project.json', import.meta.url), 'utf8')).sheets[0].cells[1]
async function login(page: Page, user = 'Alice') { await page.goto('/'); await page.getByRole('button', { name: 'Continue with GitHub' }).click(); await page.getByRole('button', { name: `Sign in as ${user}` }).click(); await expect(page.getByTestId('account-name')).toHaveText(user) }
async function request(page: Page, path: string, method = 'GET', data?: unknown) { const token = (await page.context().cookies()).find(cookie => cookie.name === 'orbit-csrf')?.value; return page.request.fetch(path, { method, data, headers: { Accept: 'application/json', Origin: new URL(page.url()).origin, ...(token ? { 'X-CSRF-Token': decodeURIComponent(token) } : {}) } }) }
const stored = async (page: Page, id: string) => (await (await request(page, `/api/projects/${id}/notebook`)).json()).notebook
async function book(page: Page, text: any = native) {
  const project = (await (await request(page, '/api/projects', 'POST', { title: `Rich text ${crypto.randomUUID()}` })).json()).project
  const initial = (await (await request(page, `/api/projects/${project.id}/notebook`, 'POST', {})).json()).notebook, document = JSON.parse(initial.document)
  Object.assign(document, { version: 4, inputs: [], dependencies: [], sheets: [{ id: 'main', title: 'Main', cells: [{ id: '1', kind: 'code', source: '42\n', mode: 'manual' }, { ...text, id: '2', kind: 'text', future: { exact: '__exact__' } }] }], boards: [{ id: 'dash', title: 'Text board', sheet: 'main', columns: 2, rows: [{ id: 'row' }], components: [{ id: 'note', kind: 'rich_text', title: 'Rich note', row: 'row', span: 12, text_content: { source: text.source, ...(text.formatting ? { formatting: text.formatting } : {}) }, future: { retained: true } }] }] })
  const response = await request(page, `/api/projects/${project.id}/notebook`, 'PUT', { command_id: crypto.randomUUID(), base_revision: initial.revision, document: JSON.stringify(document).replaceAll('"__exact__"', '9223372036854775807') }); expect(response.status(), await response.text()).toBe(200)
  return { project, notebook: (await response.json()).notebook }
}
const editor = (page: Page) => page.getByTestId('notebook-cell').nth(1).getByTestId('text-editor')
async function select(input: Locator, start: number, length: number) { await input.focus(); await input.evaluate((element: HTMLTextAreaElement, range) => { element.setSelectionRange(range.start, range.start + range.length); element.dispatchEvent(new Event('select', { bubbles: true })) }, { start, length }) }
async function save(page: Page) { await page.getByRole('button', { name: 'Save notebook', exact: true }).click(); await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved') }
async function inert(page: Page, id: string) { expect((await (await request(page, `/api/projects/${id}/execution`)).json()).runs).toEqual([]) }

test('Swift v2 text renders headings/lists/tables safely and edits portable spans with explicit save and reload', async ({ page }) => {
  await login(page); const { project, notebook } = await book(page); await page.goto(`/projects/${project.id}`)
  const scope = editor(page), source = scope.getByRole('textbox', { name: 'Text cell 2', exact: true })
  await expect(source).toBeEditable(); await scope.getByRole('button', { name: 'Preview text', exact: true }).click()
  await expect(scope.getByRole('heading', { name: 'Rich text, live code', exact: true })).toBeVisible(); await expect(scope.locator('table td')).toHaveCount(4); await expect(scope.locator('table')).toContainText('Native tables')
  await expect(scope).toContainText('[message: unavailable]'); expect(await stored(page, project.id)).toEqual(notebook)
  await scope.getByRole('button', { name: 'Edit text', exact: true }).click(); await select(source, 0, 9); await scope.getByRole('button', { name: 'Bold', exact: true }).click()
  await scope.getByRole('button', { name: 'Preview text', exact: true }).click(); await expect(scope.locator('.text-bold').filter({ hasText: 'Rich text' })).toBeVisible()
  await scope.getByRole('button', { name: 'Edit text', exact: true }).click(); await select(source, native.source.indexOf('Native tables'), 6); await source.press(process.platform === 'darwin' ? 'Meta+i' : 'Control+i')
  await save(page); const saved = await stored(page, project.id); expect(saved.document).toContain('9223372036854775807'); const text = JSON.parse(saved.document).sheets[0].cells[1]; expect(text.formatting.version).toBe(2); expect(text.formatting.tables).toEqual(native.formatting.tables); expect(text.formatting.runs.some((run: any) => run.italic)).toBe(true)
  await page.reload(); await editor(page).getByRole('button', { name: 'Preview text', exact: true }).click(); await expect(editor(page).locator('.text-italic')).toHaveText('Native'); await inert(page, project.id)
  for (const colorScheme of ['light', 'dark'] as const) { await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' }); for (const width of [1280, 375, 320]) { await page.setViewportSize({ width, height: 900 }); expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true); if (width !== 320) await page.screenshot({ path: `../build/rich-text-${colorScheme}-${width}.png`, fullPage: true }) } }
})

test('Unicode source edits remap spans, preserve literal content and undo/redo through save', async ({ page }) => {
  await login(page); const { project } = await book(page, { source: 'A 💫 title\n<script>literal</script>\n', formatting: { version: 1, runs: [{ start: 2, length: 2, bold: true }] } }); await page.goto(`/projects/${project.id}`)
  const scope = editor(page), source = scope.getByRole('textbox', { name: 'Text cell 2', exact: true })
  await select(source, 0, 0); await source.press('Home'); await source.pressSequentially('New ')
  await scope.getByRole('button', { name: 'Preview text', exact: true }).click(); await expect(scope.locator('.text-bold')).toHaveText('💫'); await expect(scope).toContainText('<script>literal</script>'); expect(await scope.locator('script')).toHaveCount(0)
  await scope.getByRole('button', { name: 'Edit text', exact: true }).click(); await scope.getByRole('button', { name: 'Undo text edit', exact: true }).click(); await expect(source).toHaveValue('A 💫 title\n<script>literal</script>\n')
  await scope.getByRole('button', { name: 'Redo text edit', exact: true }).click(); await expect(source).toHaveValue('New A 💫 title\n<script>literal</script>\n')
  await save(page); expect(JSON.parse((await stored(page, project.id)).document).sheets[0].cells[1].formatting.runs[0]).toMatchObject({ start: 6, length: 2, bold: true }); await inert(page, project.id)
})

test('paragraph/list tools and protected tables author native structure with Undo and structural cell editing', async ({ page }) => {
  await login(page); const { project } = await book(page, { source: 'Title\nFirst\nSecond\n' }); await page.goto(`/projects/${project.id}`)
  const scope = editor(page), source = scope.getByRole('textbox', { name: 'Text cell 2', exact: true })
  await select(source, 0, 0); await scope.getByLabel('Paragraph style', { exact: true }).selectOption('heading2')
  await select(source, 6, 13); await scope.getByRole('button', { name: 'Numbered list', exact: true }).click(); await expect(source).toHaveValue('Title\n1.\tFirst\n2.\tSecond\n')
  await select(source, 6, 0); await scope.getByRole('button', { name: 'Numbered list', exact: true }).click(); await expect(source).toHaveValue('Title\nFirst\n1.\tSecond\n')
  await select(source, 0, 0); await scope.getByLabel('Text table actions', { exact: true }).click(); await scope.getByRole('button', { name: 'Insert 2 × 2 table', exact: true }).click()
  await source.pressSequentially('Cell 💫'); await source.press('Tab'); await source.pressSequentially('Next')
  await source.press('Backspace')
  // Cell terminator deletion is rejected atomically, with a visible reason.
  const value = await source.inputValue(), firstTerminator = value.indexOf('\n', 6)
  await select(source, firstTerminator, 1); await source.press('Backspace'); await expect(scope.getByRole('alert')).toContainText('boundaries'); await expect(source).toHaveValue(value)
  await select(source, 6, 0); await scope.getByRole('button', { name: 'Add table row', exact: true }).click(); await scope.getByRole('button', { name: 'Add table column', exact: true }).click()
  await scope.getByRole('button', { name: 'Preview text', exact: true }).click(); await expect(scope.locator('table tr')).toHaveCount(3); await expect(scope.locator('table td')).toHaveCount(9)
  await scope.getByRole('button', { name: 'Edit text', exact: true }).click(); await select(source, 0, 0); await scope.getByRole('button', { name: 'Insert 2 × 2 table', exact: true }).click()
  await scope.getByRole('button', { name: 'Preview text', exact: true }).click(); await expect(scope.locator('table')).toHaveCount(2); await expect(scope.locator('table td')).toHaveCount(13)
  await save(page); const saved = JSON.parse((await stored(page, project.id)).document).sheets[0].cells[1]; expect(saved.formatting.tables[1].columns).toBe(3); expect(saved.formatting.tables[1].cells).toHaveLength(9); await inert(page, project.id)
})

test('board rich text shares the editor/preview and cancelling keeps exact original formatting', async ({ page }) => {
  await login(page); const { project, notebook } = await book(page); await page.goto(`/projects/${project.id}`); await page.getByRole('navigation', { name: 'Boards', exact: true }).getByRole('button', { name: 'Text board', exact: true }).click()
  await expect(page.getByTestId('notebook-board').locator('table td')).toHaveCount(4)
  await page.getByRole('button', { name: 'Design board Text board', exact: true }).click(); const dialog = page.getByRole('dialog', { name: 'Board Designer', exact: true }); await dialog.getByRole('button', { name: 'Select Rich note', exact: true }).click()
  const source = dialog.getByRole('textbox', { name: 'Board text source', exact: true }); await select(source, 0, 9); await dialog.getByRole('button', { name: 'Underline', exact: true }).click(); await dialog.getByRole('button', { name: 'Cancel', exact: true }).click(); expect(await stored(page, project.id)).toEqual(notebook)
  await page.getByRole('button', { name: 'Design board Text board', exact: true }).click(); await dialog.getByRole('button', { name: 'Select Rich note', exact: true }).click(); await select(source, 0, 9); await dialog.getByRole('button', { name: 'Underline', exact: true }).click(); await dialog.getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await save(page)
  await expect(page.getByTestId('notebook-board').locator('.text-underline')).toHaveText('Rich text'); const saved = JSON.parse((await stored(page, project.id)).document).boards[0].components[0]; expect(saved.future).toEqual({ retained: true }); expect(saved.text_content.formatting.tables).toEqual(native.formatting.tables); await inert(page, project.id)
})

test('readers get rendered text and revoked editors cannot persist a rich-text draft', async ({ page, browser, baseURL }) => {
  await login(page); const { project } = await book(page); const context = await browser.newContext({ baseURL })
  try {
    const bob = await context.newPage(); await login(bob, 'Bob'); const bobID = (await (await request(bob, '/api/session')).json()).account.id
    await request(page, `/api/projects/${project.id}/memberships`, 'POST', { account_id: bobID, role: 'viewer' }); await bob.goto(`/projects/${project.id}`); await expect(editor(bob).locator('table td')).toHaveCount(4); await expect(editor(bob).getByRole('button', { name: 'Bold', exact: true })).toHaveCount(0)
    await request(page, `/api/projects/${project.id}/memberships`, 'POST', { account_id: bobID, role: 'editor' }); await bob.reload(); const source = editor(bob).getByRole('textbox', { name: 'Text cell 2', exact: true }); await select(source, 0, 9); await editor(bob).getByRole('button', { name: 'Bold', exact: true }).click()
    await request(page, `/api/projects/${project.id}/memberships/${bobID}`, 'DELETE'); await bob.getByRole('button', { name: 'Save notebook', exact: true }).click(); await expect(bob.getByRole('alert').first()).toContainText(/found|access|permission|forbidden/i); expect(JSON.parse((await stored(page, project.id)).document).sheets[0].cells[1].formatting.runs).toEqual([])
    await inert(page, project.id)
  } finally { await context.close() }
})

test('lost Save response retries identical rich-text commands and CAS conflicts retain formatted draft', async ({ page }) => {
  await login(page); const { project } = await book(page, { source: 'Source\n' }); await page.goto(`/projects/${project.id}`)
  const source = editor(page).getByRole('textbox', { name: 'Text cell 2', exact: true }); await select(source, 0, 6); await editor(page).getByRole('button', { name: 'Bold', exact: true }).click(); const commands: any[] = []
  await page.route(`**/api/projects/${project.id}/notebook`, async route => { if (route.request().method() !== 'PUT') return route.continue(); commands.push(route.request().postDataJSON()); if (commands.length === 1) { await route.fetch(); await route.abort('failed') } else await route.continue() })
  await page.getByRole('button', { name: 'Save notebook', exact: true }).click(); await expect(page.getByRole('button', { name: 'Retry save', exact: true })).toBeVisible(); await page.getByRole('button', { name: 'Retry save', exact: true }).click(); await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved'); expect(commands[1]).toEqual(commands[0]); await page.unrouteAll({ behavior: 'wait' })
  await select(source, 0, 6); await editor(page).getByRole('button', { name: 'Italic', exact: true }).click(); const current = await stored(page, project.id), document = current.document.replace('"title":"Main"', '"title":"Concurrent sheet"'); expect((await request(page, `/api/projects/${project.id}/notebook`, 'PUT', { command_id: crypto.randomUUID(), base_revision: current.revision, document })).status()).toBe(200)
  await page.getByRole('button', { name: 'Save notebook', exact: true }).click(); await expect(page.getByRole('alert').first()).toContainText(/changed|newer|conflict/i); await expect(page.getByTestId('notebook-save-status')).toHaveText('Unsaved changes'); expect(JSON.parse((await stored(page, project.id)).document).sheets[0].cells[1].formatting.runs[0].italic).toBe(false); await inert(page, project.id)
})

test('numbered lists continue, composed input commits once and oversized previews remain bounded', async ({ page }) => {
  await login(page); const { project } = await book(page, { source: 'First\nSecond\n' }); await page.goto(`/projects/${project.id}`)
  const scope = editor(page), source = scope.getByRole('textbox', { name: 'Text cell 2', exact: true })
  await select(source, 0, 13); await scope.getByRole('button', { name: 'Numbered list', exact: true }).click(); await select(source, 8, 0); await source.press('Enter'); await expect(source).toHaveValue('1.\tFirst\n2.\t\n3.\tSecond\n')
  await save(page)
  await source.evaluate((element: HTMLTextAreaElement) => { element.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true })); element.value = element.value.replace('First', '漢字'); element.dispatchEvent(new InputEvent('input', { bubbles: true, isComposing: true, inputType: 'insertCompositionText', data: '漢字' })) })
  await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved'); await expect(source).toHaveValue('1.\t漢字\n2.\t\n3.\tSecond\n')
  await source.evaluate((element: HTMLTextAreaElement) => element.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '漢字' })))
  await expect(page.getByTestId('notebook-save-status')).toHaveText('Unsaved changes'); await save(page); expect(JSON.parse((await stored(page, project.id)).document).sheets[0].cells[1].source).toContain('漢字'); await inert(page, project.id)
  const large = await book(page, { source: 'Long text\n'.repeat(5000) }); await page.goto(`/projects/${large.project.id}`); await editor(page).getByRole('button', { name: 'Preview text', exact: true }).click(); await expect(editor(page)).toContainText('4000 lines'); await expect(editor(page).locator('.text-paragraph')).toHaveCount(0); await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved'); await inert(page, large.project.id)
})
