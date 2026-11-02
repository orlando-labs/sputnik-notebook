import { expect, test, type Page } from '@playwright/test'
import net from 'node:net'
async function rpc(method: string, params = {}): Promise<any> {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(`${process.env.NOTEBOOK_WEB_TEST_CORE_ROOT}/agent.sock`); let buffer = ''
    socket.setTimeout(30000, () => socket.destroy(new Error('Core test timeout'))); socket.on('error', reject)
    socket.on('connect', () => socket.write(JSON.stringify({ method, params }) + '\n'))
    socket.on('data', chunk => { buffer += chunk; if (!buffer.includes('\n')) return; socket.end(); const response = JSON.parse(buffer.split('\n')[0]!); if (response.status !== 200) reject(new Error(JSON.stringify(response))); else resolve(response.data) })
  })
}
async function login(page: Page, user = 'Alice') {
  await page.goto('/'); await page.getByRole('button', { name: 'Continue with GitHub' }).click(); await page.getByRole('button', { name: `Sign in as ${user}` }).click(); await expect(page.getByTestId('account-name')).toHaveText(user)
}
async function request(page: Page, path: string, method = 'GET', data?: unknown) {
  const token = (await page.context().cookies()).find(cookie => cookie.name === 'orbit-csrf')?.value
  return page.request.fetch(path, { method, data, headers: { Accept: 'application/json', Origin: new URL(page.url()).origin, ...(token ? { 'X-CSRF-Token': decodeURIComponent(token) } : {}) } })
}
const execution = (id: string) => `/api/projects/${id}/execution`
const stored = async (page: Page, id: string) => (await (await request(page, `/api/projects/${id}/notebook`)).json()).notebook
const registry = async (page: Page, id: string) => (await (await request(page, execution(id))).json())
const card = (page: Page, id: string) => page.locator(`[data-board-component="${id}"]`)
async function openBoard(page: Page, title: string) { await page.getByRole('navigation', { name: 'Boards', exact: true }).getByRole('button', { name: title, exact: true }).click(); await expect(page.getByTestId('notebook-board')).toBeVisible() }
function panel(id: string, title: string, components: any[]) { return { id, title, rows: [{ id: `${id}_row` }], components: components.map(item => ({ ...item, row: `${id}_row`, span: Math.floor(12 / components.length) })) } }
function board(id: string, title: string, sheet: string, components: any[], modern = true) { return { id, title, sheet, columns: 2, ...(modern ? { rows: components.filter(item => item.kind !== 'periodic_work').map((_, i) => ({ id: `${id}_row${i}` })), components: components.map((item, i) => item.kind === 'periodic_work' ? item : { ...item, row: `${id}_row${i}`, span: 12 }) } : { components }) } }
async function book(page: Page, sheets: any[], boards: any[], inputs: any[] = [], withService = false) {
  const response = await request(page, '/api/projects', 'POST', { title: `Board ${crypto.randomUUID()}` }); expect(response.status()).toBe(201)
  const project = (await response.json()).project
  await request(page, `/api/projects/${project.id}/notebook`, 'POST', {})
  const initial = await stored(page, project.id), document = JSON.parse(initial.document)
  Object.assign(document, { version: 4, active_sheet: sheets[0].id, sheets, boards, inputs, dependencies: [] })
  const changes = withService ? { 'modules/jobs.s': { encoding: 'utf8', data: 'package jobs\nexport tick\ndef tick(): 42\n' } } : {}
  if (withService) document.modules = [{ id: 'jobs', path: 'modules/jobs.s' }]
  const saved = await request(page, `/api/projects/${project.id}/notebook`, 'PUT', { command_id: crypto.randomUUID(), base_revision: initial.revision, document: JSON.stringify(document), changes })
  expect(saved.status(), await saved.text()).toBe(200)
  return { project, notebook: (await saved.json()).notebook, document }
}
async function release(page: Page, id: string) {
  const current = await registry(page, id)
  for (const run of current.runs.filter((value: any) => !['succeeded', 'failed', 'cancelled', 'force-stopped', 'interrupted'].includes(value.state))) {
    await request(page, `${execution(id)}/runs/${run.id}/stop`, 'POST', { command_id: crypto.randomUUID(), runtime_epoch: run.runtime_epoch, force: true })
    await expect.poll(async () => (await registry(page, id)).runs.find((value: any) => value.id === run.id)?.state).toMatch(/^(succeeded|failed|cancelled|force-stopped|interrupted)$/)
  }
  const sheets = JSON.parse((await stored(page, id)).document).sheets.map((sheet: any) => sheet.id)
  for (const runtime of current.runtimes.filter((value: any) => sheets.includes(value.sheet_id) && !current.reset_epochs.includes(value.runtime_epoch))) expect((await request(page, `${execution(id)}/restart`, 'POST', { command_id: crypto.randomUUID(), sheet_id: runtime.sheet_id, runtime_epoch: runtime.runtime_epoch })).status()).toBe(200)
}
const cell = (id: string, source: string, mode = 'manual') => ({ id, kind: 'code', mode, source })

