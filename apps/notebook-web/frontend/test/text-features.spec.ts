import { expect, test, type Page } from '@playwright/test'
const createdBooks = new WeakMap<Page, string[]>()

async function login(page: Page, user = 'Alice') { await page.goto('/'); await page.getByRole('button', { name: 'Continue with GitHub' }).click(); await page.getByRole('button', { name: `Sign in as ${user}` }).click(); await expect(page.getByTestId('account-name')).toHaveText(user) }
async function request(page: Page, path: string, method = 'GET', data?: unknown) {
  const token = (await page.context().cookies()).find(cookie => cookie.name === 'orbit-csrf')?.value
  return page.request.fetch(path, { method, data, headers: { Accept: 'application/json', Origin: new URL(page.url()).origin, ...(token ? { 'X-CSRF-Token': decodeURIComponent(token) } : {}) } })
}
const code = (id: string, source: string) => ({ id, source, kind: 'code', mode: 'manual' })
const text = (id: string, source: string, formatting?: unknown) => ({ id, source, kind: 'text', ...(formatting ? { formatting } : {}) })
async function book(page: Page, cells: unknown[], components: any[] = []) {
  const created = await request(page, '/api/projects', 'POST', { title: 'Text features ' + crypto.randomUUID() }); expect(created.status()).toBe(201); const project = (await created.json()).project
  const owned = createdBooks.get(page) || []; owned.push(project.id); createdBooks.set(page, owned)
  const endpoint = `/api/projects/${project.id}/notebook`, initial = (await (await request(page, endpoint, 'POST', {})).json()).notebook
  const document = JSON.parse(initial.document); document.sheets[0].cells = cells; document.future = { exact: '__exact__' }
  if (components.length) { document.version = 4; document.inputs = []; document.dependencies = []; document.boards = [{ id: 'report', title: 'Report', sheet: 'main', columns: 2, rows: components.map((_, index) => ({ id: `row${index}` })), components: components.map((component, index) => ({ ...component, row: `row${index}`, span: 12 })) }] }
  const response = await request(page, endpoint, 'PUT', { command_id: crypto.randomUUID(), base_revision: initial.revision, document: JSON.stringify(document).replace('"__exact__"', '9223372036854775807') }); expect(response.status(), await response.text()).toBe(200)
  return { project, notebook: (await response.json()).notebook }
}
async function stored(page: Page, id: string) { return (await (await request(page, `/api/projects/${id}/notebook`)).json()).notebook }
async function registry(page: Page, id: string) { const response = await request(page, `/api/projects/${id}/execution`); expect(response.status(), await response.text()).toBe(200); return response.json() }
async function runResult(page: Page, id: string) { const state = await registry(page, id), run = state.runs.at(-1); expect(run).toBeTruthy(); return (await (await request(page, `/api/projects/${id}/execution/runs/${run.id}`)).json()).run }
async function runAll(page: Page, id: string, name = 'Run All') {
  const previous = (await registry(page, id)).runs.at(-1)?.id
  await page.getByRole('button', { name, exact: true }).click()
  await expect.poll(async () => { const run = (await registry(page, id)).runs.at(-1); return run?.id !== previous ? run?.state : '' }, { timeout: 15000 }).toMatch(/^(succeeded|failed)$/)
}
async function save(page: Page) { await page.getByRole('button', { name: 'Save notebook', exact: true }).click(); await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved') }
const cell = (page: Page, index: number) => page.getByTestId('notebook-cell').nth(index)
const card = (page: Page, id: string) => page.locator(`[data-board-component="${id}"]`).first()

// Core deliberately retains idle heaps and permits eight live workers. Release
// each scenario's own worlds so the complete suite tests lifecycle, not leakage
// from these independent fixtures. Authored documents and results are retained.
test.afterEach(async ({ page }) => {
  for (const id of createdBooks.get(page) || []) {
    const endpoint = `/api/projects/${id}/execution`, response = await request(page, endpoint)
    if (response.status() !== 200) continue
    const current = await response.json()
    for (const run of current.runs.filter((run: any) => !['succeeded', 'failed', 'cancelled', 'force-stopped', 'interrupted'].includes(run.state))) {
      expect((await request(page, `${endpoint}/runs/${run.id}/stop`, 'POST', { command_id: crypto.randomUUID(), runtime_epoch: run.runtime_epoch, force: true })).status()).toBe(200)
      await expect.poll(async () => (await (await request(page, `${endpoint}/runs/${run.id}`)).json()).run.state).toMatch(/^(succeeded|failed|cancelled|force-stopped|interrupted)$/)
    }
    const latest = new Map<string, any>()
    for (const runtime of current.runtimes) if (!current.reset_epochs.includes(runtime.runtime_epoch)) latest.set(runtime.sheet_id, runtime)
    for (const runtime of latest.values()) expect((await request(page, endpoint + '/restart', 'POST', { command_id: crypto.randomUUID(), sheet_id: runtime.sheet_id, runtime_epoch: runtime.runtime_epoch })).status()).toBe(200)
  }
})

test('text uses declared preceding module values, exact integers, literal strings and explicit stale states', async ({ page }) => {
  await login(page)
  const cells = [text('1', 'Before {{greeting}}'), code('2', 'greeting = "**Hello** <script>literal</script>"\nscore = 9223372036854775807\nempty = ""\nprivate_value = "never publish me"\nscore\n'), text('3', 'Value {{greeting}} · {{score}} · [{{empty}}] · {{score + 1}}', { version: 1, runs: [{ start: 6, length: 5, bold: true }] })]
  const { project, notebook } = await book(page, cells); await page.goto(`/projects/${project.id}`)
  await cell(page, 0).getByRole('button', { name: 'Preview text', exact: true }).click(); await cell(page, 2).getByRole('button', { name: 'Preview text', exact: true }).click()
  await expect(cell(page, 0)).toContainText('[greeting: unavailable]'); await expect(cell(page, 2)).toContainText('[score: unavailable]'); expect((await registry(page, project.id)).runs).toEqual([])
  await runAll(page, project.id); await expect(cell(page, 2)).toContainText('**Hello** <script>literal</script> · 9223372036854775807 · []'); await expect(cell(page, 2)).toContainText('[score + 1: unavailable]'); await expect(cell(page, 0)).toContainText('[greeting: unavailable]')
  expect(await cell(page, 2).locator('script').count()).toBe(0); await expect(cell(page, 2).locator('.text-bold')).toContainText('**Hello**')
  const result = await runResult(page, project.id); expect(result.rich_error).toBe(''); expect(result.cells.find((value: any) => value.id === '2').text_values.map((value: any) => value.name).sort()).toEqual(['empty', 'greeting', 'score']); expect(JSON.stringify(result.cells.map((value: any) => value.text_values))).not.toContain('never publish me')
  expect(await stored(page, project.id)).toEqual(notebook)
  await page.getByLabel('Code cell 2', { exact: true }).fill(cells[1]!.source + '\n# changed\n'); await expect(cell(page, 2).locator('.text-variable-stale').first()).toBeVisible(); await expect(cell(page, 2)).toContainText('stale —')
  await save(page); expect((await registry(page, project.id)).runs).toHaveLength(1); const old = await runResult(page, project.id); expect(old.cells.find((value: any) => value.id === '2').text_values).toEqual(result.cells.find((value: any) => value.id === '2').text_values)
  await page.reload(); await cell(page, 2).getByRole('button', { name: 'Preview text', exact: true }).click(); await expect(cell(page, 2)).toContainText('stale —')
})

test('later uninitialized providers shadow earlier values and failures stale preceding text values', async ({ page }) => {
  await login(page)
  const { project } = await book(page, [code('1', 'answer = 1\n'), text('2', '{{answer}}'), code('3', 'answer = 2\n'), text('4', '{{answer}}')])
  await page.goto(`/projects/${project.id}`); await cell(page, 1).getByRole('button', { name: 'Preview text', exact: true }).click(); await cell(page, 3).getByRole('button', { name: 'Preview text', exact: true }).click()
  await runAll(page, project.id); await expect(cell(page, 1).getByTestId('text-preview')).toHaveText('1'); await expect(cell(page, 3).getByTestId('text-preview')).toHaveText('2')
  await page.getByLabel('Code cell 3', { exact: true }).fill('if false:\n  answer = 3\n1 / 0\n'); await save(page); await runAll(page, project.id)
  await expect(cell(page, 3).getByTestId('text-preview')).toContainText(/answer: (?:stale|unavailable)/)
  const result = await runResult(page, project.id); expect(result.rich_error).toBe(''); expect(result.state).toBe('failed')
})

test('Markdown board renders structure before literal values and never fetches authored media or HTML', async ({ page }) => {
  await login(page)
  const source = '# Analysis\n\n**Strong** and *emphasis* with {{message}}.\n\n| Name | Score |\n| --- | ---: |\n| Model | {{score}} |\n\n```sputnik\nπ = 42 # note\n{{score}}\n```\n\n[Docs](https://example.com/docs)\n\n![private image](https://example.invalid/private.png)\n\n<script>window.injected = true</script>\n\n[unsafe](javascript:alert(1))'
  const { project, notebook } = await book(page, [code('1', 'message = "**literal** <img src=x>"\nscore = 42\n')], [{ id: 'markdown', kind: 'rich_text', title: 'Markdown report', text_mode: 'markdown', text_content: { source } }, { id: 'bound', kind: 'text', title: 'Published text', cell: '1', binding: 'message' }])
  const media: string[] = []; page.on('request', request => { if (/example\.invalid|\/private\.png|\/x$/.test(request.url())) media.push(request.url()) })
  await page.goto(`/projects/${project.id}`); await page.getByRole('navigation', { name: 'Boards', exact: true }).getByRole('button', { name: 'Report' }).click(); await expect(card(page, 'markdown').getByRole('heading', { name: 'Analysis', exact: true })).toBeVisible(); expect((await registry(page, project.id)).runs).toEqual([])
  await runAll(page, project.id, 'Run Sheet'); await expect(card(page, 'markdown')).toContainText('**literal** <img src=x>'); await expect(card(page, 'markdown').locator('table')).toContainText('42'); await expect(card(page, 'markdown').locator('pre')).toContainText('42'); await expect(card(page, 'bound')).toContainText('**literal** <img src=x>')
  expect(await card(page, 'markdown').locator('script,img,iframe,style').count()).toBe(0); expect(media).toEqual([]); expect(await page.evaluate(() => (window as any).injected)).toBeUndefined(); expect(await card(page, 'markdown').locator('a[href^="javascript:"]').count()).toBe(0)
  await expect(card(page, 'markdown').getByRole('link', { name: 'Docs', exact: true })).toHaveAttribute('rel', 'noopener noreferrer'); await expect(card(page, 'markdown').locator('.syntax-number').first()).toHaveText('42')
  expect(await stored(page, project.id)).toEqual(notebook)
  for (const colorScheme of ['light', 'dark'] as const) { await page.emulateMedia({ colorScheme }); for (const width of [1280, 375, 320]) { await page.setViewportSize({ width, height: 900 }); expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true); if (width !== 320) await page.screenshot({ path: `../build/markdown-${colorScheme}-${width}.png`, fullPage: true }) } }
})

