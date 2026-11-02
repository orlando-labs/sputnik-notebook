import { expect, test, type Page } from '@playwright/test'
async function login(page: Page, user = 'Alice') { await page.goto('/'); await page.getByRole('button', { name: 'Continue with GitHub' }).click(); await page.getByRole('button', { name: `Sign in as ${user}` }).click(); await expect(page.getByTestId('account-name')).toHaveText(user) }
async function request(page: Page, path: string, method = 'GET', data?: unknown) { const token = (await page.context().cookies()).find(cookie => cookie.name === 'orbit-csrf')?.value; return page.request.fetch(path, { method, data, headers: { Accept: 'application/json', Origin: new URL(page.url()).origin, ...(token ? { 'X-CSRF-Token': decodeURIComponent(token) } : {}) } }) }
const base = (id: string) => `/api/projects/${id}/execution`
const registry = async (page: Page, id: string) => (await (await request(page, base(id))).json())
const stored = async (page: Page, id: string) => (await (await request(page, `/api/projects/${id}/notebook`)).json()).notebook
const card = (page: Page, id: string) => page.locator(`[data-board-component="${id}"]`)
const service = (page: Page) => page.getByRole('article', { name: 'Periodic counter', exact: true })
const output = (page: Page) => page.getByTestId('invocation-result')
async function open(page: Page, id: string) { await page.goto(`/projects/${id}`); await page.getByRole('navigation', { name: 'Boards', exact: true }).getByRole('button', { name: 'Dashboard', exact: true }).click() }
const code = 'package jobs\nimport task\nclass Counter:\n  def init(): @value = 0\n  def next():\n    @value += 1\n    @value\nState = Counter()\ndef compute(x, other:): [State.next(), x, other]\ndef tick(): State.next()\ndef slow():\n  task.sleep(350)\n  State.next()\ndef fail(): raise "Service example failure"\ndef long():\n  while true:\n    task.sleep(50)\n  1\nexport compute, tick, slow, fail, long\n'
async function book(page: Page, settings: Record<string, unknown> = {}) {
  const project = (await (await request(page, '/api/projects', 'POST', { title: `Commands ${crypto.randomUUID()}` })).json()).project
  const initial = (await (await request(page, `/api/projects/${project.id}/notebook`, 'POST', {})).json()).notebook, document = JSON.parse(initial.document)
  const components: any[] = [{ id: 'metric', kind: 'metric', title: 'Controller score', cell: '1', binding: 'score', row: 'r1', span: 12 }, { id: 'act', kind: 'action', title: 'Compute', module_id: 'jobs', function: 'compute', row: 'r2', span: 6, p1: { arguments: [{ id: 'x', input: 'gain' }, { id: 'other', name: 'other', value_json: '-9223372036854775808' }] } }, { id: 'controls', kind: 'execution_controls', title: 'Action controls', row: 'r2', span: 6, p1: { target_kind: 'action', target_component: 'act' } }, { id: 'sheet_controls', kind: 'execution_controls', title: 'Sheet controls', row: 'r3', span: 12, p1: { target_kind: 'sheet' } }, { id: 'job', kind: 'periodic_work', title: 'Periodic counter', module_id: 'jobs', function: 'tick', period_seconds: .15, timing: 'fixed_delay', retention: 'tail', tail_limit: 2, run_immediately: false, pause_when_hidden: true, ...settings }]
  Object.assign(document, { version: 4, modules: [{ id: 'jobs', path: 'modules/jobs.s' }], inputs: [{ id: 'gain', title: 'Gain', type: 'integer', default: '__exact__' }], boards: [{ id: 'dash', title: 'Dashboard', sheet: 'main', columns: 2, rows: [{ id: 'r1' }, { id: 'r2' }, { id: 'r3' }], components }], sheets: [{ id: 'main', title: 'Main', cells: [{ id: '1', kind: 'code', source: 'score = 7\nscore\n', mode: 'manual' }] }], active_sheet: 'main', dependencies: [] })
  const saved = await request(page, `/api/projects/${project.id}/notebook`, 'PUT', { command_id: crypto.randomUUID(), base_revision: initial.revision, document: JSON.stringify(document).replace('"__exact__"', '9223372036854775807'), changes: { 'modules/jobs.s': { encoding: 'utf8', data: code } } })
  expect(saved.status(), await saved.text()).toBe(200)
  return { project, notebook: (await saved.json()).notebook }
}
const configure = (page: Page, id: string, revision: string, operation: string, command = crypto.randomUUID()) => request(page, `${base(id)}/services`, 'POST', { command_id: command, revision, board_id: 'dash', component_id: 'job', operation })
async function waitTerminal(page: Page, id: string, run: string) { await expect.poll(async () => (await registry(page, id)).runs.find((value: any) => value.id === run)?.state, { timeout: 15000 }).toMatch(/^(succeeded|failed|cancelled|force-stopped|interrupted)$/) }
async function release(page: Page, id: string) {
  let current = await registry(page, id)
  for (const value of current.services || []) if (value.enabled) await request(page, `${base(id)}/services`, 'POST', { command_id: crypto.randomUUID(), revision: current.revision, board_id: value.board_id, component_id: value.component_id, operation: 'pause' })
  for (const run of current.runs.filter((run: any) => !['succeeded', 'failed', 'cancelled', 'force-stopped', 'interrupted'].includes(run.state))) { await request(page, `${base(id)}/runs/${run.id}/stop`, 'POST', { command_id: crypto.randomUUID(), runtime_epoch: run.runtime_epoch, force: true }); await waitTerminal(page, id, run.id) }
  current = await registry(page, id)
  const targets = new Map<string, any>(); for (const run of current.runs) if (run.board_id) targets.set(`${run.board_id}:${run.component_id}`, run)
  for (const run of targets.values()) await request(page, `${base(id)}/runs/${run.id}/restart`, 'POST', { command_id: crypto.randomUUID(), runtime_epoch: run.runtime_epoch })
  for (const runtime of current.runtimes.filter((value: any) => !current.reset_epochs.includes(value.runtime_epoch))) await request(page, `${base(id)}/restart`, 'POST', { command_id: crypto.randomUUID(), sheet_id: runtime.sheet_id, runtime_epoch: runtime.runtime_epoch })
}

