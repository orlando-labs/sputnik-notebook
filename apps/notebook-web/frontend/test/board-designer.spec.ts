import { expect, test, type Page } from '@playwright/test'
async function login(page: Page, user = 'Alice') { await page.goto('/'); await page.getByRole('button', { name: 'Continue with GitHub' }).click(); await page.getByRole('button', { name: `Sign in as ${user}` }).click(); await expect(page.getByTestId('account-name')).toHaveText(user) }
async function request(page: Page, path: string, method = 'GET', data?: unknown) {
  const token = (await page.context().cookies()).find(cookie => cookie.name === 'orbit-csrf')?.value
  return page.request.fetch(path, { method, data, headers: { Accept: 'application/json', Origin: new URL(page.url()).origin, ...(token ? { 'X-CSRF-Token': decodeURIComponent(token) } : {}) } })
}
const stored = async (page: Page, id: string) => (await (await request(page, `/api/projects/${id}/notebook`)).json()).notebook
const registry = async (page: Page, id: string) => (await (await request(page, `/api/projects/${id}/execution`)).json())
const dialog = (page: Page) => page.getByRole('dialog', { name: 'Board Designer', exact: true })
const canvas = (page: Page) => page.getByTestId('board-designer-canvas')
const select = (page: Page, title: string) => canvas(page).getByRole('button', { name: `Select ${title}`, exact: true }).click()
async function open(page: Page, title: string) { await page.getByRole('navigation', { name: 'Boards', exact: true }).getByRole('button', { name: title, exact: true }).click() }
async function design(page: Page, title: string) { await open(page, title); await page.getByRole('button', { name: `Design board ${title}`, exact: true }).click(); await expect(dialog(page)).toBeVisible() }
async function tool(page: Page, title: string, category = 'Display') { await dialog(page).getByRole('tab', { name: category, exact: true }).click(); await dialog(page).getByRole('button', { name: `Add ${title}`, exact: true }).click() }
async function save(page: Page) { await page.getByRole('button', { name: 'Save notebook', exact: true }).click(); await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved') }
async function book(page: Page, boards: any[] = [], input = true) {
  const created = await request(page, '/api/projects', 'POST', { title: `Designer ${crypto.randomUUID()}` }); const project = (await created.json()).project
  await request(page, `/api/projects/${project.id}/notebook`, 'POST', {})
  const initial = await stored(page, project.id), document = JSON.parse(initial.document)
  Object.assign(document, { version: 4, inputs: input ? [{ id: 'gain', title: 'Gain', type: 'integer', default: 2 }] : [], boards, dependencies: [], sheets: [{ id: 'main', title: 'Main', cells: [{ id: '1', kind: 'code', mode: 'watch', source: input ? 'score = notebook.input("gain") * 2\nscore\n' : 'score = 42\nscore\n' }] }, { id: 'other', title: 'Other', cells: [{ id: '2', kind: 'code', mode: 'manual', source: '99\n' }] }], active_sheet: 'main' })
  const text = JSON.stringify(document).replaceAll('"__exact__"', '9223372036854775807')
  const response = await request(page, `/api/projects/${project.id}/notebook`, 'PUT', { command_id: crypto.randomUUID(), base_revision: initial.revision, document: text })
  expect(response.status(), await response.text()).toBe(200)
  return { project, notebook: (await response.json()).notebook }
}
const basic = () => ({ id: 'dashboard', title: 'Dashboard', sheet: 'main', columns: 2, rows: [{ id: 'r' }], components: [{ id: 'm', kind: 'metric', title: 'Value', row: 'r', span: 6, cell: '1', binding: 'score', future: { exact: '__exact__' } }], future_board: ['kept'] })
async function release(page: Page, id: string) {
  const state = await registry(page, id)
  for (const run of state.runs.filter((run: any) => !['succeeded', 'failed', 'cancelled', 'force-stopped', 'interrupted'].includes(run.state))) {
    await request(page, `/api/projects/${id}/execution/runs/${run.id}/stop`, 'POST', { command_id: crypto.randomUUID(), runtime_epoch: run.runtime_epoch, force: true })
    await expect.poll(async () => (await registry(page, id)).runs.find((item: any) => item.id === run.id)?.state).toMatch(/^(succeeded|failed|cancelled|force-stopped|interrupted)$/)
  }
  for (const runtime of state.runtimes.filter((runtime: any) => !state.reset_epochs.includes(runtime.runtime_epoch))) await request(page, `/api/projects/${id}/execution/restart`, 'POST', { command_id: crypto.randomUUID(), sheet_id: runtime.sheet_id, runtime_epoch: runtime.runtime_epoch })
}

test('create a board with inert palette/inspector/preview drafts, explicit save and runnable bindings', async ({ page }) => {
  await login(page); const { project, notebook } = await book(page)
  try {
    await page.goto(`/projects/${project.id}`)
    const writes: string[] = []; page.on('request', value => { if (['POST', 'PUT', 'DELETE'].includes(value.method())) writes.push(value.url()) })
    await page.getByRole('button', { name: 'New board', exact: true }).click()
    await dialog(page).getByLabel('Board title', { exact: true }).fill('Control panel')
    await tool(page, 'Metric'); await dialog(page).getByLabel('Component title', { exact: true }).fill('Score'); await dialog(page).getByLabel('Published variable', { exact: true }).fill('score')
    await tool(page, 'Table')
    await dialog(page).getByRole('button', { name: 'Add row', exact: true }).click()
    await dialog(page).getByLabel('Row height', { exact: true }).fill('240')
    await tool(page, 'Tabs', 'Layout'); await dialog(page).getByRole('button', { name: 'Edit panel 1', exact: true }).click()
    await tool(page, 'Text'); await dialog(page).getByLabel('Component title', { exact: true }).fill('Note'); await dialog(page).getByLabel('Board text source', { exact: true }).fill('Hello <Sputnik>')
    await dialog(page).getByRole('navigation', { name: 'Designer panels', exact: true }).getByRole('button', { name: 'Control panel', exact: true }).click()
    expect(await page.evaluate(() => { const event = new Event('beforeunload', { cancelable: true }); window.dispatchEvent(event); return event.defaultPrevented })).toBe(true)
    await dialog(page).getByRole('button', { name: 'Preview layout', exact: true }).click()
    await expect(dialog(page).getByText('Hello <Sputnik>', { exact: true })).toBeVisible()
    await expect(dialog(page).getByRole('button', { name: 'Open Sheet', exact: true })).toBeDisabled()
    await dialog(page).getByRole('button', { name: 'Edit layout', exact: true }).click()
    for (const colorScheme of ['light', 'dark'] as const) {
      await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' })
      for (const width of [1280, 375, 320]) {
        await page.setViewportSize({ width, height: 900 }); expect(await dialog(page).evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true)
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
        if (width === 1280) { expect((await dialog(page).boundingBox())!.width).toBeGreaterThan(1000); expect(await canvas(page).evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true) }
        else { const layout = (await canvas(page).boundingBox())!, inspector = (await dialog(page).getByRole('complementary', { name: 'Object Inspector', exact: true }).boundingBox())!; expect(inspector.y).toBeGreaterThanOrEqual(layout.y + layout.height - 1) }
        if (width !== 320) await dialog(page).screenshot({ path: `../build/board-designer-${colorScheme}-${width}.png` })
      }
    }
    await dialog(page).getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await expect(dialog(page)).not.toBeVisible()
    await expect(page.getByTestId('notebook-save-status')).toHaveText('Unsaved changes')
    expect(await stored(page, project.id)).toEqual(notebook); expect((await registry(page, project.id)).runs).toEqual([]); expect(writes).toEqual([])
    await save(page)
    const document = JSON.parse((await stored(page, project.id)).document), board = document.boards[0]
    expect(board.title).toBe('Control panel'); expect(board.rows).toHaveLength(2); expect(board.rows[1].height).toBe(240)
    expect(board.components.map((item: any) => item.kind)).toEqual(['metric', 'table', 'tabs'])
    expect(board.components[2].panels[0].components[0].text_content.source).toBe('Hello <Sputnik>')
    expect((await registry(page, project.id)).runs).toEqual([])
    await page.getByRole('button', { name: 'Run Sheet', exact: true }).click(); await expect(page.getByLabel('Score value', { exact: true })).toHaveText('4')
    await page.reload(); await open(page, 'Control panel'); await expect(page.getByLabel('Score value', { exact: true })).toHaveText('4')
  } finally { await release(page, project.id) }
})

test('legacy editing preserves opaque settings and exact metadata through drag, duplication and undo/redo', async ({ page }) => {
  await login(page)
  const legacy = { id: 'legacy', title: 'Legacy', sheet: 'main', columns: 2, future: '__exact__', components: [{ id: 'm', kind: 'metric', title: 'Original metric', cell: '1', binding: 'score', p1: { future: ['kept'], target: '__exact__' } }, { id: 'group', kind: 'group', title: 'Container', panels: [{ id: 'panel', title: 'Contents', future_panel: { kept: true }, rows: [{ id: 'nested', future_row: 123 }], components: [{ id: 'child', kind: 'metric', title: 'Child', row: 'nested', span: 6, cell: '1', p1: { target_component: 'child', future: true } }] }] }, { id: 'opaque', kind: 'audio', title: 'Saved audio', cell: '1', audio_id: 'track', future: { retained: true } }] }
  const { project, notebook } = await book(page, [legacy])
  try {
    await page.goto(`/projects/${project.id}`); await design(page, 'Legacy'); await dialog(page).getByRole('button', { name: 'Cancel', exact: true }).click()
    expect(await stored(page, project.id)).toEqual(notebook); await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved')
    await design(page, 'Legacy')
    await dialog(page).getByRole('button', { name: 'Select row 1', exact: true }).click(); await dialog(page).getByLabel('Row height', { exact: true }).fill('0')
    await dialog(page).getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await expect(dialog(page).getByRole('alert')).toContainText(/height|numeric/)
    await dialog(page).getByRole('button', { name: 'Undo', exact: true }).click(); await expect(dialog(page).getByLabel('Row height', { exact: true })).toHaveValue('')
    const firstRow = await canvas(page).locator('[data-designer-row]').first().getAttribute('data-designer-row')
    await dialog(page).getByRole('button', { name: 'Add row', exact: true }).click()
    const target = canvas(page).locator('[data-designer-row]').last(), targetID = await target.getAttribute('data-designer-row')
    const source = canvas(page).locator('[data-designer-component="m"]')
    await source.scrollIntoViewIfNeeded(); const box = (await source.boundingBox())!
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2); await page.mouse.down(); await page.mouse.move(box.x + box.width / 2 + 10, box.y + box.height / 2 + 10, { steps: 3 }); await target.hover(); await target.hover(); await page.mouse.up()
    await expect(dialog(page).getByLabel('Component row', { exact: true })).toHaveValue(targetID!)
    await dialog(page).getByRole('button', { name: 'Duplicate component', exact: true }).click()
    await dialog(page).getByRole('button', { name: 'Undo', exact: true }).click(); await expect(canvas(page).getByRole('button', { name: 'Select Original metric copy', exact: true })).toHaveCount(0)
    await dialog(page).getByRole('button', { name: 'Redo', exact: true }).click(); await expect(canvas(page).getByRole('button', { name: 'Select Original metric copy', exact: true })).toHaveCount(1)
    await select(page, 'Container'); await dialog(page).getByRole('button', { name: 'Duplicate component', exact: true }).click()
    await expect(canvas(page).getByRole('button', { name: 'Select Container copy', exact: true })).toBeVisible()
    await dialog(page).getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await save(page)
    const saved = await stored(page, project.id), board = JSON.parse(saved.document).boards[0]
    expect(saved.document).toContain('"future":9223372036854775807'); expect(saved.document).toContain('"target":9223372036854775807')
    expect(board.components.find((item: any) => item.id === 'm').row).toBe(targetID)
    expect(board.rows[0].id).toBe(firstRow)
    expect(board.components.find((item: any) => item.id === 'opaque')).toMatchObject({ audio_id: 'track', future: { retained: true } })
    const copy = board.components.find((item: any) => item.title === 'Container copy')
    expect(copy.panels[0].future_panel).toEqual({ kept: true }); expect(copy.panels[0].rows[0].future_row).toBe(123)
    expect(copy.panels[0].components[0].id).not.toBe('child'); expect(copy.panels[0].components[0].p1.target_component).toBe(copy.panels[0].components[0].id)
    expect((await registry(page, project.id)).runs).toEqual([])
  } finally { await release(page, project.id) }
})