test('Markdown authoring and the variable picker stage normal drafts and preserve formatting/metadata', async ({ page }) => {
  await login(page)
  const { project, notebook } = await book(page, [code('1', 'answer = 42\n'), text('2', 'Report: ')], [{ id: 'note', kind: 'rich_text', title: 'Authored note', future: { retain: true }, text_content: { source: 'Plain text', formatting: { version: 1, runs: [{ start: 0, length: 5, bold: true }] } } }])
  await page.goto(`/projects/${project.id}`); const editor = cell(page, 1).getByTestId('text-editor'), input = editor.getByLabel('Text cell 2', { exact: true }); await input.focus(); await input.evaluate((element: HTMLTextAreaElement) => { element.setSelectionRange(8, 8); element.dispatchEvent(new Event('select', { bubbles: true })) }); await page.setViewportSize({ width: 375, height: 900 }); await editor.getByLabel('Insert notebook variable').click(); expect(await editor.locator('.text-variable-picker > div').evaluate(element => { const bounds = element.getBoundingClientRect(); return bounds.left >= 0 && bounds.right <= innerWidth })).toBe(true); await page.screenshot({ path: '../build/text-variable-picker-mobile.png', fullPage: true }); await page.setViewportSize({ width: 1280, height: 900 }); await editor.getByLabel('Variable name', { exact: true }).fill('answer'); await editor.getByRole('button', { name: 'Insert variable', exact: true }).click(); await expect(input).toHaveValue('Report: {{answer}}'); expect((await registry(page, project.id)).runs).toEqual([]); expect(await stored(page, project.id)).toEqual(notebook)
  await save(page); await page.getByRole('navigation', { name: 'Boards', exact: true }).getByRole('button', { name: 'Report' }).click(); await page.getByRole('button', { name: 'Design board Report', exact: true }).click()
  const designer = page.getByRole('dialog', { name: 'Board Designer', exact: true }); await designer.getByRole('button', { name: 'Select Authored note', exact: true }).click(); await designer.getByLabel('Board text format', { exact: true }).selectOption('markdown'); await designer.getByLabel('Board text source', { exact: true }).fill('# Saved Markdown\n{{answer}}'); await expect(designer.getByLabel('Board Markdown preview')).toContainText('[answer: unavailable]'); await designer.getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await save(page)
  const document = JSON.parse((await stored(page, project.id)).document), note = document.boards[0].components[0]; expect(note.text_mode).toBe('markdown'); expect(note.text_content.formatting.runs[0].bold).toBe(true); expect(note.future.retain).toBe(true); expect((await stored(page, project.id)).document).toContain('9223372036854775807'); expect((await registry(page, project.id)).runs).toEqual([])
  await runAll(page, project.id, 'Run Sheet'); await expect(card(page, 'note')).toContainText('42')
})