test('existing boards open inertly with legacy/row layouts, nested panels and explicit unavailable components', async ({ page }) => {
  await login(page)
  const components = [
    { id: 'metric', kind: 'metric', title: 'Score', cell: '1', binding: 'score' },
    { id: 'tabs', kind: 'tabs', title: 'Workspace', panels: [panel('first', 'First', [{ id: 'nested_metric', kind: 'metric', title: 'Nested score', cell: '1', binding: 'nested' }]), panel('second', 'Second', [{ id: 'note', kind: 'rich_text', title: 'Notes', text_content: { source: '<script>visible source</script>' } }])] },
    { id: 'group', kind: 'group', title: 'Details', p1: { collapsed: true }, panels: [panel('group_panel', 'Group', [{ id: 'missing', kind: 'metric', title: 'Missing source', cell: '999' }])] },
    { id: 'split', kind: 'split', title: 'Comparison', split_fraction: .35, split_axis: 'horizontal', panels: [panel('left', 'Left', [{ id: 'left_metric', kind: 'metric', title: 'Left score', cell: '1', binding: 'score' }]), panel('right', 'Right', [{ id: 'right_result', kind: 'result', title: 'Right result', cell: '1' }])] },
    { id: 'audio', kind: 'audio', title: 'Audio', cell: '1' },
    { id: 'service', kind: 'periodic_work', title: 'Scheduled work', module_id: 'jobs', function: 'tick', run_immediately: true, pause_when_hidden: false },
  ]
  const modern = board('dashboard', 'Dashboard', 'main', components)
  modern.rows![0]!.height = 180
  modern.components[0].span = 6
  modern.components.push({ id: 'summary', kind: 'result', title: 'Scalar result', cell: '1', row: modern.rows![0]!.id, span: 6 })
  ;(modern as any).future_layout = { retained: ['native'] }
  const legacy = board('legacy', 'Legacy', 'main', [{ id: 'legacy_a', kind: 'metric', title: 'Legacy A', cell: '1' }, { id: 'legacy_b', kind: 'text', title: 'Legacy B', cell: '1' }], false)
  const { project, notebook } = await book(page, [{ id: 'main', title: 'Main', cells: [cell('1', 'score = 42\nnested = 9223372036854775807\nscore\n')] }], [modern, legacy], [], true)
  try {
    await page.goto(`/projects/${project.id}`)
    const mutations: string[] = []; page.on('request', value => { if (['POST', 'PUT', 'DELETE'].includes(value.method())) mutations.push(value.url()) })
    await openBoard(page, 'Dashboard')
    await expect(card(page, 'metric')).toContainText('Unavailable')
    await expect(card(page, 'audio')).toContainText('Audio channel unavailable')
    await expect(page.getByRole('region', { name: 'Services', exact: true })).toContainText('continues when this board or browser is closed')
    await expect(card(page, 'missing')).toBeHidden()
    await card(page, 'group').getByRole('button', { name: 'Details' }).click()
    await expect(card(page, 'missing')).toContainText('Source cell unavailable')
    const second = card(page, 'tabs').getByRole('tab', { name: 'Second', exact: true })
    await second.click(); await expect(card(page, 'note')).toContainText('<script>visible source</script>')
    await second.press('Home'); await expect(card(page, 'tabs').getByRole('tab', { name: 'First' })).toBeFocused()
    await card(page, 'split').getByRole('slider').fill('0.7')
    await openBoard(page, 'Legacy')
    expect(await card(page, 'legacy_a').evaluate(element => getComputedStyle(element).gridColumnStart)).toBe('span 6')
    expect(await stored(page, project.id)).toEqual(notebook); expect((await registry(page, project.id)).runs).toEqual([]); expect(mutations).toEqual([])
    await openBoard(page, 'Dashboard')
    await page.getByRole('button', { name: 'Run Sheet', exact: true }).click()
    await expect(page.getByLabel('Score value', { exact: true })).toHaveText('42')
    await expect(page.getByLabel('Nested score value', { exact: true })).toHaveText('9223372036854775807')
    expect(await card(page, 'metric').evaluate(element => Math.round(element.getBoundingClientRect().height))).toBe(180)
    const run = (await registry(page, project.id)).runs.at(-1)
    const result = (await (await request(page, `${execution(project.id)}/runs/${run.id}`)).json()).run
    expect(result.rich_error).toBe(''); expect(result.cells[0].metrics.map((item: any) => item.name).sort()).toEqual(['nested', 'score'])
    for (const colorScheme of ['light', 'dark'] as const) {
      await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' })
      for (const width of [1280, 375, 320]) {
        await page.setViewportSize({ width, height: 900 }); expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
        if (width !== 320) await page.getByTestId('notebook-board').screenshot({ path: `../build/board-layout-${colorScheme}-${width}.png` })
      }
    }
    expect(await stored(page, project.id)).toEqual(notebook)
    await page.getByRole('button', { name: 'Open Sheet', exact: true }).click(); await expect(page.getByTestId('notebook-board')).toHaveCount(0)
    await expect(page.getByRole('textbox', { name: 'Code cell 1', exact: true })).toBeVisible()
    await openBoard(page, 'Dashboard'); await page.getByRole('button', { name: 'New sheet', exact: true }).click()
    await expect(page.getByTestId('notebook-board')).toHaveCount(0)
    await expect(page.getByRole('textbox', { name: 'Sheet title', exact: true })).toHaveValue('Sheet 2')
  } finally { await release(page, project.id) }
})

