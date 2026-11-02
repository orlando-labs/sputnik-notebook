import { expect, test, type Page } from '@playwright/test'
import net from 'node:net'
import { readFile } from 'node:fs/promises'
const created = new WeakMap<Page, string[]>()

async function login(page: Page, user = 'Alice') { await page.goto('/'); await page.getByRole('button', { name: 'Continue with GitHub' }).click(); await page.getByRole('button', { name: `Sign in as ${user}` }).click(); await expect(page.getByTestId('account-name')).toHaveText(user) }
async function request(page: Page, path: string, method = 'GET', data?: unknown) { const token = (await page.context().cookies()).find(item => item.name === 'orbit-csrf')?.value; return page.request.fetch(path, { method, data, headers: { Accept: 'application/json', Origin: new URL(page.url()).origin, ...(token ? { 'X-CSRF-Token': decodeURIComponent(token) } : {}) } }) }
const base = (id: string) => `/api/projects/${id}`
async function json(page: Page, path: string) { const response = await request(page, path); expect(response.status(), await response.text()).toBe(200); return response.json() }
async function setup(page: Page, mode = 'manual') {
  const title = 'History ' + crypto.randomUUID(); const p = (await (await request(page, '/api/projects', 'POST', { title })).json()).project
  const owned = created.get(page) || []; owned.push(p.id); created.set(page, owned)
  const initial = (await (await request(page, base(p.id) + '/notebook', 'POST', {})).json()).notebook; const document = JSON.parse(initial.document)
  Object.assign(document, { version: 4, dependencies: [], inputs: [{ id: 'exact', title: 'Exact', type: 'integer', default: '__exact__' }, { id: 'dataset', title: 'Dataset', type: 'string', default: '' }], boards: [{ id: 'history', title: 'Experiments', sheet: 'main', columns: 2, components: [{ id: 'history', kind: 'run_history', title: 'History' }, { id: 'compare', kind: 'experiment_compare', title: 'Compare' }, { id: 'file', kind: 'file_input', title: 'File', input: 'dataset' }] }] })
  document.sheets[0].cells[0] = { id: '1', kind: 'code', mode, source: 'notebook.input("exact")\n', cell_ui: { inputs: [{ id: 'gain', title: 'Local gain', type: 'integer', default_json: '2' }], pre: [{ id: 'form', kind: 'parameter_form', title: 'Local', fields: [{ input: 'gain' }] }], post: [] } }
  const saved = await request(page, base(p.id) + '/notebook', 'PUT', { command_id: crypto.randomUUID(), base_revision: initial.revision, document: JSON.stringify(document).replace('"__exact__"', '9223372036854775806'), changes: {} }); expect(saved.status(), await saved.text()).toBe(200)
  await page.goto(`/projects/${p.id}`); await expect(page.getByLabel('Code cell 1', { exact: true })).toBeVisible()
  return { ...p, revision: (await saved.json()).notebook.revision, title }
}
async function registry(page: Page, id: string) { return json(page, base(id) + '/execution') }
async function run(page: Page, p: { id: string; revision: string }) {
  const response = await request(page, base(p.id) + '/execution/runs', 'POST', { command_id: crypto.randomUUID(), revision: p.revision, sheet_id: 'main', cell_id: '1', action: 'run' }); expect(response.status(), await response.text()).toBe(200); const value = (await response.json()).run
  await expect.poll(async () => (await registry(page, p.id)).runs.find((r: any) => r.id === value.id)?.state).toBe('succeeded'); return value.id
}
async function snapshot(page: Page, id: string, run: string) { return json(page, base(id) + `/execution/runs/${run}/snapshot`) }
async function inputs(page: Page, id: string, cell?: string) { return json(page, base(id) + '/inputs' + (cell ? '?cell=' + cell : '')) }
async function apply(page: Page, id: string, values: Record<string, string>, cell?: string) { const state = await inputs(page, id, cell); const response = await request(page, base(id) + '/inputs' + (cell ? '?cell=' + cell : ''), 'PUT', { command_id: crypto.randomUUID(), revision: state.revision, base_version: state.version, values }); expect(response.status(), await response.text()).toBe(200); await expect.poll(async () => (await registry(page, id)).runs.every((run: any) => ['succeeded','failed','cancelled','force-stopped','interrupted'].includes(run.state))).toBe(true) }
async function annotate(page: Page, id: string, run: string, extra: Record<string, unknown> = {}) { const value = await snapshot(page, id, run); return request(page, base(id) + `/execution/runs/${run}/history`, 'POST', { command_id: crypto.randomUUID(), base_version: value.metadata.version, operation: 'update', title: '', pinned: false, ...extra }) }
const modal = (page: Page) => page.getByRole('dialog', { name: 'Run snapshots and experiments', exact: true })
async function show(page: Page, run: string) { await page.locator('details.run-history > summary').click(); await page.getByRole('button', { name: 'Snapshots and experiments…', exact: true }).click(); await modal(page).getByLabel('Snapshot run', { exact: true }).selectOption(run); await expect(modal(page).getByRole('button', { name: 'Export run snapshot…' })).toBeVisible() }
async function rpc(method: string, params = {}): Promise<any> { return new Promise((resolve, reject) => { const socket = net.createConnection(`${process.env.NOTEBOOK_WEB_TEST_CORE_ROOT}/agent.sock`); let text = ''; socket.setTimeout(30000, () => socket.destroy(new Error('Core timeout'))); socket.on('error', reject); socket.on('connect', () => socket.write(JSON.stringify({ method, params }) + '\n')); socket.on('data', chunk => { text += chunk; if (!text.includes('\n')) return; socket.end(); const value = JSON.parse(text.split('\n')[0]!); value.status === 200 ? resolve(value.data) : reject(new Error(JSON.stringify(value))) }) }) }
async function cid(p: { title: string }) { return (await rpc('project.list')).projects.find((project: any) => project.title === p.title).id }