test('Sputnik source keeps lexical colors, selection, Unicode diagnostics and stale-range protection', async ({ page }) => {
  await login(page); const { project } = await book(page, [code('1', 'π = "😀"\nπ + missing_name\n')]); await page.goto(`/projects/${project.id}`)
  const source = page.getByLabel('Code cell 1', { exact: true }), editor = cell(page, 0).getByTestId('sputnik-editor')
  await expect(editor.locator('.syntax-string')).toHaveText('"😀"'); await runAll(page, project.id)
  const result = await runResult(page, project.id); expect(result.rich_error).toBe(''); const diagnostics = result.cells[0].diagnostics; expect(diagnostics.length).toBeGreaterThan(0); expect(diagnostics.some((item: any) => item.range !== null)).toBe(true)
  const list = cell(page, 0).getByTestId('code-diagnostics'); await expect(list).toBeVisible(); await expect(editor.locator('.code-error-range').first()).toBeVisible(); await list.getByRole('button').filter({ hasText: 'Line ' }).first().click(); await expect(source).toBeFocused(); const selected = await source.evaluate((element: HTMLTextAreaElement) => element.value.slice(element.selectionStart, element.selectionEnd)); expect(selected.length).toBeGreaterThan(0)
  for (const colorScheme of ['light', 'dark'] as const) { await page.emulateMedia({ colorScheme }); await page.screenshot({ path: `../build/sputnik-diagnostics-${colorScheme}.png`, fullPage: true }) }
  await source.fill('π = 21\nπ * 2\n'); await expect(list).toContainText('Previous diagnostics'); expect(await editor.locator('.code-error-range').count()).toBe(0); await expect(list.getByRole('button').first()).toBeDisabled(); await save(page); await runAll(page, project.id); await expect(cell(page, 0).getByLabel('Cell result', { exact: true })).toHaveText('42'); await expect(list).toHaveCount(0)
})