test('nested panels can be authored, reordered, removed and restored with stable bindings', async ({ page }) => {
  await login(page); const { project } = await book(page)
  try {
    await page.goto(`/projects/${project.id}`); await page.getByRole('button', { name: 'New board', exact: true }).click()
    await dialog(page).getByLabel('Board title', { exact: true }).fill('Nested')
    await tool(page, 'Tabs', 'Layout'); await dialog(page).getByRole('button', { name: 'Add panel', exact: true }).click()
    await dialog(page).getByLabel('Panel 3 title', { exact: true }).fill('Third'); await dialog(page).getByRole('button', { name: 'Move panel 3 left', exact: true }).click()
    await expect(dialog(page).getByLabel('Panel 2 title', { exact: true })).toHaveValue('Third')
    await dialog(page).getByRole('button', { name: 'Edit panel 2', exact: true }).click()
    await tool(page, 'Input', 'Controls'); await expect(dialog(page).getByLabel('Project parameter', { exact: true })).toHaveValue('gain')
    await dialog(page).getByRole('navigation', { name: 'Designer panels', exact: true }).getByRole('button', { name: 'Nested', exact: true }).click(); await select(page, 'Tabs')
    page.once('dialog', value => value.accept()); await dialog(page).getByRole('button', { name: 'Delete panel 2', exact: true }).click()
    await expect(dialog(page).getByLabel('Panel 3 title', { exact: true })).toHaveCount(0)
    await dialog(page).getByRole('button', { name: 'Undo', exact: true }).click(); await expect(dialog(page).getByLabel('Panel 2 title', { exact: true })).toHaveValue('Third')
    await tool(page, 'Split View', 'Layout'); await dialog(page).getByLabel('Split direction', { exact: true }).selectOption('vertical'); await dialog(page).getByLabel('Minimum panel size', { exact: true }).fill('160')
    await dialog(page).getByRole('button', { name: 'Edit panel 1', exact: true }).click(); await tool(page, 'Metric'); await dialog(page).getByLabel('Published variable', { exact: true }).fill('score')
    await dialog(page).getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await save(page)
    const board = JSON.parse((await stored(page, project.id)).document).boards[0]
    expect(board.components[0].panels.map((item: any) => item.title)).toEqual(['First', 'Third', 'Second'])
    expect(board.components[0].panels[1].components[0].input).toBe('gain')
    expect(board.components[1].split_axis).toBe('vertical'); expect(board.components[1].split_min).toBe(160)
    expect(board.components[1].panels[0].components[0].binding).toBe('score')
    expect((await registry(page, project.id)).runs).toEqual([])
  } finally { await release(page, project.id) }
})