test.afterEach(async ({ page }) => {
  for (const id of created.get(page) || []) {
    const response = await request(page, base(id) + '/execution'); if (response.status() !== 200) continue
    const state = await response.json(); const current = JSON.parse((await json(page, base(id) + '/notebook')).notebook.document); const sheets = new Set(current.sheets.map((sheet: any) => sheet.id))
    for (const run of state.runs.filter((run: any) => !['succeeded','failed','cancelled','force-stopped','interrupted'].includes(run.state))) { await request(page, base(id) + `/execution/runs/${run.id}/stop`, 'POST', { command_id: crypto.randomUUID(), runtime_epoch: run.runtime_epoch, force: true }); await expect.poll(async () => (await registry(page,id)).runs.find((item:any)=>item.id===run.id)?.state).toMatch(/^(succeeded|failed|cancelled|force-stopped|interrupted)$/) }
    for (const runtime of state.runtimes.filter((runtime:any) => !state.reset_epochs.includes(runtime.runtime_epoch) && sheets.has(runtime.sheet_id))) expect((await request(page, base(id) + '/execution/restart', 'POST', { command_id: crypto.randomUUID(), sheet_id: runtime.sheet_id, runtime_epoch: runtime.runtime_epoch })).status()).toBe(200)
  }
})

test('immutable snapshot retains exact project/local values, sources and private-free environment provenance', async ({ page }) => {
  await login(page); const p = await setup(page); const first = await run(page, p); const before = await snapshot(page, p.id, first)
  expect(before.snapshot.inputs.exact).toBe('9223372036854775806'); expect(before.snapshot.cell_inputs[0].values.gain).toBe('2'); expect(before.snapshot.environment.available).toBe(true)
  expect(JSON.stringify(before.snapshot)).not.toMatch(/core_project_id|runtime_id|worker_pid|environment_directory|\/Users\/|\/private\/|"grants"|"spec"/)
  await apply(page, p.id, { exact: '9223372036854775807' }); const second = await run(page, p); expect((await snapshot(page, p.id, second)).snapshot.inputs.exact).toBe('9223372036854775807')
  expect((await annotate(page, p.id, first, { title: 'Baseline', pinned: true })).status()).toBe(200)
  expect((await snapshot(page, p.id, first)).snapshot).toEqual(before.snapshot)
  await expect.poll(async () => (await registry(page, p.id)).runs.some((run: any) => run.id === second)).toBe(true); await show(page, first)
  const waiting = page.waitForEvent('download'); await modal(page).getByRole('button', { name: 'Export run snapshot…' }).click(); const exported = JSON.parse(await readFile((await (await waiting).path())!, 'utf8')); expect(exported).toEqual(before.snapshot)
  await modal(page).getByText('Inspect sources and environment', { exact: true }).click(); await expect(modal(page)).toContainText('notebook.input("exact")')
  for (const scheme of ['light', 'dark'] as const) for (const width of [1280, 375]) { await page.emulateMedia({ colorScheme: scheme }); await page.setViewportSize({ width, height: 1000 }); expect(await modal(page).evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true); await page.screenshot({ path: `../build/run-history-${scheme}-${width}-${process.env.ORBIT_E2E_MODE || 'production'}-${process.env.ORBIT_E2E_NATIVE === '1' ? 'native' : 'vm'}.png` }) }
})