test('code editor composition, tab, Undo, scroll and module styling preserve explicit save semantics', async ({ page }) => {
  await login(page); const { project } = await book(page, [code('1', 'answer = 1\nanswer\n')]); await page.goto(`/projects/${project.id}`)
  const source = page.getByLabel('Code cell 1', { exact: true }); await source.fill('answer = 12\nanswer\n'); await source.focus(); await source.press('End'); await source.pressSequentially(' + 3'); const beforeUndo = await source.inputValue(); await source.press(process.platform === 'darwin' ? 'Meta+z' : 'Control+z'); expect(await source.inputValue()).not.toBe(beforeUndo)
  await source.fill(''); await source.evaluate((element: HTMLTextAreaElement) => { element.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true })); element.value = 'число = 42\nчисло\n'; element.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertCompositionText', data: 'число', isComposing: true })) }); await expect(page.getByTestId('notebook-save-status')).toHaveText('Unsaved changes'); await source.evaluate(element => element.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: 'число' }))); await save(page); expect(JSON.parse((await stored(page, project.id)).document).sheets[0].cells[0].source).toBe('число = 42\nчисло\n')
  await source.focus(); await source.evaluate((element: HTMLTextAreaElement) => element.setSelectionRange(0, 0)); await source.press('Tab'); await expect(source).toHaveValue('  число = 42\nчисло\n'); await source.fill('x = 1\n'.repeat(80)); await source.evaluate((element: HTMLTextAreaElement) => { element.scrollTop = 300; element.dispatchEvent(new Event('scroll', { bubbles: true })) }); expect(await cell(page, 0).locator('.code-highlight').evaluate(element => element.scrollTop)).toBe(300)
  await source.fill('42\n'); await save(page); expect((await registry(page, project.id)).runs).toEqual([])
  await page.getByRole('button', { name: 'New module', exact: true }).click(); const module = page.getByRole('dialog', { name: 'New module', exact: true }); await module.getByLabel('Module name').fill('helpers'); await module.getByRole('button', { name: 'Add to draft', exact: true }).click(); const file = page.getByLabel('Module helpers', { exact: true }); await file.fill('package helpers\nexport answer\ndef answer(): 42\n'); await expect(page.getByTestId('project-file-editor').locator('.syntax-keyword').first()).toHaveText('package'); await save(page); await page.reload(); await page.getByRole('navigation', { name: 'Project files' }).getByRole('button', { name: 'helpers' }).click(); await expect(page.getByLabel('Module helpers', { exact: true })).toHaveValue('package helpers\nexport answer\ndef answer(): 42\n')
})