test('designer enforces viewer/revocation and preserves its committed draft across revision conflicts', async ({ page, browser, baseURL }) => {
  await login(page); const { project } = await book(page, [basic()])
  const context = await browser.newContext({ baseURL })
  try {
    const bob = await context.newPage(); await login(bob, 'Bob'); const bobID = (await (await request(bob, '/api/session')).json()).account.id
    await request(page, `/api/projects/${project.id}/memberships`, 'POST', { account_id: bobID, role: 'viewer' })
    await bob.goto(`/projects/${project.id}`); await open(bob, 'Dashboard')
    await expect(bob.getByRole('button', { name: 'New board', exact: true })).toHaveCount(0); await expect(bob.getByRole('button', { name: 'Design board Dashboard', exact: true })).toHaveCount(0)
    await request(page, `/api/projects/${project.id}/memberships`, 'POST', { account_id: bobID, role: 'editor' })
    await bob.reload(); await design(bob, 'Dashboard'); await dialog(bob).getByLabel('Board title', { exact: true }).fill('Uncommitted')
    await request(page, `/api/projects/${project.id}/memberships/${bobID}`, 'DELETE')
    await expect(dialog(bob).getByRole('button', { name: 'Update notebook draft', exact: true })).toBeDisabled(); await expect(dialog(bob).getByLabel('Board title', { exact: true })).toHaveValue('Uncommitted')
    await dialog(bob).getByRole('button', { name: 'Cancel', exact: true }).click()
    await request(page, `/api/projects/${project.id}/memberships`, 'POST', { account_id: bobID, role: 'editor' })
    await bob.reload(); await design(bob, 'Dashboard'); await dialog(bob).getByLabel('Board title', { exact: true }).fill('Local title'); await dialog(bob).getByRole('button', { name: 'Update notebook draft', exact: true }).click()
    const current = await stored(page, project.id), document = current.document.replace('\"title\":' + JSON.stringify(JSON.parse(current.document).title), '\"title\":\"Concurrent source edit\"')
    expect((await request(page, `/api/projects/${project.id}/notebook`, 'PUT', { command_id: crypto.randomUUID(), base_revision: current.revision, document })).status()).toBe(200)
    await bob.getByRole('button', { name: 'Save notebook', exact: true }).click(); await expect(bob.getByRole('alert')).toContainText(/changed|conflict|revision|newer/i)
    await expect(bob.getByTestId('notebook-save-status')).toHaveText('Unsaved changes'); await expect(bob.getByTestId('notebook-board')).toContainText('Local title')
    expect(JSON.parse((await stored(page, project.id)).document).boards[0].title).toBe('Dashboard')
    expect((await registry(page, project.id)).runs).toEqual([])
  } finally { await context.close(); await release(page, project.id) }
})