test('actions freeze exact arguments, keep isolated state, expose history and leave controller results intact', async ({ page }) => {
  await login(page); const { project, notebook } = await book(page)
  try {
    await open(page, project.id); expect((await registry(page, project.id)).runs).toEqual([])
    await card(page, 'sheet_controls').getByRole('button', { name: 'Run', exact: true }).click(); await expect(page.getByLabel('Controller score value', { exact: true })).toHaveText('7')
    await card(page, 'act').getByRole('button', { name: 'Compute', exact: true }).click(); await expect(output(page).getByLabel('Cell result', { exact: true })).toHaveText('[1, 9223372036854775807, -9223372036854775808]')
    await card(page, 'controls').getByRole('button', { name: 'Run', exact: true }).click(); await expect(output(page).getByLabel('Cell result', { exact: true })).toHaveText('[2, 9223372036854775807, -9223372036854775808]')
    await expect(page.getByLabel('Controller score value', { exact: true })).toHaveText('7')
    expect(await stored(page, project.id)).toEqual(notebook)
    const state = await registry(page, project.id); expect(state.runs.filter((run: any) => run.action === 'action_run')).toHaveLength(1); expect((await runHistory(page, project.id)).runs.filter((run: any) => run.action === 'action_run')).toHaveLength(2); expect(state.runtimes.map((runtime: any) => runtime.sheet_id)).toEqual(['main']); expect(JSON.stringify(state)).not.toMatch(/core_project_id|runtime_id|service_[a-f0-9]{64}|worker_pid|\/private\//)
    await page.reload(); await page.getByRole('navigation', { name: 'Boards', exact: true }).getByRole('button', { name: 'Dashboard', exact: true }).click(); await card(page, 'act').getByRole('button', { name: 'View output', exact: true }).click(); await expect(output(page).getByLabel('Cell result', { exact: true })).toContainText('[2,')
    for (const colorScheme of ['light', 'dark'] as const) { await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' }); for (const width of [1280, 375, 320]) { await page.setViewportSize({ width, height: 900 }); expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true); if (width !== 320) await page.screenshot({ path: `../build/board-commands-${colorScheme}-${width}.png`, fullPage: true }) } }
  } finally { await release(page, project.id) }
})

test('server schedules survive a closed board, pause explicitly, retain tail history and clear without resetting counters', async ({ page, context }) => {
  await login(page); const { project, notebook } = await book(page); let monitor: Page | undefined
  try {
    await open(page, project.id); await expect(service(page).getByRole('button', { name: 'Start', exact: true })).toBeEnabled()
    expect((await registry(page, project.id)).services).toEqual([])
    await service(page).getByRole('button', { name: 'Start', exact: true }).click(); await expect.poll(async () => Number((await registry(page, project.id)).services[0]?.runs)).toBeGreaterThanOrEqual(1)
    monitor = await context.newPage(); await monitor.goto('/'); const before = Number((await registry(monitor, project.id)).services[0].runs); await page.close()
    await expect.poll(async () => Number((await registry(monitor, project.id)).services[0].runs)).toBeGreaterThan(before + 1)
    await open(monitor, project.id); await service(monitor).getByRole('button', { name: 'Pause', exact: true }).click(); await expect.poll(async () => (await registry(monitor, project.id)).services[0].enabled).toBe(false)
    await expect.poll(async () => (await registry(monitor, project.id)).services[0].running).toBe(false)
    const state = (await registry(monitor, project.id)).services[0]; expect(state.history_count).toBe('2')
    await service(monitor).getByRole('button', { name: 'History · 2', exact: true }).click(); await expect(monitor.getByTestId('service-history').locator('li')).toHaveCount(2)
    await service(monitor).getByRole('button', { name: 'Clear history', exact: true }).click(); await expect(monitor.getByTestId('service-history')).toContainText('No retained runs')
    expect((await registry(monitor, project.id)).services[0].runs).toBe(state.runs); expect(await stored(monitor, project.id)).toEqual(notebook)
    await release(monitor, project.id); await monitor.close()
  } finally { if (monitor && !monitor.isClosed()) await release(monitor, project.id); else if (!page.isClosed()) await release(page, project.id) }
})

test('fixed rate skips overlaps and service/module edits pause future calls while failures obey retention', async ({ page }) => {
  await login(page); const { project, notebook } = await book(page, { function: 'slow', period_seconds: .1, timing: 'fixed_rate', run_immediately: true })
  try {
    expect((await configure(page, project.id, notebook.revision, 'start')).status()).toBe(200)
    await expect.poll(async () => Number((await registry(page, project.id)).services[0]?.skipped)).toBeGreaterThan(0)
    await configure(page, project.id, notebook.revision, 'pause'); await expect.poll(async () => (await registry(page, project.id)).services[0].running).toBe(false)
    let current = await stored(page, project.id); let document = current.document.replace('"function":"slow"', '"function":"fail"').replace('"run_immediately":true', '"run_immediately":true,"stop_on_error":true')
    expect((await request(page, `/api/projects/${project.id}/notebook`, 'PUT', { command_id: crypto.randomUUID(), base_revision: current.revision, document })).status()).toBe(200)
    current = await stored(page, project.id); expect((await configure(page, project.id, current.revision, 'start')).status()).toBe(200)
    await expect.poll(async () => Number((await registry(page, project.id)).services[0].failures)).toBeGreaterThan(0); await expect.poll(async () => (await registry(page, project.id)).services[0].enabled).toBe(false)
    const history = await request(page, `${base(project.id)}/services/dash/job`); expect(history.status()).toBe(200); expect((await history.json()).history[0].error).toContain('Service example failure')
    expect((await configure(page, project.id, current.revision, 'start')).status()).toBe(200)
    const revised = await request(page, `/api/projects/${project.id}/notebook`, 'PUT', { command_id: crypto.randomUUID(), base_revision: current.revision, document: current.document, changes: { 'modules/jobs.s': { encoding: 'utf8', data: code + '\n# changed module\n' } } }); expect(revised.status()).toBe(200)
    await expect.poll(async () => (await registry(page, project.id)).services[0].enabled).toBe(false)
  } finally { await release(page, project.id) }
})

test('invocation stop, force stop and restart address their own worker and preserve the controller', async ({ page }) => {
  await login(page); const { project, notebook } = await book(page, { function: 'long', run_immediately: true })
  try {
    await open(page, project.id); await page.getByRole('button', { name: 'Run Sheet', exact: true }).click(); await expect(page.getByLabel('Controller score value', { exact: true })).toHaveText('7')
    await service(page).getByRole('button', { name: 'Run Once', exact: true }).click(); await expect(service(page).getByRole('button', { name: 'Stop', exact: true })).toBeEnabled(); await service(page).getByRole('button', { name: 'Stop', exact: true }).click()
    await expect.poll(async () => (await registry(page, project.id)).runs.at(-1).state).toBe('cancelled')
    await service(page).getByRole('button', { name: 'Run Once', exact: true }).click(); await expect(service(page).getByRole('button', { name: 'Force Stop…', exact: true })).toBeEnabled(); page.once('dialog', value => value.accept()); await service(page).getByRole('button', { name: 'Force Stop…', exact: true }).click()
    await expect.poll(async () => (await registry(page, project.id)).runs.at(-1).state).toBe('force-stopped')
    const last = (await registry(page, project.id)).runs.at(-1)
    expect((await request(page, `${base(project.id)}/runs/${last.id}/restart`, 'POST', { command_id: crypto.randomUUID(), runtime_epoch: 'stale' })).status()).toBe(409)
    page.once('dialog', value => value.accept()); await service(page).getByRole('button', { name: 'Restart…', exact: true }).click(); await expect.poll(async () => (await registry(page, project.id)).reset_epochs.includes(last.runtime_epoch)).toBe(true)
    await expect(page.getByLabel('Controller score value', { exact: true })).toHaveText('7'); expect(await stored(page, project.id)).toEqual(notebook)
  } finally { await release(page, project.id) }
})

test('lost accepted and unaccepted board commands recover exact receipts without automatic replay', async ({ page }) => {
  await login(page); const { project } = await book(page)
  try {
    await open(page, project.id); const commands: any[] = []
    await page.route(`**${base(project.id)}/commands/*`, route => route.abort('failed'))
    await page.route(`**${base(project.id)}/invocations`, async route => { commands.push(route.request().postDataJSON()); await route.fetch(); await route.abort('failed') })
    await card(page, 'act').getByRole('button', { name: 'Compute', exact: true }).click(); await expect(page.getByTestId('execution-message')).toContainText('outcome')
    await page.reload(); await expect(page.getByTestId('execution-message')).toContainText('outcome'); expect(commands).toHaveLength(1)
    await page.unroute(`**${base(project.id)}/commands/*`); await expect(page.getByTestId('execution-message')).toHaveCount(0); expect((await registry(page, project.id)).runs).toHaveLength(1)
    await page.unroute(`**${base(project.id)}/invocations`); await page.getByRole('navigation', { name: 'Boards', exact: true }).getByRole('button', { name: 'Dashboard', exact: true }).click()
    const once: any[] = []; await page.route(`**${base(project.id)}/services`, async route => { if (route.request().method() !== 'POST') return route.continue(); once.push(route.request().postDataJSON()); if (once.length === 1) return route.abort('failed'); await route.continue() })
    await service(page).getByRole('button', { name: 'Run Once', exact: true }).click(); await expect(page.getByRole('button', { name: 'Retry pending command', exact: true })).toBeVisible(); await page.reload(); await expect(page.getByRole('button', { name: 'Retry pending command', exact: true })).toBeVisible(); expect(once).toHaveLength(1)
    await page.getByRole('button', { name: 'Retry pending command', exact: true }).click(); await expect.poll(async () => (await runHistory(page, project.id)).runs.length).toBe(2); expect(once).toHaveLength(2); expect(once[1]).toEqual(once[0])
    await page.unroute(`**${base(project.id)}/services`)
    await expect.poll(async () => (await registry(page, project.id)).services[0].running).toBe(false)
    const acceptedOnce: any[] = []
    await page.route(`**${base(project.id)}/commands/*`, route => route.abort('failed'))
    await page.route(`**${base(project.id)}/services`, async route => { if (route.request().method() !== 'POST') return route.continue(); acceptedOnce.push(route.request().postDataJSON()); await route.fetch(); await route.abort('failed') })
    await page.getByRole('navigation', { name: 'Boards', exact: true }).getByRole('button', { name: 'Dashboard', exact: true }).click()
    await service(page).getByRole('button', { name: 'Run Once', exact: true }).click(); await expect(page.getByTestId('execution-message')).toContainText('outcome'); await page.reload(); expect(acceptedOnce).toHaveLength(1)
    const receipt = await request(page, `${base(project.id)}/commands/${acceptedOnce[0].command_id}`); expect((await receipt.json()).command.service.component_id).toBe('job')
    await page.unroute(`**${base(project.id)}/commands/*`); await expect(page.getByTestId('execution-message')).toHaveCount(0); expect((await runHistory(page, project.id)).runs).toHaveLength(3); expect(acceptedOnce).toHaveLength(1)
  } finally { if (!page.isClosed()) { await page.unrouteAll({ behavior: 'ignoreErrors' }); await release(page, project.id) } }
})

test('actions and services enforce ACL, CSRF, ownership and revoke open runtime data', async ({ page, browser, baseURL }) => {
  await login(page); const { project, notebook } = await book(page), other = await book(page)
  const context = await browser.newContext({ baseURL })
  try {
    const bob = await context.newPage(); await login(bob, 'Bob'); const bobID = (await (await request(bob, '/api/session')).json()).account.id
    await request(page, `/api/projects/${project.id}/memberships`, 'POST', { account_id: bobID, role: 'viewer' }); await open(bob, project.id)
    await expect(card(bob, 'act').getByRole('button', { name: 'Compute', exact: true })).toBeDisabled(); await expect(service(bob).getByRole('button', { name: 'Start', exact: true })).toBeDisabled()
    expect((await configure(bob, project.id, notebook.revision, 'start')).status()).toBe(403); expect((await page.request.post(`${base(project.id)}/services`, { data: {} })).status()).toBe(403)
    expect((await request(page, `${base(project.id)}/invocations`, 'POST', { command_id: crypto.randomUUID(), revision: 'stale', board_id: 'dash', component_id: 'act' })).status()).toBe(409)
    const accepted = await request(page, `${base(project.id)}/invocations`, 'POST', { command_id: crypto.randomUUID(), revision: notebook.revision, board_id: 'dash', component_id: 'act' }); expect(accepted.status()).toBe(200); const run = (await accepted.json()).run; await waitTerminal(page, project.id, run.id)
    expect((await request(page, `${base(other.project.id)}/runs/${run.id}`)).status()).toBe(404); expect((await request(page, `${base(other.project.id)}/runs/${run.id}/restart`, 'POST', { command_id: crypto.randomUUID(), runtime_epoch: run.runtime_epoch })).status()).toBe(404)
    await card(bob, 'act').getByRole('button', { name: 'View output', exact: true }).click(); await expect(output(bob)).toContainText('9223372036854775807')
    const onceID = crypto.randomUUID(), once = await configure(page, project.id, notebook.revision, 'once', onceID); expect(once.status()).toBe(200)
    const onceRun = (await once.json()).service.run_id; const duplicate = await configure(page, project.id, notebook.revision, 'once', onceID); expect(duplicate.status()).toBe(200); expect((await duplicate.json()).service.run_id).toBe(onceRun); await waitTerminal(page, project.id, onceRun)
    await service(bob).getByRole('button', { name: 'History · 1', exact: true }).click(); await expect(bob.getByTestId('service-history').locator('li')).toHaveCount(1)
    await request(page, `/api/projects/${project.id}/memberships/${bobID}`, 'DELETE'); await expect(output(bob)).toHaveCount(0); await expect(card(bob, 'act').getByRole('button', { name: 'View output', exact: true })).toHaveCount(0)
    await expect(bob.getByTestId('service-history')).toHaveCount(0)
    expect((await request(bob, `${base(project.id)}/services`)).status()).toBe(404)
  } finally { await context.close(); await release(page, project.id); await release(page, other.project.id) }
})

test('designer authors actions, service schedules and execution targets as inert drafts', async ({ page }) => {
  await login(page); const { project, notebook } = await book(page)
  try {
    await open(page, project.id); await page.getByRole('button', { name: 'Design board Dashboard', exact: true }).click(); const designer = page.getByRole('dialog', { name: 'Board Designer', exact: true })
    await designer.getByRole('button', { name: 'Add Action Button', exact: true }).click(); await designer.getByLabel('Component title', { exact: true }).fill('Designed action'); await designer.getByLabel('Exported function', { exact: true }).fill('compute')
    await designer.getByRole('button', { name: 'Add argument', exact: true }).click(); await designer.getByLabel('Argument 1 source', { exact: true }).selectOption('input'); await designer.getByRole('button', { name: 'Add argument', exact: true }).click(); await designer.getByLabel('Argument 2 name', { exact: true }).fill('other'); await designer.getByLabel('Argument 2 JSON', { exact: true }).fill('9223372036854775807')
    await designer.getByRole('button', { name: 'Add Execution Controls', exact: true }).click(); await designer.getByLabel('Execution target', { exact: true }).selectOption('action'); await designer.getByLabel('Target component', { exact: true }).selectOption({ label: 'Designed action' })
    await designer.getByRole('tab', { name: 'Services', exact: true }).click(); await designer.getByRole('button', { name: 'Add Periodic Work', exact: true }).click(); await designer.getByLabel('Component title', { exact: true }).fill('Designed service'); await designer.getByLabel('Service period', { exact: true }).fill('0'); await designer.getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await expect(designer.getByRole('alert')).toContainText(/Period|numeric/); await designer.getByLabel('Service period', { exact: true }).fill('0.25')
    await designer.getByRole('button', { name: 'Preview layout', exact: true }).click(); await expect(designer.getByRole('button', { name: 'Designed action', exact: true })).toBeDisabled(); await expect(designer.getByRole('article', { name: 'Designed service', exact: true }).getByRole('button', { name: 'Start', exact: true })).toBeDisabled()
    expect((await registry(page, project.id)).runs).toEqual([]); expect((await registry(page, project.id)).services).toEqual([]); expect(await stored(page, project.id)).toEqual(notebook)
    await designer.getByRole('button', { name: 'Update notebook draft', exact: true }).click(); await page.getByRole('button', { name: 'Save notebook', exact: true }).click(); await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved'); expect((await registry(page, project.id)).runs).toEqual([])
    await page.getByRole('button', { name: 'Designed action', exact: true }).click(); await expect(output(page).getByLabel('Cell result', { exact: true })).toHaveText('[1, 9223372036854775807, 9223372036854775807]')
  } finally { await release(page, project.id) }
})

async function runHistory(page: Page, id: string) {
  const response = await page.request.get(`/api/projects/${id}/execution/history`)
  expect(response.ok()).toBe(true)
  return response.json()
}