test('reader text/Markdown access follows ACL and new authored names cannot read old run locals', async ({ page, browser, baseURL }) => {
  await login(page); const { project } = await book(page, [code('1', 'public_value = "visible"\nprivate_value = "hidden"\n'), text('2', '{{public_value}}')]); await page.goto(`/projects/${project.id}`); await runAll(page, project.id); const initial = await runResult(page, project.id)
  await cell(page, 1).getByLabel('Text cell 2', { exact: true }).fill('{{public_value}} {{private_value}}'); await save(page); await cell(page, 1).getByRole('button', { name: 'Preview text', exact: true }).click(); await expect(cell(page, 1)).toContainText('[private_value: unavailable]'); const old = (await (await request(page, `/api/projects/${project.id}/execution/runs/${initial.id}?binding=private_value`)).json()).run; expect(old.cells[0].text_values.map((value: any) => value.name)).toEqual(['public_value'])
  const context = await browser.newContext({ baseURL }); try { const bob = await context.newPage(); await login(bob, 'Bob'); const bobId = (await (await request(bob, '/api/session')).json()).account.id; expect((await request(bob, `/api/projects/${project.id}/execution/runs/${initial.id}`)).status()).toBe(404); await request(page, `/api/projects/${project.id}/memberships`, 'POST', { account_id: bobId, role: 'viewer' }); await bob.goto(`/projects/${project.id}`); await expect(cell(bob, 1).getByTestId('text-preview')).toContainText('visible'); await expect(bob.getByLabel('Code cell 1', { exact: true })).toHaveAttribute('readonly', ''); await request(page, `/api/projects/${project.id}/memberships/${bobId}`, 'DELETE'); await expect(cell(bob, 1).getByTestId('text-preview')).toContainText('[public_value: unavailable]', { timeout: 10000 }) } finally { await context.close() }
})