test('comparison keeps Int64 delta exact and exports CSV through the board entry', async ({ page }) => {
  await login(page); const p = await setup(page); const first = await run(page, p); await apply(page, p.id, { exact: '9223372036854775807' }); const second = await run(page, p)
  await page.getByRole('navigation', { name: 'Boards', exact: true }).getByRole('button', { name: 'Experiments', exact: true }).click(); await page.getByRole('button', { name: 'Compare experiments…', exact: true }).click()
  await modal(page).getByLabel('Baseline', { exact: true }).selectOption(first); await modal(page).getByLabel('Snapshot run', { exact: true }).selectOption(second)
  const row = modal(page).getByRole('row').filter({ hasText: 'Input · exact' }); await expect(row).toContainText('9223372036854775806'); await expect(row).toContainText('9223372036854775807'); await expect(row).toContainText('+1')
  const waiting = page.waitForEvent('download'); await modal(page).getByRole('button', { name: 'Export comparison CSV…' }).click(); const csv = await readFile((await (await waiting).path())!, 'utf8'); expect(csv).toContain('9223372036854775806'); expect(csv).toContain('"\'+1"')
  await page.screenshot({ path: `../build/run-comparison-${process.env.ORBIT_E2E_NATIVE === '1' ? 'native' : 'vm'}.png` })
})

test('Pin and Rename use metadata CAS, lost responses recover, protected delete is explicit and usage survives deletion', async ({ page }) => {
  await login(page); const p = await setup(page); const first = await run(page, p); await run(page, p); await show(page, first)
  await modal(page).getByLabel('Run title', { exact: true }).fill('Local title'); expect((await annotate(page, p.id, first, { title: 'Other title' })).status()).toBe(200)
  await modal(page).getByRole('button', { name: 'Rename run', exact: true }).click(); await expect(modal(page).getByRole('alert')).toContainText('Run labels changed'); await expect(modal(page).getByLabel('Run title', { exact: true })).toHaveValue('Local title')
  await modal(page).getByRole('button', { name: 'Reload selected snapshot' }).click(); await expect(modal(page).getByLabel('Run title', { exact: true })).toHaveValue('Other title')
  let lost = false; await page.route('**/execution/runs/*/history', async route => { if (!lost) { lost = true; await route.fetch(); await route.abort('failed') } else await route.continue() })
  await modal(page).getByRole('button', { name: 'Pin run', exact: true }).click(); await expect(modal(page).getByRole('button', { name: 'Unpin run', exact: true })).toBeVisible(); expect((await snapshot(page, p.id, first)).metadata.pinned).toBe(true)
  expect((await annotate(page, p.id, first, { operation: 'delete' })).status()).toBe(409)
  await modal(page).getByRole('button', { name: 'Unpin run', exact: true }).click(); await expect(modal(page).getByRole('button', { name: 'Pin run', exact: true })).toBeVisible()
  const spent = (await registry(page, p.id)).resources.spent_ms; await modal(page).getByRole('button', { name: 'Delete run…' }).click(); expect((await snapshot(page, p.id, first)).snapshot).toBeTruthy(); await modal(page).getByRole('button', { name: 'Confirm delete run' }).click(); await expect(modal(page)).toContainText('Run deleted')
  expect((await request(page, base(p.id) + `/execution/runs/${first}/snapshot`)).status()).toBe(404); expect((await registry(page, p.id)).resources.spent_ms).toBe(spent)
})