test('designer shortcut, lost Save receipt and board duplicate/delete keep explicit lifecycle semantics', async ({ page }) => {
  await login(page); const { project, notebook } = await book(page, [], false)
  try {
    await page.goto(`/projects/${project.id}`); await page.getByRole('button', { name: 'New board', exact: true }).click(); await dialog(page).getByLabel('Board title', { exact: true }).fill('Lifecycle')
    await tool(page, 'Metric'); await dialog(page).getByLabel('Published variable', { exact: true }).fill('score')
    await dialog(page).getByLabel('Published variable', { exact: true }).press(process.platform === 'darwin' ? 'Meta+s' : 'Control+s')
    await expect(dialog(page)).not.toBeVisible(); expect(await stored(page, project.id)).toEqual(notebook)
    const commands: any[] = []
    await page.route(`**/api/projects/${project.id}/notebook`, async route => {
      if (route.request().method() !== 'PUT') return route.continue()
      commands.push(route.request().postDataJSON())
      if (commands.length === 1) { await route.fetch(); await route.abort('failed') } else await route.continue()
    })
    await page.getByRole('button', { name: 'Save notebook', exact: true }).click(); await expect(page.getByRole('button', { name: 'Retry save', exact: true })).toBeVisible()
    await page.getByRole('button', { name: 'Retry save', exact: true }).click(); await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved')
    expect(commands).toHaveLength(2); expect(commands[1]).toEqual(commands[0]); expect((await registry(page, project.id)).runs).toEqual([])
    await page.unroute(`**/api/projects/${project.id}/notebook`)
    await page.getByLabel('Board actions', { exact: true }).click(); await page.getByRole('button', { name: 'Duplicate board…', exact: true }).click()
    await expect(dialog(page).getByLabel('Board title', { exact: true })).toHaveValue('Lifecycle copy'); await dialog(page).getByRole('button', { name: 'Cancel', exact: true }).click()
    await page.getByLabel('Board actions', { exact: true }).click(); await page.getByRole('button', { name: 'Duplicate board…', exact: true }).click(); await dialog(page).getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await save(page)
    expect(JSON.parse((await stored(page, project.id)).document).boards).toHaveLength(2)
    await page.getByLabel('Board actions', { exact: true }).click(); page.once('dialog', value => value.accept()); await page.getByRole('button', { name: 'Delete board…', exact: true }).click()
    expect(JSON.parse((await stored(page, project.id)).document).boards).toHaveLength(2); await save(page)
    const boards = JSON.parse((await stored(page, project.id)).document).boards
    expect(boards).toHaveLength(1); expect(boards[0].title).toBe('Lifecycle')
    await open(page, 'Lifecycle'); await page.getByRole('button', { name: 'Run Sheet', exact: true }).click(); await expect(page.getByLabel('Metric value', { exact: true })).toHaveText('42')
  } finally { await release(page, project.id) }
})