test('board parameters use explicit Apply, remain cold until Run and protect hidden/navigation drafts', async ({ page }) => {
  await login(page)
  const tabs = { id: 'tabs', kind: 'tabs', title: 'Parameters', panels: [panel('controls', 'Controls', [{ id: 'gain_input', kind: 'input', title: 'Gain control', input: 'gain' }]), panel('value', 'Value', [{ id: 'score', kind: 'metric', title: 'Computed score', cell: '1', binding: 'score' }])] }
  const { project, notebook } = await book(page, [{ id: 'main', title: 'Main', cells: [cell('1', 'score = notebook.input("gain") * 2\nscore\n', 'watch')] }], [board('dashboard', 'Dashboard', 'main', [tabs])], [{ id: 'gain', title: 'Gain', type: 'integer', default: 2 }])
  try {
    await page.goto(`/projects/${project.id}`); await openBoard(page, 'Dashboard')
    const control = card(page, 'gain_input'), input = control.getByLabel('Gain', { exact: true })
    await input.fill('4')
    await card(page, 'tabs').getByRole('tab', { name: 'Value', exact: true }).click()
    await card(page, 'tabs').getByRole('tab', { name: 'Controls', exact: true }).click(); await expect(input).toHaveValue('4')
    page.once('dialog', dialog => dialog.dismiss()); await page.getByRole('button', { name: 'Open Sheet', exact: true }).click(); await expect(page.getByTestId('notebook-board')).toBeVisible(); await expect(input).toHaveValue('4')
    await control.getByRole('button', { name: 'Apply', exact: true }).click(); await expect(control.getByRole('button', { name: 'Apply', exact: true })).toBeDisabled()
    expect((await registry(page, project.id)).runs).toEqual([])
    await page.getByRole('button', { name: 'Run Sheet', exact: true }).click()
    await card(page, 'tabs').getByRole('tab', { name: 'Value', exact: true }).click(); await expect(page.getByLabel('Computed score value', { exact: true })).toHaveText('8')
    await card(page, 'tabs').getByRole('tab', { name: 'Controls', exact: true }).click()
    await input.fill('6'); await control.getByRole('button', { name: 'Apply', exact: true }).click(); await expect(control.getByRole('button', { name: 'Apply', exact: true })).toBeDisabled()
    await card(page, 'tabs').getByRole('tab', { name: 'Value', exact: true }).click(); await expect(page.getByLabel('Computed score value', { exact: true })).toHaveText('12')
    expect((await runHistory(page, project.id)).runs.map((item: any) => item.action)).toEqual(['run_all', 'inputs'])
    expect(await stored(page, project.id)).toEqual(notebook)
  } finally { await release(page, project.id) }
})

