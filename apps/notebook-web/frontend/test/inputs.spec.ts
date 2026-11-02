import { expect, test, type Page } from '@playwright/test'
async function login(page: Page, user = 'Alice') { await page.goto('/'); await page.getByRole('button', { name: 'Continue with GitHub' }).click(); await page.getByRole('button', { name: `Sign in as ${user}` }).click(); await expect(page.getByTestId('account-name')).toHaveText(user) }
async function request(page: Page, path: string, method = 'GET', data?: unknown) { const token = (await page.context().cookies()).find(cookie => cookie.name === 'orbit-csrf')?.value; return page.request.fetch(path, { method, data, headers: { Accept: 'application/json', Origin: new URL(page.url()).origin, ...(token ? { 'X-CSRF-Token': decodeURIComponent(token) } : {}) } }) }
const base = (id: string) => `/api/projects/${id}`
async function read(page: Page, path: string) { const response = await request(page, path); expect(response.status()).toBe(200); return response.json() }
async function state(page: Page, id: string, cell?: string) { return read(page, base(id) + '/inputs' + (cell ? `?cell=${cell}` : '')) }
async function registry(page: Page, id: string) { return read(page, base(id) + '/execution') }
async function saved(page: Page, id: string) { return (await read(page, base(id) + '/notebook')).notebook }
async function waitIdle(page: Page, id: string) { await expect.poll(async () => (await registry(page, id)).runs.filter((run: any) => !['succeeded', 'failed', 'cancelled', 'force-stopped', 'interrupted'].includes(run.state)).length).toBe(0) }
async function save(page: Page) { await page.getByRole('button', { name: 'Save notebook', exact: true }).click(); await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved') }
function cell(id: string, mode: string, source: string, value: string, title: string) { return { id, kind: 'code', mode, source, cell_ui: { inputs: [{ id: 'gain', title, type: 'integer', default_json: value, minimum: 0, maximum: 100 }], pre: [{ id: 'form', kind: 'parameter_form', title: `${title} form`, fields: [{ input: 'gain' }] }], post: [] } } }
async function book(page: Page) {
  const created = await request(page, '/api/projects', 'POST', { title: `Parameters ${crypto.randomUUID()}` }); const project = (await created.json()).project
  await request(page, base(project.id) + '/notebook', 'POST', {})
  const first = await saved(page, project.id), document = JSON.parse(first.document)
  document.version = 4; document.boards = []; document.dependencies = []; document.inputs = [{ id: 'gain', title: 'Project gain', type: 'integer', default: 2, minimum: 0, maximum: 100 }, { id: 'exact', title: 'Exact integer', type: 'integer', default: '__exact__' }]
  document.sheets[0].cells = [
    { id: '1', kind: 'code', mode: 'watch', source: 'project_gain = notebook.input("gain")\nproject_gain * 2\n' },
    cell('2', 'watch', 'local_gain = notebook.cell_input("gain")\nlocal_gain * 3\n', '3', 'Local gain'),
    cell('3', 'manual', 'manual_gain = notebook.cell_input("gain")\nnotebook.progress("manual", 1, 1, "Manual progress", true)\nmanual_gain * 4\n', '5', 'Manual gain'),
    { id: '4', kind: 'code', mode: 'watch', source: 'project_gain + local_gain + manual_gain\n' },
  ]
  const source = JSON.stringify(document).replace('"__exact__"', '9223372036854775806')
  const put = await request(page, base(project.id) + '/notebook', 'PUT', { command_id: crypto.randomUUID(), base_revision: first.revision, document: source }); expect(put.status()).toBe(200)
  return { project, document, notebook: (await put.json()).notebook }
}
function form(page: Page, title: string) { return page.getByRole('region', { name: title, exact: true }) }
function result(page: Page, index: number) { return page.getByTestId('notebook-cell').nth(index - 1).getByLabel('Cell result', { exact: true }) }
async function apply(page: Page, title: string, field: string, value: string) { const region = form(page, title); await region.getByLabel(field, { exact: true }).fill(value); await expect(region.getByRole('button', { name: 'Apply', exact: true })).toBeEnabled(); await region.getByRole('button', { name: 'Apply', exact: true }).click(); await expect(region.getByLabel(field, { exact: true })).toBeEnabled(); await expect(region.getByRole('button', { name: 'Apply', exact: true })).toBeDisabled() }

test('project and local Apply are atomic, exact and inert until a world is initialized; Watch and Manual follow core semantics', async ({ page }) => {
  await login(page); const { project, notebook } = await book(page); await page.goto(`/projects/${project.id}`)
  await expect(form(page, 'Project Parameters').getByLabel('Exact integer', { exact: true })).toHaveValue('9223372036854775806')
  await apply(page, 'Project Parameters', 'Project gain', '4')
  expect((await registry(page, project.id)).runs).toEqual([])
  await page.getByRole('button', { name: 'Run All', exact: true }).click(); await expect(result(page, 1)).toHaveText('8'); await expect(result(page, 2)).toHaveText('9'); await expect(result(page, 3)).toHaveText('20'); await waitIdle(page, project.id)
  const firstRun = (await registry(page, project.id)).runs[0]
  await expect(page.getByTestId('notebook-cell').nth(2).getByTestId('runtime-telemetry')).not.toContainText('Previous measurements')
  await apply(page, 'Local gain form', 'Local gain', '7'); await expect(result(page, 2)).toHaveText('21'); await expect(result(page, 4)).toHaveText('16'); await waitIdle(page, project.id)
  await apply(page, 'Manual gain form', 'Manual gain', '9'); await waitIdle(page, project.id)
  await expect(page.getByTestId('notebook-cell').nth(2).getByLabel('Cell error', { exact: true })).toContainText('manual cell is stale'); await expect(page.getByTestId('notebook-cell').nth(2)).toContainText('Previous result')
  await expect(page.getByTestId('notebook-cell').nth(2).getByTestId('runtime-telemetry')).toContainText('Previous measurements')
  await page.locator('.run-history > summary').click(); await expect(page.locator('.run-history')).toContainText('Apply parameters'); await page.locator('.run-history > summary').click()
  await page.getByRole('button', { name: 'Run cell 3', exact: true }).click(); await expect(result(page, 3)).toHaveText('36'); await waitIdle(page, project.id)
  await apply(page, 'Project Parameters', 'Exact integer', '9223372036854775807'); await waitIdle(page, project.id)
  expect((await state(page, project.id)).values.exact).toBe('9223372036854775807')
  expect(await saved(page, project.id)).toEqual(notebook)
  const history = await read(page, base(project.id) + `/execution/runs/${firstRun.id}`); expect(history.run.input_version).toBe(firstRun.input_version); expect(history.run.cells[1].result).toBe('9')
  expect(history.run.input_version).not.toBe((await state(page, project.id)).version)
  await page.reload(); await expect(form(page, 'Project Parameters').getByLabel('Exact integer', { exact: true })).toHaveValue('9223372036854775807'); await expect(form(page, 'Local gain form').getByLabel('Local gain', { exact: true })).toHaveValue('7'); await expect(form(page, 'Manual gain form').getByLabel('Manual gain', { exact: true })).toHaveValue('9')
})

test('parameter conflicts preserve drafts and invalid/busy/revoked requests leave accepted values unchanged', async ({ page, context, browser }) => {
  await login(page); const { project, notebook } = await book(page); await page.goto(`/projects/${project.id}`)
  const before = await state(page, project.id), region = form(page, 'Project Parameters')
  await region.getByLabel('Project gain', { exact: true }).fill('7')
  const other = await context.newPage(); await other.goto(`/projects/${project.id}`); await apply(other, 'Project Parameters', 'Project gain', '8'); await other.close()
  await expect(region).toContainText('Parameters changed on the server'); await expect(region.getByLabel('Project gain', { exact: true })).toHaveValue('7'); await expect(region.getByRole('button', { name: 'Apply', exact: true })).toBeDisabled()
  const command = { command_id: crypto.randomUUID(), revision: notebook.revision, base_version: before.version, values: { gain: '7' } }
  expect((await request(page, base(project.id) + '/inputs', 'PUT', command)).status()).toBe(409)
  await region.getByRole('button', { name: 'Reset to current', exact: true }).click(); await expect(region.getByLabel('Project gain', { exact: true })).toHaveValue('8')
  const current = await state(page, project.id)
  for (const values of [{ gain: '9', exact: '9223372036854775808' }, { gain: '101' }, { gain: '"wrong type"' }, { missing: '2' }]) {
    const rejected = await request(page, base(project.id) + '/inputs', 'PUT', { ...command, command_id: crypto.randomUUID(), base_version: current.version, values }); expect([400, 422]).toContain(rejected.status()); expect(await rejected.text()).not.toMatch(/\/private\/|agent.sock|core_project_id/)
    expect(await state(page, project.id)).toEqual(current)
  }
  const otherContext = await browser.newContext(); const bob = await otherContext.newPage(); await login(bob, 'Bob'); const bobId = await bob.getByTestId('account-id').textContent(); await request(page, base(project.id) + '/memberships', 'POST', { account_id: bobId, role: 'viewer' }); await bob.goto(`/projects/${project.id}`)
  await expect(form(bob, 'Project Parameters').getByLabel('Project gain', { exact: true })).toBeDisabled(); expect((await request(bob, base(project.id) + '/inputs', 'PUT', { ...command, base_version: current.version })).status()).toBe(403)
  await request(page, base(project.id) + '/memberships/' + bobId, 'DELETE'); expect((await request(bob, base(project.id) + '/inputs')).status()).toBe(404); expect((await request(bob, base(project.id) + '/inputs/commands/' + command.command_id)).status()).toBe(404); await otherContext.close()
})

test('input definitions and cell controls are authored as inert drafts and survive save with exact metadata', async ({ page }) => {
  await login(page); const created = await request(page, '/api/projects', 'POST', { title: 'Input designer ' + crypto.randomUUID() }); const project = (await created.json()).project; await request(page, base(project.id) + '/notebook', 'POST', {}); await page.goto(`/projects/${project.id}`)
  await page.getByRole('button', { name: 'Project Inputs…', exact: true }).click(); await page.getByRole('button', { name: 'Add parameter', exact: true }).click(); await page.getByLabel('Parameter name', { exact: true }).fill('limit'); await page.getByLabel('Parameter title', { exact: true }).fill('Exact limit'); await page.getByLabel('Parameter type', { exact: true }).selectOption('integer'); await page.getByLabel('Parameter default', { exact: true }).fill('9223372036854775807'); await page.getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await expect(page.getByTestId('notebook-save-status')).toHaveText('Unsaved changes'); await save(page)
  expect((await saved(page, project.id)).document).toContain('9223372036854775807'); expect((await registry(page, project.id)).runs).toEqual([])
  await page.getByRole('button', { name: 'Components for cell 1', exact: true }).click(); await page.getByRole('button', { name: 'Add parameter', exact: true }).click(); await page.getByLabel('Parameter name', { exact: true }).fill('gain'); await page.getByLabel('Parameter title', { exact: true }).fill('Local gain'); await page.getByLabel('Parameter type', { exact: true }).selectOption('integer'); await page.getByLabel('Parameter default', { exact: true }).fill('2'); await page.getByRole('button', { name: 'Add Parameter Form', exact: true }).click(); await page.getByLabel('Parameter Form field 1 control', { exact: true }).selectOption('stepper'); await page.getByRole('button', { name: 'Update notebook draft', exact: true }).click()
  await page.getByLabel('Execution mode for cell 1', { exact: true }).selectOption('watch'); await page.getByRole('textbox', { name: 'Code cell 1', exact: true }).fill('notebook.cell_input("gain") * 2\n'); await save(page); expect((await registry(page, project.id)).runs).toEqual([])
  await page.reload(); await expect(form(page, 'Parameter Form').getByLabel('Local gain', { exact: true })).toHaveValue('2'); await form(page, 'Parameter Form').getByRole('button', { name: 'Increase Local gain', exact: true }).click(); await form(page, 'Parameter Form').getByRole('button', { name: 'Apply', exact: true }).click(); await expect(form(page, 'Parameter Form').getByLabel('Local gain', { exact: true })).toHaveValue('3'); expect((await registry(page, project.id)).runs).toEqual([])
  await page.getByRole('button', { name: 'Run cell 1', exact: true }).click(); await expect(result(page, 1)).toHaveText('6')
})

test('input commands recover accepted and unaccepted response loss without duplicate runs or automatic replay', async ({ page }) => {
  await login(page); const { project } = await book(page); await page.goto(`/projects/${project.id}`)
  const routePath = `**${base(project.id)}/inputs**`, commands: any[] = []
  let mode = 'accepted', lost = false
  await page.route(routePath, async route => {
    if (route.request().method() !== 'PUT') return route.continue()
    commands.push(route.request().postDataJSON())
    if (!lost) { lost = true; if (mode === 'accepted') await route.fetch(); return route.abort('failed') }
    return route.continue()
  })
  await apply(page, 'Project Parameters', 'Project gain', '6'); expect((await state(page, project.id)).values.gain).toBe('6'); expect((await registry(page, project.id)).runs).toEqual([])
  mode = 'unknown'; lost = false
  const region = form(page, 'Local gain form'); await region.getByLabel('Local gain', { exact: true }).fill('9'); await region.getByRole('button', { name: 'Apply', exact: true }).click(); await expect(page.getByRole('button', { name: 'Retry pending input command', exact: true })).toBeVisible(); expect(commands).toHaveLength(2)
  page.once('dialog', dialog => dialog.accept()); await page.reload(); await expect(page.getByRole('button', { name: 'Retry pending input command', exact: true })).toBeVisible(); expect(commands).toHaveLength(2)
  await page.getByRole('button', { name: 'Retry pending input command', exact: true }).click(); await expect(form(page, 'Local gain form').getByLabel('Local gain', { exact: true })).toHaveValue('9'); await expect(page.getByRole('button', { name: 'Retry pending input command', exact: true })).toHaveCount(0)
  expect(commands).toHaveLength(3); expect(commands[2]).toEqual(commands[1]); expect((await registry(page, project.id)).runs).toEqual([])
})

test('an active run rejects project and local edits and retains its frozen input version', async ({ page }) => {
  await login(page); const { project, notebook, document } = await book(page)
  document.sheets[0].cells = document.sheets[0].cells.slice(0, 2)
  document.sheets[0].cells[0].source = 'import task\nproject_gain = notebook.input("gain")\nprint "waiting"\ntask.sleep(2000)\nproject_gain\n'
  const put = await request(page, base(project.id) + '/notebook', 'PUT', { command_id: crypto.randomUUID(), base_revision: notebook.revision, document: JSON.stringify(document).replace('"__exact__"', '9223372036854775806') }); expect(put.status()).toBe(200)
  const current = (await put.json()).notebook, accepted = await state(page, project.id)
  await page.goto(`/projects/${project.id}`); await page.getByRole('button', { name: 'Run cell 1', exact: true }).click(); await expect(page.getByLabel('Cell output', { exact: true })).toContainText('waiting')
  for (const cell of [null, '2']) { const rejected = await request(page, base(project.id) + '/inputs' + (cell ? '?cell=' + cell : ''), 'PUT', { command_id: crypto.randomUUID(), revision: current.revision, base_version: accepted.version, values: { gain: '8' } }); expect(rejected.status()).toBe(409) }
  expect(await state(page, project.id)).toEqual(accepted); await expect(result(page, 1)).toHaveText('2'); await waitIdle(page, project.id)
  const run = (await registry(page, project.id)).runs[0]; expect(run.input_version).toBe(accepted.version)
})

test('typed controls preserve large integers, ranges and configs; rejected config batches keep every draft and accepted value', async ({ page }) => {
  await login(page); const { project, notebook, document } = await book(page)
  const definitions = [
    { id: 'amount', title: 'Amount', type: 'number', default_json: '1.5', minimum: 0, maximum: 10, future: { retained: true } },
    { id: 'exact', title: 'Local exact', type: 'integer', default_json: '9223372036854775806' },
    { id: 'enabled', title: 'Enabled', type: 'boolean', default_json: 'false' },
    { id: 'choice', title: 'Choice', type: 'string', default_json: '"alpha"' },
    { id: 'range', title: 'Range', type: 'range', default_json: '{"start":0,"finish":10,"inclusive_end":true,"step":2}' },
    { id: 'decimal_range', title: 'Decimal range', type: 'range', default_json: '{"start":0.0,"finish":10.0,"inclusive_end":false,"step":0.5}' },
    { id: 'config', title: 'JSON config', type: 'string', default_json: '"{\\\"epochs\\\":2}"' },
    { id: 'yaml', title: 'YAML config', type: 'string', default_json: JSON.stringify('# defaults\nepochs: 2\n') },
    { id: 'toml', title: 'TOML config', type: 'string', default_json: JSON.stringify('# defaults\nepochs = 2\n') },
  ]
  document.sheets[0].cells = [{ id: '1', kind: 'code', mode: 'watch', source: 'notebook.cell_input("exact")\n', cell_ui: { inputs: definitions, future_ui: { retained: ['future'] }, pre: [{ id: 'form', kind: 'parameter_form', title: 'Typed parameters', future_component: 'keep', fields: [
    { input: 'amount', control: { style: 'slider', minimum: 0, maximum: 10, step: 0.5 } }, { input: 'exact', control: { style: 'stepper', step: 1 } }, { input: 'enabled' }, { input: 'choice', control: { style: 'select', options: [{ label: 'Alpha', value_json: '"alpha"', future_option: true }, { label: 'Beta', value_json: '"beta"' }] } }, { input: 'range', control: { style: 'range_sliders', start_minimum: 0, start_maximum: 10, finish_minimum: 0, finish_maximum: 20, step: 1 } }, { input: 'decimal_range', control: { style: 'slider', minimum: 0, maximum: 10, step: 0.5 } }, { input: 'config', control: { style: 'json', config_format: 'json' } }, { input: 'yaml', control: { style: 'json', config_format: 'yaml' } }, { input: 'toml', control: { style: 'json', config_format: 'toml' } },
  ] }], post: [{ id: 'display', kind: 'metric', title: 'Saved metric', binding: 'score', future_display: { retained: true } }] } }]
  const put = await request(page, base(project.id) + '/notebook', 'PUT', { command_id: crypto.randomUUID(), base_revision: notebook.revision, document: JSON.stringify(document).replace('"__exact__"', '9223372036854775806') }); expect(put.status()).toBe(200)
  const original = (await put.json()).notebook
  await page.goto(`/projects/${project.id}`); const region = form(page, 'Typed parameters'); await expect(region.getByLabel('Local exact', { exact: true })).toBeEnabled()
  const before = await state(page, project.id, '1')
  await region.getByRole('button', { name: 'Increase Local exact', exact: true }).click(); await expect(region.getByLabel('Local exact', { exact: true })).toHaveValue('9223372036854775807')
  await region.getByLabel('Enabled', { exact: true }).check(); await region.getByLabel('Choice', { exact: true }).selectOption('beta'); await region.getByLabel('Range start', { exact: true }).focus(); await page.keyboard.press('ArrowRight'); await expect(region.getByLabel('Range', { exact: true })).toHaveValue('(1..10:2)')
  await region.getByLabel('Decimal range start', { exact: true }).focus(); await page.keyboard.press('ArrowRight'); await expect(region.getByLabel('Decimal range', { exact: true })).toHaveValue('(0.5...10.0:0.5)')
  await region.getByLabel('JSON config', { exact: true }).fill('{"epochs":4,"seed":9223372036854775807}')
  await region.getByLabel('YAML config', { exact: true }).fill('epochs: ['); await region.getByRole('button', { name: 'Apply', exact: true }).click(); await expect(page.getByTestId('input-status')).toContainText('invalid'); expect(await state(page, project.id, '1')).toEqual(before); await expect(region.getByLabel('Local exact', { exact: true })).toHaveValue('9223372036854775807')
  await region.getByLabel('YAML config', { exact: true }).fill('# accepted\nepochs: 4\n'); await region.getByLabel('TOML config', { exact: true }).fill('# accepted\nepochs = 4\n'); await region.getByRole('button', { name: 'Apply', exact: true }).click(); await expect(region.getByRole('button', { name: 'Apply', exact: true })).toBeDisabled(); await expect.poll(async () => (await state(page, project.id, '1')).values.exact).toBe('9223372036854775807')
  expect((await state(page, project.id, '1')).values.decimal_range).toContain('"finish":10.0'); expect(JSON.parse((await state(page, project.id, '1')).values.yaml)).toBe('# accepted\nepochs: 4\n'); expect(JSON.parse((await state(page, project.id, '1')).values.range)).toEqual({ start: 1, finish: 10, inclusive_end: true, step: 2 }); expect((await registry(page, project.id)).runs).toEqual([])
  await page.getByRole('button', { name: 'Components for cell 1', exact: true }).click(); await page.getByLabel('Parameter title', { exact: true }).fill('Amount updated'); await page.getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await save(page)
  const current = JSON.parse((await saved(page, project.id)).document).sheets[0].cells[0].cell_ui
  expect(current.future_ui).toEqual({ retained: ['future'] }); expect(current.inputs[0].future).toEqual({ retained: true }); expect(current.pre[0].future_component).toBe('keep'); expect(current.pre[0].fields[3].control.options[0].future_option).toBe(true); expect(current.post).toEqual(document.sheets[0].cells[0].cell_ui.post)
  expect(original.document).toContain('9223372036854775806')
})

test('parameter drafts guard navigation and layouts fit light/dark desktop and mobile', async ({ page }) => {
  await login(page); const { project } = await book(page); await page.goto(`/projects/${project.id}`)
  const region = form(page, 'Local gain form'); await region.getByLabel('Local gain', { exact: true }).fill('7')
  page.once('dialog', dialog => dialog.dismiss()); await page.getByRole('link', { name: 'Notebook Library', exact: true }).click(); await expect(region.getByLabel('Local gain', { exact: true })).toHaveValue('7')
  await region.getByRole('button', { name: 'Reset to current', exact: true }).click()
  const errors: string[] = []; page.on('pageerror', error => errors.push(error.message))
  for (const colorScheme of ['light', 'dark'] as const) {
    await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' })
    for (const width of [1280, 375, 320]) {
      await page.setViewportSize({ width, height: 1000 }); expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
      if (width !== 320) await page.screenshot({ path: `../build/notebook-inputs-${colorScheme}-${width}.png`, fullPage: true })
      await page.getByRole('button', { name: 'Components for cell 2', exact: true }).click(); expect(await page.getByRole('dialog', { name: 'Cell Components & Parameters', exact: true }).evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true)
      if (width !== 320) await page.screenshot({ path: `../build/notebook-input-designer-${colorScheme}-${width}.png` }); await page.getByRole('button', { name: 'Close input designer', exact: true }).click()
    }
  }
  expect(errors).toEqual([])
})