test('variable and syntax work limits stay visible while complete authored source survives Save', async ({ page }) => {
  await login(page)
  const placeholders = Array.from({ length: 257 }, (_, i) => `{{name_${i}}}`).join(' ')
  const { project } = await book(page, [code('1', 'имя = "Мир"\nname_0 = "visible only within a complete projection"\n'), text('2', '{{\u00a0имя\u00a0}}')])
  await page.goto(`/projects/${project.id}`); await runAll(page, project.id); await cell(page, 1).getByRole('button', { name: 'Preview text', exact: true }).click(); await expect(cell(page, 1).getByTestId('text-preview')).toHaveText('Мир')
  await cell(page, 1).getByRole('button', { name: 'Edit text', exact: true }).click(); await cell(page, 1).getByLabel('Text cell 2', { exact: true }).fill(placeholders); await save(page); await runAll(page, project.id)
  await expect(page.getByText('Published text exceeds the preview limits.', { exact: false })).toBeVisible(); const result = await runResult(page, project.id); expect(result.text_limited).toBe(true); expect(result.cells[0].text_values).toEqual([])
  const large = '# ' + 'x'.repeat(262145); await page.getByLabel('Code cell 1', { exact: true }).fill(large); await expect(cell(page, 0)).toContainText('Syntax preview is limited'); expect(await cell(page, 0).locator('.code-highlight').count()).toBe(0); await save(page); expect(JSON.parse((await stored(page, project.id)).document).sheets[0].cells[0].source).toBe(large)
})

test('temporary preview shares code styling and literal text bindings without changing its template', async ({ page }) => {
  await login(page); const { project, notebook } = await book(page, [code('1', 'answer = 42\n'), text('2', 'Preview {{answer}}')]); await page.goto(`/projects/${project.id}`)
  await page.getByRole('button', { name: 'Temporary preview…', exact: true }).click(); const dialog = page.getByRole('dialog', { name: 'Temporary preview', exact: true }); await expect(dialog.getByLabel('Preview code cell 1', { exact: true })).toHaveValue('answer = 42\n'); await expect(dialog.locator('.syntax-number')).toHaveText('42'); await dialog.getByRole('button', { name: 'Preview text', exact: true }).click(); await dialog.getByRole('button', { name: 'Run preview sheet', exact: true }).click(); await expect(dialog.getByTestId('text-preview')).toHaveText('Preview 42', { timeout: 15000 }); await expect(dialog.getByTestId('preview-budget')).toContainText('One run: 60 s'); expect(await stored(page, project.id)).toEqual(notebook); expect((await registry(page, project.id)).runs).toEqual([]); await dialog.getByRole('button', { name: 'Close preview', exact: true }).click()
})