test('board live channels, progress and stopwatch reconnect to the controller without replay', async ({ page }) => {
  await login(page)
  const components = [{ id: 'chart', kind: 'live_chart', title: 'Live loss', chart_id: 'loss' }, { id: 'progress', kind: 'progress', title: 'Work', cell: '1', progress_id: 'work' }, { id: 'clock', kind: 'stopwatch', title: 'Clock', stopwatch_id: 'training' }, { id: 'image', kind: 'image', title: 'Frame', image_id: 'hero' }, { id: 'table', kind: 'table', title: 'Result rows', cell: '1' }]
  const { project } = await book(page, [{ id: 'main', title: 'Main', cells: [cell('1', 'from notebook.ui import Stopwatch\nimport task\nnotebook.chart_point("loss", 0, 9)\nnotebook.progress("work", 1, 2, "Work", false)\nnotebook.images("hero", [{data: [255,0,0], width: 1, height: 1, format: :rgb}])\nStopwatch.measure("training"):\n  task.sleep(4000)\nnotebook.chart_point("loss", 1, 4)\nnotebook.progress("work", 2, 2, "Work", true)\n[[42]]\n')] }], [board('dashboard', 'Dashboard', 'main', components)])
  try {
    await page.goto(`/projects/${project.id}`); await openBoard(page, 'Dashboard'); await page.getByRole('button', { name: 'Run Sheet', exact: true }).click()
    await expect(card(page, 'chart').getByRole('img')).toBeVisible(); await expect(card(page, 'progress')).toContainText('Running')
    await expect(card(page, 'clock')).toContainText('Running'); await expect(card(page, 'image').getByRole('img')).toBeVisible()
    await expect(card(page, 'image').getByRole('button', { name: 'Save image…' })).toHaveCount(0)
    const runID = (await registry(page, project.id)).runs[0].id
    const posts: string[] = []; page.on('request', value => { if (value.method() === 'POST' && value.url().includes('/execution/')) posts.push(value.url()) })
    await page.reload(); await openBoard(page, 'Dashboard')
    await expect(card(page, 'chart')).toContainText('2 retained / 2 total samples')
    await expect(card(page, 'clock')).toContainText('Finished'); await expect(card(page, 'progress')).toContainText('Finished')
    await expect(card(page, 'table')).toContainText('42')
    for (const colorScheme of ['light', 'dark'] as const) {
      await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' })
      for (const width of [1280, 375]) {
        await page.setViewportSize({ width, height: 900 })
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
        await page.getByTestId('notebook-board').screenshot({ path: `../build/board-results-${colorScheme}-${width}.png` })
      }
    }
    expect((await registry(page, project.id)).runs).toHaveLength(1); expect((await registry(page, project.id)).runs[0].id).toBe(runID); expect(posts).toEqual([])
  } finally { await release(page, project.id) }
})