test('restore reviews exact scalar scopes, excludes file inputs, preserves defaults and detects a stale review', async ({ page }) => {
  await login(page); const p = await setup(page); const first = await run(page, p); await apply(page, p.id, { exact: '9223372036854775807' }); await apply(page, p.id, { gain: '8' }, '1'); await show(page, first)
  await modal(page).getByRole('button', { name: 'Review scalar restore' }).click(); await expect(modal(page)).toContainText('may trigger Watch'); await expect(modal(page).getByRole('row').filter({ hasText: 'dataset' })).toHaveCount(0)
  await apply(page, p.id, { exact: '7' }); await expect(modal(page).getByRole('alert')).toContainText('Parameters or the notebook changed'); await expect(modal(page).getByRole('button', { name: 'Apply saved scalar parameters' })).toBeDisabled()
  await modal(page).getByRole('button', { name: 'Reset restore review' }).click(); await modal(page).getByRole('button', { name: 'Review scalar restore' }).click(); await modal(page).getByRole('button', { name: 'Apply saved scalar parameters' }).click(); await expect.poll(async () => (await inputs(page, p.id)).values.exact).toBe('9223372036854775806')
  await modal(page).getByLabel('Parameter scope', { exact: true }).selectOption('1'); await modal(page).getByRole('button', { name: 'Review scalar restore' }).click(); await modal(page).getByRole('button', { name: 'Apply saved scalar parameters' }).click(); await expect.poll(async () => (await inputs(page, p.id, '1')).values.gain).toBe('2')
  expect((await json(page, base(p.id) + '/execution/history')).runs.every((run: any) => run.id === first || run.action === 'inputs')).toBe(true); expect((await json(page, base(p.id) + '/notebook')).notebook.document).toContain('9223372036854775806')
})

test('restoring a project scope triggers Watch only after explicit Apply', async ({ page }) => {
  await login(page); const p = await setup(page, 'watch'); const first = await run(page, p); await apply(page, p.id, { exact: '9' }); await expect.poll(async () => (await json(page, base(p.id) + '/execution/history')).runs.length).toBe(2); await expect.poll(async () => (await registry(page, p.id)).runs.at(-1)?.state).toBe('succeeded')
  await show(page, first); await modal(page).getByRole('button', { name: 'Review scalar restore' }).click(); expect((await json(page, base(p.id) + '/execution/history')).runs).toHaveLength(2)
  await modal(page).getByRole('button', { name: 'Apply saved scalar parameters' }).click(); await expect.poll(async () => (await json(page, base(p.id) + '/execution/history')).runs.length).toBe(3)
  await expect.poll(async () => (await registry(page, p.id)).runs.at(-1)?.state).toBe('succeeded')
})

test('pinned snapshots survive retention, labels obey storage, current presentation and foreign projects stay protected', async ({ page }) => {
  await login(page); const p = await setup(page); const first = await run(page, p); expect((await annotate(page, p.id, first, { title: 'Pinned', pinned: true })).status()).toBe(200); const middle = await run(page, p); const last = await run(page, p)
  const core = await cid(p); await rpc('policy.configure', { scope: 'project', id: core, limits: { run_count: 2 } }); await rpc('storage.collect', { project_id: core, command_id: crypto.randomUUID() })
  const ids = (await json(page, base(p.id) + '/execution/history')).runs.map((item: any) => item.id); expect(ids).toContain(first); expect(ids).toContain(last); expect(ids).not.toContain(middle)
  expect((await annotate(page, p.id, last, { operation: 'delete' })).status()).toBe(409)
  await rpc('policy.configure', { scope: 'project', id: core, limits: { project_bytes: 1 } }); try { expect((await annotate(page, p.id, first, { title: 'Over quota', pinned: true })).status()).toBe(507); expect((await annotate(page, p.id, first, { title: 'Pinned', pinned: false })).status()).toBe(200); expect((await annotate(page, p.id, first, { operation: 'delete' })).status()).toBe(200) } finally { await rpc('policy.configure', { scope: 'project', id: core, limits: {} }) }
  const foreign = await setup(page); expect((await request(page, base(foreign.id) + `/execution/runs/${first}/snapshot`)).status()).toBe(404)
  const own = await run(page, foreign); const metadata = (await snapshot(page, foreign.id, own)).metadata
  expect((await request(page, base(foreign.id) + `/execution/runs/${first}/history`, 'POST', { command_id: crypto.randomUUID(), base_version: metadata.version, operation: 'update', title: 'forged', pinned: false })).status()).toBe(404)
})