test('boards isolate controller sheets and keep immutable historical metric bindings', async ({ page }) => {
  await login(page)
  const first = board('first_board', 'First board', 'first', [{ id: 'metric', kind: 'metric', title: 'First metric', cell: '1', binding: 'score' }, { id: 'chart', kind: 'live_chart', title: 'Shared channel', chart_id: 'shared' }, { id: 'run', kind: 'run', title: 'Run first cell', cell: '1' }])
  const second = board('second_board', 'Second board', 'second', [{ id: 'second_metric', kind: 'metric', title: 'Second metric', cell: '2', binding: 'score' }, { id: 'second_chart', kind: 'live_chart', title: 'Other channel', chart_id: 'shared' }])
  const { project } = await book(page, [{ id: 'first', title: 'First', cells: [cell('1', 'score = 7\nother = 99\nnotebook.chart_point("shared", 0, 7)\nscore\n')] }, { id: 'second', title: 'Second', cells: [cell('2', 'score = 11\nnotebook.chart_point("shared", 0, 11)\nscore\n')] }], [first, second])
  try {
    await page.goto(`/projects/${project.id}`); await openBoard(page, 'First board'); await card(page, 'run').getByRole('button', { name: 'Run first cell', exact: true }).click()
    await expect(page.getByLabel('First metric value', { exact: true })).toHaveText('7')
    const firstRun = (await registry(page, project.id)).runs[0]
    await openBoard(page, 'Second board'); await expect(page.getByLabel('Second metric value', { exact: true })).toHaveText('Unavailable'); await expect(card(page, 'second_chart')).toContainText('Waiting for chart samples')
    await page.getByRole('button', { name: 'Run Sheet', exact: true }).click(); await expect(page.getByLabel('Second metric value', { exact: true })).toHaveText('11')
    await openBoard(page, 'First board'); await expect(page.getByLabel('First metric value', { exact: true })).toHaveText('7')
    const saved = await stored(page, project.id), document = JSON.parse(saved.document)
    document.boards[0].components[0].binding = 'other'
    expect((await request(page, `/api/projects/${project.id}/notebook`, 'PUT', { command_id: crypto.randomUUID(), base_revision: saved.revision, document: JSON.stringify(document) })).status()).toBe(200)
    await page.getByRole('button', { name: 'Reload saved notebook' }).click()
    await expect(page.getByLabel('First metric value', { exact: true })).toHaveText('Unavailable')
    const old = (await (await request(page, `${execution(project.id)}/runs/${firstRun.id}`)).json()).run
    expect(old.cells[0].metrics).toEqual([{ name: 'score', value: '7' }])
    await page.getByRole('button', { name: 'Run Sheet', exact: true }).click(); await expect(page.getByLabel('First metric value', { exact: true })).toHaveText('99')
    await page.locator('.run-history > summary').click(); await page.getByRole('button', { name: `View run ${firstRun.id}` }).click()
    await expect(page.getByTestId('notebook-board')).toBeVisible(); await expect(page.getByLabel('First metric value', { exact: true })).toHaveText('Unavailable')
  } finally { await release(page, project.id) }
})

test('board readers inspect results and exports while ACL revocation clears the runtime view', async ({ page, browser, baseURL }) => {
  await login(page)
  const { project } = await book(page, [{ id: 'main', title: 'Main', cells: [cell('1', 'score = 42\nnotebook.chart_point("loss", 0, 3)\nscore\n')] }], [board('dashboard', 'Dashboard', 'main', [{ id: 'score', kind: 'metric', title: 'Score', cell: '1', binding: 'score' }, { id: 'chart', kind: 'live_chart', title: 'Chart', chart_id: 'loss' }, { id: 'control', kind: 'input', title: 'Input', input: 'gain' }])], [{ id: 'gain', title: 'Gain', type: 'integer', default: 2 }])
  const viewer = await browser.newContext({ baseURL })
  try {
    await page.goto(`/projects/${project.id}`); await openBoard(page, 'Dashboard'); await page.getByRole('button', { name: 'Run Sheet', exact: true }).click(); await expect(page.getByLabel('Score value', { exact: true })).toHaveText('42')
    const bob = await viewer.newPage(); await login(bob, 'Bob'); const bobID = (await (await request(bob, '/api/session')).json()).account.id
    expect((await request(bob, execution(project.id))).status()).toBe(404)
    await request(page, `/api/projects/${project.id}/memberships`, 'POST', { account_id: bobID, role: 'viewer' })
    await bob.goto(`/projects/${project.id}`); await openBoard(bob, 'Dashboard'); await expect(bob.getByLabel('Score value', { exact: true })).toHaveText('42')
    await expect(bob.getByRole('button', { name: 'Run Sheet', exact: true })).toHaveCount(0)
    await expect(card(bob, 'control').getByLabel('Gain', { exact: true })).toBeDisabled()
    const csv = bob.waitForEvent('download'); await card(bob, 'chart').getByRole('button', { name: 'Export samples CSV…' }).click(); expect((await csv).suggestedFilename()).toBe('chart.csv')
    const runs = (await registry(page, project.id)).runs; const result = (await (await request(bob, `${execution(project.id)}/runs/${runs[0].id}`)).json()).run
    expect(JSON.stringify(result)).not.toMatch(/execution_document|worker_pid|"runtime_id"|\/private\//)
    await request(page, `/api/projects/${project.id}/memberships/${bobID}`, 'DELETE')
    await expect(bob.getByLabel('Score value', { exact: true })).toHaveText('Unavailable'); await expect(card(bob, 'chart')).toContainText('Waiting for chart samples')
    expect((await registry(page, project.id)).runs).toHaveLength(1)
  } finally { await viewer.close(); await release(page, project.id) }
})

test('isolated action worlds never replace controller board results or cell controls', async ({ page }) => {
  await login(page)
  const components = [{ id: 'metric', kind: 'metric', title: 'Controller score', cell: '1', binding: 'score' }, { id: 'action', kind: 'action', title: 'Isolated job', module_id: 'jobs', function: 'tick' }]
  const { project, notebook } = await book(page, [{ id: 'main', title: 'Main', cells: [cell('1', 'score = 7\nscore\n')] }], [board('dashboard', 'Dashboard', 'main', components)], [], true)
  try {
    await page.goto(`/projects/${project.id}`); await openBoard(page, 'Dashboard'); await page.getByRole('button', { name: 'Run Sheet', exact: true }).click(); await expect(page.getByLabel('Controller score value', { exact: true })).toHaveText('7')
    const source = (await rpc('project.list')).projects.find((item: any) => item.title === project.title)
    const accepted = await rpc('run.start', { project_id: source.id, command_id: crypto.randomUUID(), revision: notebook.revision, action: 'action_run', board_id: 'dashboard', component_id: 'action' })
    await expect.poll(async () => (await rpc('run.get', { run_id: accepted.run_id })).state).toBe('succeeded')
    await expect.poll(async () => (await runHistory(page, project.id)).runs.length).toBe(2)
    await page.locator('.run-history > summary').click()
    await page.getByRole('button', { name: `View run ${accepted.run_id}` }).click()
    await expect(page.getByTestId('invocation-result').getByLabel('Cell result', { exact: true })).toHaveText('42')
    await expect(page.locator('.run-history')).toContainText('Action · action')
    await page.getByRole('button', { name: 'Close output', exact: true }).click()
    await expect(page.getByLabel('Controller score value', { exact: true })).toHaveText('7')
    await expect(page.getByRole('button', { name: 'Run Sheet', exact: true })).toBeEnabled()
    await page.reload(); await openBoard(page, 'Dashboard'); await expect(page.getByLabel('Controller score value', { exact: true })).toHaveText('7')
    await page.getByRole('button', { name: 'Open Sheet', exact: true }).click(); await expect(page.getByLabel('Cell result', { exact: true })).toHaveText('7')
    expect((await runHistory(page, project.id)).runs).toHaveLength(2)
  } finally { await release(page, project.id) }
})

async function runHistory(page: Page, id: string) {
  const response = await page.request.get(`/api/projects/${id}/execution/history`)
  expect(response.ok()).toBe(true)
  return response.json()
}