test('viewer can inspect and export but cannot mutate or restore; revocation removes snapshot contents', async ({ page, browser, baseURL }) => {
  await login(page); const p = await setup(page); const first = await run(page, p); const context = await browser.newContext({ baseURL }); const viewer = await context.newPage(); await login(viewer, 'Bob'); const account = (await json(viewer, '/api/session')).account.id
  expect((await request(page, base(p.id) + '/memberships', 'POST', { account_id: account, role: 'viewer' })).status()).toBe(200); await viewer.goto(`/projects/${p.id}`); await show(viewer, first)
  await expect(modal(viewer).getByRole('button', { name: 'Pin run', exact: true })).toHaveCount(0); await expect(modal(viewer).getByRole('button', { name: 'Review scalar restore' })).toBeDisabled(); expect((await annotate(viewer, p.id, first, { title: 'forged' })).status()).toBe(403)
  await request(page, base(p.id) + '/memberships/' + account, 'DELETE'); await expect(modal(viewer)).not.toBeVisible({ timeout: 10000 }); await context.close()
})

test('pin limit is enforced by Core and active snapshots are never presented as immutable', async ({ page }) => {
  test.setTimeout(60000)
  await login(page); const p = await setup(page)
  for (let i = 0; i < 11; i++) { const id = await run(page, p); const response = await annotate(page, p.id, id, { title: `Experiment ${i}`, pinned: true }); expect(response.status(), await response.text()).toBe(i < 10 ? 200 : 409) }
  const head = (await json(page, base(p.id) + '/notebook')).notebook; const document = JSON.parse(head.document); document.inputs[0].default = 5; document.sheets[0].cells[0].source = 'import task\ntask.sleep(60000)\n42\n'
  const saved = await request(page, base(p.id) + '/notebook', 'PUT', { command_id: crypto.randomUUID(), base_revision: head.revision, document: JSON.stringify(document), changes: {} }); expect(saved.status(), await saved.text()).toBe(200)
  const response = await request(page, base(p.id) + '/execution/runs', 'POST', { command_id: crypto.randomUUID(), revision: (await saved.json()).notebook.revision, sheet_id: 'main', cell_id: '1', action: 'run' }); expect(response.status()).toBe(200); const active = (await response.json()).run
  expect((await request(page, base(p.id) + `/execution/runs/${active.id}/snapshot`)).status()).toBe(409)
  expect((await request(page, base(p.id) + `/execution/runs/${active.id}/stop`, 'POST', { command_id: crypto.randomUUID(), runtime_epoch: active.runtime_epoch, force: true })).status()).toBe(200)
  await expect.poll(async () => (await registry(page, p.id)).runs.find((run: any) => run.id === active.id)?.state).toBe('force-stopped')
  const stopped = (await snapshot(page, p.id, active.id)).snapshot; expect(stopped.run.state).toBe('force-stopped'); expect(stopped.sources[0].source).toContain('task.sleep(60000)')
})

test('removed sheets keep immutable snapshots available through All retained sheets', async ({ page }) => {
  await login(page); const p = await setup(page); const first = await run(page, p); const original = (await snapshot(page, p.id, first)).snapshot
  const head = (await json(page, base(p.id) + '/notebook')).notebook; const document = JSON.parse(head.document)
  document.sheets = [{ id: 'next', title: 'Replacement', cells: [{ id: '2', kind: 'code', mode: 'manual', source: '42\n' }] }]; document.active_sheet = 'next'; document.boards = []; document.inputs = []
  const saved = await request(page, base(p.id) + '/notebook', 'PUT', { command_id: crypto.randomUUID(), base_revision: head.revision, document: JSON.stringify(document), changes: {} }); expect(saved.status(), await saved.text()).toBe(200)
  expect((await snapshot(page, p.id, first)).snapshot).toEqual(original)
  await page.reload(); await page.locator('details.run-history > summary').click(); await page.getByRole('button', { name: 'Snapshots and experiments…', exact: true }).click()
  await modal(page).getByRole('combobox', { name: 'Sheet', exact: true }).selectOption(''); await modal(page).getByLabel('Snapshot run', { exact: true }).selectOption(first)
  await expect(modal(page)).toContainText('unavailable or outside its scope'); await expect(modal(page).getByRole('button', { name: 'Review scalar restore' })).toBeDisabled()
  await modal(page).getByText('Inspect sources and environment', { exact: true }).click(); await expect(modal(page)).toContainText('notebook.input("exact")')
})
