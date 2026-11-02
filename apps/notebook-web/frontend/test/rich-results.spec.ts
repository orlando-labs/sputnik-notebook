import { expect, test, type Page } from '@playwright/test'
import net from 'node:net'
import { readFile, writeFile, unlink, symlink, mkdir } from 'node:fs/promises'

async function rpc(method: string, params = {}): Promise<any> {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(`${process.env.NOTEBOOK_WEB_TEST_CORE_ROOT}/agent.sock`)
    let reply = ''
    socket.setTimeout(30_000, () => socket.destroy(new Error('Core test timeout')))
    socket.on('error', reject)
    socket.on('connect', () => socket.write(JSON.stringify({ method, params }) + '\n'))
    socket.on('data', chunk => {
      reply += chunk
      if (!reply.includes('\n')) return
      socket.end()
      const response = JSON.parse(reply.split('\n')[0]!)
      if (response.status !== 200) reject(new Error(JSON.stringify(response)))
      else resolve(response.data)
    })
  })
}
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
const execution = (id: string) => `/api/projects/${id}/execution`
async function book(page: Page, source: string, modules: ('ui' | 'plot')[] = [], cellUI?: unknown) {
  const created = await request(page, '/api/projects', 'POST', { title: `Rich results ${crypto.randomUUID()}` })
  expect(created.status()).toBe(201)
  const project = (await created.json()).project
  const initial = (await (await request(page, `/api/projects/${project.id}/notebook`, 'POST', {})).json()).notebook
  const document = JSON.parse(initial.document)
  document.sheets[0].cells = [{ id: '1', kind: 'code', source, mode: 'manual' }]
  if (cellUI) { document.version = 4; document.inputs ||= []; document.boards ||= []; document.dependencies ||= []; document.sheets[0].cells[0].cell_ui = cellUI }
  const internal = (await rpc('project.list')).projects.find((value: any) => value.title === project.title)
  const files: Record<string, string> = {}
  // Seed ordinary bundled modules via the privileged fixture, preserving the
  // canonical package source. The browser has no file-map or package authority.
  for (const name of modules) {
    if (name === 'ui') continue
    const original = await readFile('../../../../plot/src/plot.s', 'utf8')
    files[`modules/${name}.s`] = Buffer.from(original).toString('base64')
    document.modules.push({ id: name, path: `modules/${name}.s` })
  }
  const saved = await rpc('project.put', { project_id: internal.id, command_id: crypto.randomUUID(), base_revision: initial.revision, document: JSON.stringify(document), files })
  if (modules.includes('ui')) {
    // Install the canonical table implementation in this disposable project's
    // package home. Qualified package names are not bundled module IDs. The dedicated audio suite covers audio; this fixture includes only
    // DataTableView's source.
    const directory = `${process.env.NOTEBOOK_WEB_TEST_CORE_ROOT}/table-package`
    await mkdir(directory, { recursive: true })
    const original = await readFile('../../../../sputnik-lang/packages/notebook_ui/src/notebook_ui.s', 'utf8')
    await writeFile(`${directory}/table.s`, 'package notebook.ui\nexport DataTableView\n\n' + original.slice(original.indexOf('class DataTableView:'), original.indexOf('# Publish numeric samples')))
    await writeFile(`${directory}/sputnik.build.yaml`, JSON.stringify({ schema: 'sputnik.build.v1', name: 'notebook-ui', version: '0.0.0', root: 'notebook.ui', modules: [{ name: 'notebook.ui', path: 'table.s' }] }))
    const job = await rpc('dependency.change', { project_id: internal.id, command_id: crypto.randomUUID(), action: 'install_sputnik', source: directory, local_source: true })
    let status: any
    await expect.poll(async () => { status = await rpc('dependency.get', { project_id: internal.id, operation_id: job.id }); return status.state }, { timeout: 20_000 }).toMatch(/^(succeeded|failed)$/)
    expect(status.state, JSON.stringify(status)).toBe('succeeded')
  }
  return { project, revision: saved.revision, coreId: internal.id }
}
async function run(page: Page, id: string) {
  await page.goto(`/projects/${id}`)
  await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
  await expect.poll(async () => (await (await request(page, execution(id))).json()).runs.at(-1)?.state, { timeout: 15_000 }).toMatch(/^(succeeded|failed)$/)
  const registry = await (await request(page, execution(id))).json()
  const response = await request(page, `${execution(id)}/runs/${registry.runs.at(-1).id}`)
  expect(response.status()).toBe(200)
  const result = (await response.json()).run
  expect(result.rich_error).toBe('')
  return result
}
async function save(page: Page, source: string) {
  await page.getByRole('textbox', { name: 'Code cell 1', exact: true }).fill(source)
  await page.getByRole('button', { name: 'Save notebook', exact: true }).click()
  await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved')
}
async function release(page: Page, id: string) {
  const registry = await (await request(page, execution(id))).json()
  for (const run of registry.runs.filter((value: any) => !['succeeded', 'failed', 'cancelled', 'force-stopped', 'interrupted'].includes(value.state))) {
    expect((await request(page, `${execution(id)}/runs/${run.id}/stop`, 'POST', { command_id: crypto.randomUUID(), runtime_epoch: run.runtime_epoch, force: true })).status()).toBe(200)
    await expect.poll(async () => (await (await request(page, `${execution(id)}/runs/${run.id}`)).json()).run.state).toMatch(/^(succeeded|failed|cancelled|force-stopped|interrupted)$/)
  }
  for (const runtime of registry.runtimes.filter((value: any) => !registry.reset_epochs.includes(value.runtime_epoch))) {
    const response = await request(page, `${execution(id)}/restart`, 'POST', { command_id: crypto.randomUUID(), sheet_id: runtime.sheet_id, runtime_epoch: runtime.runtime_epoch })
    expect(response.status()).toBe(200)
  }
}
async function downloadText(page: Page, name: string) {
  const waiting = page.waitForEvent('download')
  await page.getByRole('button', { name, exact: true }).click()
  const download = await waiting
  const file = await download.path()
  expect(file).not.toBeNull()
  return { bytes: await readFile(file!), name: download.suggestedFilename() }
}

test('implicit table preserves int64, typed sorting, filter, selection and exports without execution', async ({ page }) => {
  await login(page)
  const { project } = await book(page, 'from notebook.ui import Stopwatch\nStopwatch.measure("native only"): 42\n[{name: "<script>bad()</script>|α", count: 9223372036854775806, score: 0.5, enabled: true, missing: null}, {name: "second", count: 9223372036854775805, score: 2.0, enabled: false, missing: null}]\n')
  try {
    const result = await run(page, project.id)
    expect(result.state).toBe('succeeded')
    const table = page.getByTestId('rich-table')
    await expect(table).toContainText('9223372036854775806')
    await expect(table).toContainText('<script>bad()</script>|α')
    expect(await table.locator('script').count()).toBe(0)
    const values = result.cells[0].table.rows[0].values
    expect(values.find((value: any) => value.kind === 'integer').text).toBe('9223372036854775806')
    expect(values.find((value: any) => value.kind === 'boolean').text).toBe('true')
    expect(values.find((value: any) => value.kind === 'null').text).toBe('')
    await table.getByRole('button', { name: 'Sort by count', exact: true }).click()
    await expect(table.locator('tbody tr').first()).toContainText('9223372036854775805')
    await table.getByRole('button', { name: 'Sort by count', exact: true }).click()
    await expect(table.locator('tbody tr').first()).toContainText('9223372036854775806')
    await table.getByRole('searchbox', { name: 'Filter rows' }).fill('α')
    await expect(table.locator('tbody tr')).toHaveCount(1)
    await table.locator('tbody tr').first().focus()
    await page.keyboard.press('Enter')
    await expect(table.locator('tbody tr').first()).toHaveAttribute('aria-selected', 'true')
    await table.getByLabel('Table actions').click()
    const csv = await downloadText(page, 'Save CSV…')
    expect(csv.name).toBe('table.csv')
    expect(csv.bytes.toString()).toContain('"9223372036854775806"')
    expect(csv.bytes.toString()).not.toContain('second')
    const markdown = await downloadText(page, 'Save Markdown…')
    expect(markdown.bytes.toString()).toContain('&lt;script&gt;bad()&lt;/script&gt;\\|α')
    await table.getByRole('searchbox', { name: 'Filter rows' }).fill('no match')
    await expect(table).toContainText('No matching rows')
    await table.getByRole('searchbox', { name: 'Filter rows' }).fill('')
    await table.getByLabel('Table actions').click()
    for (const colorScheme of ['light', 'dark'] as const) {
      await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' })
      for (const width of [1280, 375, 320]) {
        await page.setViewportSize({ width, height: 900 })
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
        if (width !== 320) await table.screenshot({ path: `../build/rich-table-${colorScheme}-${width}.png` })
      }
    }
    expect((await (await request(page, execution(project.id))).json()).runs).toHaveLength(1)
  } finally { await release(page, project.id) }
})

test('table paging, sorting and downloads use every retained row', async ({ page }) => {
  await login(page)
  const { project } = await book(page, '(1..125).map |i|: [i, i * 2]\n')
  try {
    expect((await run(page, project.id)).state).toBe('succeeded')
    const table = page.getByTestId('rich-table')
    await expect(table.locator('tbody tr')).toHaveCount(100)
    await table.getByRole('button', { name: 'Next rows', exact: true }).click()
    await expect(table.locator('tbody tr')).toHaveCount(25)
    await expect(table.locator('tbody tr').last()).toContainText('125')
    await table.locator('thead button').first().click()
    await table.locator('thead button').first().click()
    await expect(table.locator('tbody tr').first()).toContainText('125')
    await table.getByLabel('Table actions').click()
    const csv = await downloadText(page, 'Save CSV…')
    expect(csv.bytes.toString().trimEnd().split('\r\n')).toHaveLength(126)
    await table.getByRole('searchbox', { name: 'Filter rows' }).fill('125')
    await expect(table.locator('tbody tr')).toHaveCount(1)
    expect((await (await request(page, execution(project.id))).json()).runs).toHaveLength(1)
  } finally { await release(page, project.id) }
})

test('published tables retain order, replace by ID, update live, preserve failure and clear on success', async ({ page }) => {
  await login(page)
  const source = 'from notebook.ui import DataTableView, Stopwatch\nimport task\nStopwatch.measure("table"): 42\nnotebook.show(DataTableView([], columns: ["Empty"]), caption: "Schema retained", live: false, order: 1)\nnotebook.show(DataTableView([[1]], columns: ["step"]), id: "live", caption: "Live table", order: 2)\ntask.sleep(1500)\nnotebook.show(DataTableView([[2]], columns: ["step"]), id: "live", caption: "Live table", order: 2)\ntask.sleep(1500)\n42\n'
  const { project } = await book(page, source, ['ui'])
  try {
    await page.goto(`/projects/${project.id}`)
    await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
    await expect.poll(async () => {
      const record = (await (await request(page, execution(project.id))).json()).runs.at(-1)
      if (record && ['failed', 'interrupted'].includes(record.state)) throw new Error(JSON.stringify(await rpc('run.get', { run_id: record.id })))
      return record?.state
    }, { timeout: 15_000 }).toMatch(/^(running|draining|succeeded)$/)
    const live = page.getByTestId('rich-table').filter({ hasText: 'Live table' })
    await expect(live.locator('tbody')).toContainText('1')
    await expect(live.locator('tbody')).toContainText('2')
    await expect(page.getByLabel('Cell result', { exact: true })).toHaveText('42')
    await expect(page.getByTestId('rich-table')).toHaveCount(2)
    await expect(page.getByTestId('rich-table').first()).toContainText('This table is empty')
    await save(page, 'from notebook.ui import DataTableView\nnotebook.show(DataTableView([[3]], columns: ["step"]))\n1 / 0\n')
    await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
    await expect(page.getByLabel('Cell error', { exact: true })).toContainText(/zero|Zero/)
    await expect(page.getByTestId('rich-table')).toHaveCount(2)
    await expect(page.locator('.rich-stale-note')).toContainText('last successful result')
    await expect(live.locator('tbody')).toContainText('2')
    await save(page, '42\n')
    await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
    await expect(page.getByTestId('rich-table')).toHaveCount(0)
    await expect(page.getByLabel('Cell result', { exact: true })).toHaveText('42')
  } finally { await release(page, project.id) }
})

test('real plot scene supports zoom, pan, reset and PNG export in responsive themes', async ({ page }) => {
  await login(page)
  const source = 'from plot import figure\np = figure(width: 640, height: 420).title("Training loss").axes(x_label: "Step", y_label: "Loss")\np = p.line([[0, 0], [1, 1], [2, 4], [3, 9], [4, 16]]).points([[1, 1], [3, 9]])\np = p.vline(2, label: "Checkpoint", dy: 8).annotate([2, 4], "visible")\nnotebook.show(p, id: "loss", caption: "Training figure", throttle_ms: 0)\n42\n'
  const { project } = await book(page, source, ['plot'])
  try {
    const result = await run(page, project.id)
    expect(result.state).toBe('succeeded')
    expect(result.cells[0].displays[0].plot_scene).toContain('"version":1')
    const plot = page.getByTestId('rich-plot')
    await expect(plot).toBeVisible()
    const canvas = plot.getByRole('img', { name: 'Training loss' })
    const original = await canvas.getAttribute('data-viewport')
    await plot.getByRole('button', { name: 'Zoom in', exact: true }).click()
    expect(await canvas.getAttribute('data-viewport')).not.toBe(original)
    await plot.getByRole('button', { name: 'Reset view', exact: true }).click()
    await expect(canvas).toHaveAttribute('data-viewport', original!)
    await canvas.scrollIntoViewIfNeeded()
    const box = (await canvas.boundingBox())!
    await page.mouse.move(box.x + box.width * .3, box.y + box.height * .3)
    await page.mouse.down(); await page.mouse.move(box.x + box.width * .7, box.y + box.height * .7); await page.mouse.up()
    const zoomed = await canvas.getAttribute('data-viewport')
    expect(zoomed).not.toBe(original)
    await page.keyboard.down('Shift')
    await page.mouse.move(box.x + box.width * .4, box.y + box.height * .4)
    await page.mouse.down(); await page.mouse.move(box.x + box.width * .5, box.y + box.height * .4); await page.mouse.up()
    await page.keyboard.up('Shift')
    expect(await canvas.getAttribute('data-viewport')).not.toBe(zoomed)
    await canvas.focus(); await page.keyboard.press('0')
    await expect(canvas).toHaveAttribute('data-viewport', original!)
    const png = await downloadText(page, 'Save PNG…')
    expect(png.bytes.subarray(0, 8).toString('hex')).toBe('89504e470d0a1a0a')
    expect(png.bytes.length).toBeGreaterThan(5000)
    for (const colorScheme of ['light', 'dark'] as const) {
      await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' })
      for (const width of [1280, 375, 320]) {
        await page.setViewportSize({ width, height: 900 })
        await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
        if (width !== 320) await plot.screenshot({ path: `../build/rich-plot-${colorScheme}-${width}.png` })
      }
    }
    await page.setViewportSize({ width: 1280, height: 900 })
    await page.emulateMedia({ colorScheme: 'light' })
    await page.route(`**${execution(project.id)}/runs/*`, async route => {
      const response = await route.fetch(), body = await response.json()
      if (body.run?.cells?.[0]?.displays?.[0]) body.run.cells[0].displays[0].plot_scene = '{"version":1,"layers":[{"commands":[[99,"https://invalid.example/"]]}]}'
      await route.fulfill({ response, json: body })
    })
    await page.reload()
    await expect(page.getByText('Interactive plot unavailable', { exact: false })).toBeVisible()
    await expect(page.getByLabel('Cell result', { exact: true })).toHaveText('42')
    expect((await (await request(page, execution(project.id))).json()).runs).toHaveLength(1)
  } finally { await release(page, project.id) }
})

test('raster image collections, downloads, read-only sharing and corrupt artifact fallback', async ({ page, browser, baseURL }) => {
  await login(page)
  const source = 'notebook.images("gallery", [{data: [255, 0, 0, 0, 255, 0], width: 2, height: 1, format: :rgb, caption: "First frame"}], caption: "Image collection")\nnotebook.images("gallery", [{data: [0, 0, 255, 255, 255, 0], width: 2, height: 1, format: :rgb, caption: "Second frame"}], append: true)\n42\n'
  const { project } = await book(page, source)
  const viewer = await browser.newContext({ baseURL })
  try {
    const result = await run(page, project.id)
    expect(result.state).toBe('succeeded')
    expect(result.cells[0].images[0].images).toHaveLength(2)
    const images = page.getByTestId('rich-images')
    await expect(images.getByRole('img')).toHaveAttribute('alt', 'First frame')
    await expect.poll(() => images.getByRole('img').evaluate((image: HTMLImageElement) => image.naturalWidth)).toBe(2)
    await images.getByRole('button', { name: 'Next image', exact: true }).click()
    await expect(images.getByRole('img')).toHaveAttribute('alt', 'Second frame')
    await expect(images.getByLabel('Image position')).toHaveText('2 / 2')
    const png = await downloadText(page, 'Save image…')
    expect(png.bytes.subarray(0, 8).toString('hex')).toBe('89504e470d0a1a0a')
    for (const colorScheme of ['light', 'dark'] as const) {
      await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' })
      for (const width of [1280, 375, 320]) {
        await page.setViewportSize({ width, height: 900 })
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
        if (width !== 320) await images.screenshot({ path: `../build/rich-images-${colorScheme}-${width}.png` })
      }
    }
    await page.setViewportSize({ width: 1280, height: 900 })
    await page.emulateMedia({ colorScheme: 'light' })
    const bob = await viewer.newPage()
    await login(bob, 'Bob')
    const bobId = (await (await request(bob, '/api/session')).json()).account.id
    expect((await request(bob, `${execution(project.id)}/runs/${result.id}`)).status()).toBe(404)
    await request(page, `/api/projects/${project.id}/memberships`, 'POST', { account_id: bobId, role: 'viewer' })
    await bob.goto(`/projects/${project.id}`)
    await expect(bob.getByTestId('rich-images').getByRole('img')).toBeVisible()
    await expect(bob.getByRole('button', { name: 'Run All', exact: true })).toHaveCount(0)
    const publicResult = (await (await request(bob, `${execution(project.id)}/runs/${result.id}`)).json()).run
    expect(JSON.stringify(publicResult)).not.toMatch(/presentation.*\.bin|execution_document|worker_pid|"runtime_id"|\/private\//)
    const trusted = await rpc('run.get', { run_id: result.id })
    const bytes = await readFile(trusted.presentation)
    try {
      await writeFile(trusted.presentation, Buffer.concat([bytes, Buffer.from('trailing')]))
      await page.reload()
      await expect(page.getByRole('alert')).toContainText('Rich results could not be loaded')
      await expect(page.getByLabel('Cell result', { exact: true })).toHaveText('42')
      await expect(page.getByTestId('rich-images')).toHaveCount(0)
      await unlink(trusted.presentation)
      const secret = `${process.env.NOTEBOOK_WEB_TEST_CORE_ROOT}/private-test-file`
      await writeFile(secret, 'private file must never be presented')
      await symlink(secret, trusted.presentation)
      const blocked = (await (await request(page, `${execution(project.id)}/runs/${result.id}`)).json()).run
      expect(blocked.rich_error).toContain('Rich results could not be loaded')
      expect(JSON.stringify(blocked)).not.toContain('private file must never be presented')
    } finally { await unlink(trusted.presentation); await writeFile(trusted.presentation, bytes) }
    await page.reload()
    await expect(page.getByTestId('rich-images').getByRole('img')).toBeVisible()
    await request(page, `/api/projects/${project.id}/memberships/${bobId}`, 'DELETE')
    expect((await request(bob, `${execution(project.id)}/runs/${result.id}`)).status()).toBe(404)
    expect((await (await request(page, execution(project.id))).json()).runs).toHaveLength(1)
  } finally { await viewer.close(); await release(page, project.id) }
})

test('live progress, stopwatch and chart survive reload, preserve zoom and retain run history', async ({ page }) => {
  await login(page)
  const source = 'from notebook.ui import Stopwatch\nimport task\nnotebook.progress("fraction", 0.00000000001, 0.00000000002, "Fine progress", false)\nnotebook.chart_point("loss", 0, -0.000000000123456789)\nStopwatch.measure("training"):\n  task.sleep(4000)\n  notebook.chart_point("loss", 1, 0.000000000234567891)\n  task.sleep(3000)\nnotebook.progress("fraction", 0.00000000002, 0.00000000002, "Fine progress", true)\n42\n'
  const cellUI = { inputs: [], pre: [{ id: 'audio', kind: 'audio', title: 'Authored audio', audio_id: 'training', future_setting: { exact: 'kept' } }], post: [{ id: 'waveform', kind: 'audio', title: 'Authored waveform', audio_id: 'training', show_waveform: false }] }
  const { project } = await book(page, source, [], cellUI)
  try {
    await page.goto(`/projects/${project.id}`)
    await expect(page.getByTestId('cell-display-component').filter({ hasText: 'Audio channel unavailable' })).toHaveCount(2)
    await expect(page.getByTestId('cell-display-component').first()).toContainText('Authored audio')
    await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
    const progress = page.getByTestId('runtime-progress'), timer = page.getByTestId('runtime-stopwatch'), chart = page.getByTestId('runtime-chart')
    await expect(progress).toContainText('Running')
    await expect(progress.getByRole('progressbar')).toHaveAttribute('value', '1e-11')
    await expect(timer).toContainText('Running')
    const registry = (await (await request(page, execution(project.id))).json())
    const runId = registry.runs.at(-1).id
    const initial = (await (await request(page, `${execution(project.id)}/runs/${runId}`)).json()).run
    expect(initial.live_cells[0].progress[0]).toMatchObject({ current: 1e-11, total: 2e-11, description: 'Fine progress', done: false })
    expect(initial.live_cells[0].charts[0].points[0]).toEqual([0, -0.000000000123456789])
    const posts: string[] = []
    page.on('request', value => { if (value.method() === 'POST' && value.url().endsWith('/execution/runs')) posts.push(value.url()) })
    await page.reload()
    await expect(chart.getByRole('img')).toBeVisible()
    await chart.getByRole('button', { name: 'Zoom in', exact: true }).click()
    const viewport = await chart.getByRole('img').getAttribute('data-viewport')
    await expect(chart).toContainText('2 retained / 2 total samples')
    await expect(chart.getByRole('img')).toHaveAttribute('data-viewport', viewport!)
    await expect(progress).toContainText('Finished')
    await expect(timer).toContainText('Finished')
    await expect(page.getByLabel('Cell result', { exact: true })).toHaveText('42')
    const result = (await (await request(page, `${execution(project.id)}/runs/${runId}`)).json()).run
    expect(result.state).toBe('succeeded'); expect(result.rich_error).toBe('')
    expect(typeof result.cells[0].elapsed_ms).toBe('string')
    expect(typeof result.cells[0].stopwatches[0].elapsed_ms).toBe('string')
    expect(result.cells[0].charts[0].total_points).toBe('2')
    expect(result.cells[0].charts[0].points).toEqual([[0, -0.000000000123456789], [1, 0.000000000234567891]])
    expect(posts).toEqual([])
    const csv = await downloadText(page, 'Export samples CSV…')
    expect(csv.bytes.toString()).toBe('X,Y\r\n0,-1.23456789e-10\r\n1,2.34567891e-10\r\n')
    await chart.getByRole('button', { name: 'Reset view', exact: true }).click()
    for (const colorScheme of ['light', 'dark'] as const) {
      await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' })
      for (const width of [1280, 375, 320]) {
        await page.setViewportSize({ width, height: 900 })
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
        if (width !== 320) await page.getByTestId('runtime-telemetry').screenshot({ path: `../build/runtime-telemetry-${colorScheme}-${width}.png` })
      }
    }
    await save(page, '42\n')
    const saved = (await (await request(page, `/api/projects/${project.id}/notebook`)).json()).notebook
    expect(JSON.parse(saved.document).sheets[0].cells[0].cell_ui).toEqual(cellUI)
    await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
    await expect(chart).toHaveCount(0)
    await expect(progress).toHaveCount(0)
    await page.locator('.run-history > summary').click()
    await page.getByRole('button', { name: `View run ${runId}`, exact: true }).click()
    await expect(chart).toContainText('2 retained / 2 total samples')
    await expect(page.getByTestId('runtime-telemetry')).toContainText('Previous measurements')
  } finally { await release(page, project.id) }
})

test('Stop preserves partial progress and never completes an unfinished bar', async ({ page }) => {
  await login(page)
  const { project } = await book(page, 'import task\nnotebook.progress("work", 3, 10, "Partial work", false)\nnotebook.chart_point("partial", 1, -2)\ntask.sleep(60000)\n42\n')
  try {
    await page.goto(`/projects/${project.id}`)
    await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
    const progress = page.getByTestId('runtime-progress')
    await expect(progress).toContainText('Running')
    await page.getByRole('button', { name: 'Stop', exact: true }).click()
    await expect(progress).toContainText('Stopped')
    await expect(progress.getByRole('progressbar')).toHaveAttribute('value', '3')
    await expect(progress).toContainText('3 / 10 · 30%')
    const run = (await (await request(page, execution(project.id))).json()).runs.at(-1)
    const result = (await (await request(page, `${execution(project.id)}/runs/${run.id}`)).json()).run
    expect(result.state).toBe('cancelled')
    expect(result.cells[0].progress[0]).toMatchObject({ current: 3, total: 10, done: false })
    await page.reload()
    await expect(progress).toContainText('Stopped')
    await expect(page.getByTestId('runtime-chart')).toContainText('1 retained / 1 total samples')
    expect((await (await request(page, execution(project.id))).json()).runs).toHaveLength(1)
  } finally { await release(page, project.id) }
})

test('large chart exports every retained sample and is readable only through the current ACL', async ({ page, browser, baseURL }) => {
  await login(page)
  const { project } = await book(page, '5000.times |i|:\n  value = if i == 3210 then 1000000 else i % 7\n  notebook.chart_point("samples", i, value)\n42\n')
  const viewer = await browser.newContext({ baseURL })
  try {
    const result = await run(page, project.id)
    expect(result.state).toBe('succeeded')
    expect(result.cells[0].charts[0].points).toHaveLength(5000)
    const chart = page.getByTestId('runtime-chart')
    await expect(chart).toContainText('5000 retained / 5000 total samples')
    await expect(chart).toContainText('chart sampled')
    const csv = (await downloadText(page, 'Export samples CSV…')).bytes.toString().split('\r\n')
    expect(csv).toHaveLength(5002); expect(csv[3211]).toBe('3210,1000000'); expect(csv[5000]).toBe('4999,1')
    const bob = await viewer.newPage()
    await login(bob, 'Bob')
    const bobId = (await (await request(bob, '/api/session')).json()).account.id
    expect((await request(bob, `${execution(project.id)}/runs/${result.id}`)).status()).toBe(404)
    await request(page, `/api/projects/${project.id}/memberships`, 'POST', { account_id: bobId, role: 'viewer' })
    await bob.goto(`/projects/${project.id}`)
    await expect(bob.getByTestId('runtime-chart')).toContainText('5000 retained / 5000 total samples')
    await expect(bob.getByRole('button', { name: 'Run All', exact: true })).toHaveCount(0)
    const publicResult = (await (await request(bob, `${execution(project.id)}/runs/${result.id}`)).json()).run
    expect(JSON.stringify(publicResult)).not.toMatch(/execution_document|worker_pid|"runtime_id"|\/private\//)
    await request(page, `/api/projects/${project.id}/memberships/${bobId}`, 'DELETE')
    expect((await request(bob, `${execution(project.id)}/runs/${result.id}`)).status()).toBe(404)
    await expect(bob.getByTestId('runtime-chart')).toHaveCount(0)
  } finally { await viewer.close(); await release(page, project.id) }
})

test('authored cell displays bind exact values and named outputs without automatic duplicates', async ({ page }) => {
  await login(page)
  const cellUI = { inputs: [], pre: [
    { id: 'exact', kind: 'metric', title: 'Exact count', binding: 'exact' },
    { id: 'score', kind: 'metric', title: 'Accuracy', binding: 'score', p1: { percentage: true, precision: 1, target: 0.8, baseline: 0.8, improvement: 'higher' } },
  ], post: [
    { id: 'table', kind: 'table', title: 'Chosen table', table_id: 'named' },
    { id: 'image', kind: 'image', title: 'Preview', image_id: 'hero', image_mode: 'fill', image_allow_save: false, caption: 'Authored caption' },
    { id: 'plot', kind: 'live_chart', title: 'Training loss', chart_id: 'loss', x_label: 'Epoch', y_label: 'Loss', stroke: '#4c739e', x_min: 0, x_max: 2, y_min: 0, y_max: 2 },
    { id: 'missing', kind: 'metric', title: 'Missing value', binding: 'missing' },
    { id: 'text', kind: 'metric', title: 'Non-numeric value', binding: 'label' },
  ] }
  const source = 'from notebook.ui import DataTableView\nexact = 9223372036854775807\nscore = 0.875\nlabel = "private nonnumeric text"\nunbound = 123456789\nnotebook.show(DataTableView([[1]], columns: ["Count"]), id: "named", caption: "Named published table")\nnotebook.show(DataTableView([[2]], columns: ["Count"]), id: "other", caption: "Other published table")\nnotebook.images("hero", [{data: [255, 0, 0, 0, 255, 0], width: 2, height: 1, format: :rgb, caption: "Frame"}])\nnotebook.chart_point("loss", 0, 1)\nnotebook.chart_point("unclaimed", 0, 99)\n42\n'
  const { project } = await book(page, source, ['ui'], cellUI)
  const component = (id: string) => page.locator(`[data-component-id="${id}"]`)
  try {
    await page.goto(`/projects/${project.id}`)
    await expect(component('exact')).toContainText('Unavailable')
    const result = await run(page, project.id)
    expect(result.state).toBe('succeeded')
    await expect(component('exact').getByRole('status')).toHaveText('9223372036854775807')
    await expect(component('score')).toContainText('87.5%')
    await expect(component('score')).toContainText('Target: 80.0%')
    await expect(component('score')).toContainText('Δ +7.5%')
    await expect(component('missing')).toContainText('Unavailable')
    await expect(component('text')).toContainText('Unavailable')
    expect(result.cells[0].metrics.map((item: any) => item.name).sort()).toEqual(['exact', 'label', 'score'])
    expect(result.cells[0].metrics.find((item: any) => item.name === 'label').value).toBeNull()
    expect(JSON.stringify(result.cells[0].metrics)).not.toMatch(/unbound|private nonnumeric text/)
    await expect(page.getByTestId('rich-table')).toHaveCount(2)
    await expect(component('table')).toContainText('Named published table')
    await expect(page.getByTestId('rich-images')).toHaveCount(1)
    await expect(component('image').getByRole('img')).toHaveAttribute('alt', 'Frame')
    await expect(component('image').getByRole('button', { name: 'Save image…' })).toHaveCount(0)
    await expect(component('plot').getByRole('img')).toHaveAttribute('data-viewport', '[0,0,2,2]')
    await expect(page.getByTestId('runtime-chart')).toHaveCount(1)
    await expect(page.getByTestId('runtime-chart')).toHaveAttribute('data-channel', 'unclaimed')
    const before = (await (await request(page, `/api/projects/${project.id}/notebook`)).json()).notebook
    const positions = await page.evaluate(() => ({ pre: document.querySelector('[data-component-id="exact"]')!.getBoundingClientRect().top, source: document.querySelector('#cell-source-1')!.getBoundingClientRect().top, post: document.querySelector('[data-component-id="table"]')!.getBoundingClientRect().top }))
    expect(positions.pre).toBeLessThan(positions.source); expect(positions.post).toBeGreaterThan(positions.source)
    await page.getByRole('button', { name: 'Collapse source for cell 1' }).click()
    await expect(page.getByRole('textbox', { name: 'Code cell 1', exact: true })).toBeHidden()
    await expect(component('exact')).toBeVisible(); await expect(component('table')).toBeVisible()
    expect((await (await request(page, `/api/projects/${project.id}/notebook`)).json()).notebook).toEqual(before)
    expect((await (await request(page, execution(project.id))).json()).runs).toHaveLength(1)
    for (const colorScheme of ['light', 'dark'] as const) {
      await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' })
      for (const width of [1280, 375, 320]) {
        await page.setViewportSize({ width, height: 900 })
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
        if (width !== 320) await page.getByTestId('notebook-cell').screenshot({ path: `../build/cell-displays-${colorScheme}-${width}.png` })
      }
    }
    await page.getByRole('button', { name: 'Expand source for cell 1' }).click()
    await save(page, 'missing_name()\n')
    expect((await run(page, project.id)).state).toBe('failed')
    await expect(component('exact')).toContainText(/Previous value|Unavailable/)
    await expect(component('table')).toContainText('Previous data')
    await page.locator('.run-history > summary').click()
    await page.getByRole('button', { name: `View run ${result.id}`, exact: true }).click()
    await expect(component('exact').getByRole('status')).toHaveText('9223372036854775807')
    await expect(component('exact')).toContainText('Previous value')
  } finally { await release(page, project.id) }
})

test('authored display settings edit an inert draft and preserve extension fields', async ({ page }) => {
  await login(page)
  const original = { inputs: [], pre: [], post: [{ id: 'metric', kind: 'metric', title: 'Value', binding: 'answer', future_component: { kept: true }, p1: { unit: 'items', future_setting: ['keep'] } }] }
  const { project } = await book(page, 'answer = 42\nanswer\n', [], original)
  try {
    await page.goto(`/projects/${project.id}`)
    await page.getByRole('button', { name: 'Components for cell 1' }).click()
    const dialog = page.getByRole('dialog', { name: 'Cell Components & Parameters' })
    await dialog.getByLabel('Metric unit', { exact: true }).fill('discarded')
    await dialog.getByRole('button', { name: 'Cancel', exact: true }).click()
    await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved')
    await page.getByRole('button', { name: 'Components for cell 1' }).click()
    await expect(dialog.getByLabel('Metric unit', { exact: true })).toHaveValue('items')
    await dialog.getByLabel('Metric unit', { exact: true }).fill('samples')
    await dialog.getByLabel('Metric target', { exact: true }).fill('100000000000000000000')
    await dialog.getByRole('button', { name: 'Add Live Chart', exact: true }).click()
    await dialog.getByLabel('Chart X minimum', { exact: true }).fill('2')
    await dialog.getByLabel('Chart X maximum', { exact: true }).fill('1')
    await dialog.getByRole('button', { name: 'Update notebook draft' }).click()
    await expect(dialog.getByRole('alert')).toContainText('maximum must exceed')
    await dialog.getByLabel('Chart X maximum', { exact: true }).fill('10')
    await dialog.getByRole('button', { name: 'Add series', exact: true }).click()
    await dialog.getByLabel('Series 1 channel', { exact: true }).fill('loss')
    await dialog.getByLabel('Series 1 title', { exact: true }).fill('Loss')
    await dialog.getByRole('button', { name: 'Add Table', exact: true }).click()
    await dialog.getByLabel('Table ID', { exact: true }).fill('measurements')
    await dialog.getByRole('button', { name: 'Add Image', exact: true }).click()
    await dialog.getByLabel('Image sizing', { exact: true }).selectOption('auto-height')
    await dialog.getByLabel('Allow image save', { exact: true }).uncheck()
    for (const colorScheme of ['light', 'dark'] as const) {
      await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' })
      for (const width of [1280, 375, 320]) {
        await page.setViewportSize({ width, height: 900 })
        expect(await dialog.evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true)
        if (width !== 320) await dialog.screenshot({ path: `../build/cell-display-settings-${colorScheme}-${width}.png` })
      }
    }
    await page.setViewportSize({ width: 1280, height: 900 })
    await dialog.getByRole('button', { name: 'Update notebook draft' }).click()
    await expect(dialog).not.toBeVisible()
    await expect(page.getByTestId('notebook-save-status')).toHaveText('Unsaved changes')
    expect((await (await request(page, execution(project.id))).json()).runs).toEqual([])
    await page.getByRole('button', { name: 'Save notebook', exact: true }).click()
    await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved')
    const stored = (await (await request(page, `/api/projects/${project.id}/notebook`)).json()).notebook
    const ui = JSON.parse(stored.document).sheets[0].cells[0].cell_ui
    expect(ui.inputs).toEqual([]); expect(ui.pre).toEqual([])
    expect(ui.post.map((value: any) => value.kind)).toEqual(['metric', 'live_chart', 'table', 'image'])
    expect(ui.post[0].future_component).toEqual({ kept: true }); expect(ui.post[0].p1.future_setting).toEqual(['keep']); expect(ui.post[0].p1.unit).toBe('samples')
    expect(ui.post[0].p1.target).toBe(1e20)
    expect(ui.post[1].p1.series[0].id).toBe('loss'); expect(ui.post[2].table_id).toBe('measurements')
    expect(ui.post[3].image_mode).toBe('auto-height'); expect(ui.post[3].image_allow_save).toBe(false)
    expect((await (await request(page, execution(project.id))).json()).runs).toEqual([])
    await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
    await expect(page.getByLabel('Value value', { exact: true })).toHaveText('42 samples')
    await page.reload()
    await expect(page.getByLabel('Value value', { exact: true })).toHaveText('42 samples')
  } finally { await release(page, project.id) }
})

test('authored multi-series charts update live, toggle, export and reconnect without replay', async ({ page }) => {
  await login(page)
  const cellUI = { inputs: [], pre: [], post: [{ id: 'combined', kind: 'live_chart', title: 'Training', x_label: 'Epoch', y_label: 'Value', x_min: 0, x_max: 2, y_min: 0, y_max: 10, p1: { future: true, series: [{ id: 'loss', title: 'Loss', stroke: '#86505f', future: 'keep' }, { id: 'accuracy', title: 'Accuracy', stroke: '#4c739e' }] } }] }
  const { project } = await book(page, 'import task\nnotebook.chart_point("loss", 0, 9)\nnotebook.chart_point("accuracy", 0, 1)\ntask.sleep(3500)\nnotebook.chart_point("loss", 1, 4)\nnotebook.chart_point("accuracy", 1, 8)\ntask.sleep(2000)\n42\n', [], cellUI)
  try {
    await page.goto(`/projects/${project.id}`)
    await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
    const chart = page.getByTestId('authored-chart')
    await expect(chart.getByRole('img')).toBeVisible()
    await expect(page.getByTestId('runtime-chart')).toHaveCount(0)
    await chart.getByRole('button', { name: 'Toggle series Accuracy' }).click()
    await expect(chart.getByRole('button', { name: 'Toggle series Accuracy' })).toHaveAttribute('aria-pressed', 'false')
    await chart.getByRole('button', { name: 'Zoom in', exact: true }).click()
    const viewport = await chart.getByRole('img').getAttribute('data-viewport')
    await expect(chart).toContainText('Loss: 2 retained / 2 total samples')
    await expect(chart.getByRole('img')).toHaveAttribute('data-viewport', viewport!)
    await expect(chart.getByRole('button', { name: 'Toggle series Accuracy' })).toHaveAttribute('aria-pressed', 'false')
    const posts: string[] = []
    page.on('request', value => { if (value.method() === 'POST' && value.url().endsWith('/execution/runs')) posts.push(value.url()) })
    await page.reload()
    await expect(page.getByLabel('Cell result', { exact: true })).toHaveText('42')
    await expect(chart.getByRole('button', { name: 'Toggle series Accuracy' })).toHaveAttribute('aria-pressed', 'true')
    const csv = (await downloadText(page, 'Export samples CSV…')).bytes.toString()
    expect(csv).toBe('Series,X,Y\r\n"Loss",0,9\r\n"Loss",1,4\r\n"Accuracy",0,1\r\n"Accuracy",1,8\r\n')
    await chart.getByRole('button', { name: 'Toggle series Loss' }).click()
    await chart.getByRole('button', { name: 'Toggle series Accuracy' }).click()
    await expect(chart).toContainText('All series hidden')
    expect(posts).toEqual([])
    expect((await (await request(page, execution(project.id))).json()).runs).toHaveLength(1)
  } finally { await release(page, project.id) }
})

test('authored metrics use frozen declared bindings and enforce reader revocation', async ({ page, browser, baseURL }) => {
  await login(page)
  const cellUI = { inputs: [], pre: [], post: [{ id: 'metric', kind: 'metric', title: 'Published metric', binding: 'answer' }] }
  const { project } = await book(page, 'answer = 7\nother = 99\nanswer\n', [], cellUI)
  const context = await browser.newContext({ baseURL })
  try {
    const first = await run(page, project.id)
    expect(first.cells[0].metrics).toEqual([{ name: 'answer', value: '7' }])
    const bob = await context.newPage(); await login(bob, 'Bob')
    const bobId = (await (await request(bob, '/api/session')).json()).account.id
    expect((await request(bob, `${execution(project.id)}/runs/${first.id}`)).status()).toBe(404)
    await request(page, `/api/projects/${project.id}/memberships`, 'POST', { account_id: bobId, role: 'viewer' })
    await bob.goto(`/projects/${project.id}`)
    await expect(bob.getByLabel('Published metric value', { exact: true })).toHaveText('7')
    await expect(bob.getByRole('button', { name: 'Components for cell 1' })).toHaveCount(0)
    await page.getByRole('button', { name: 'Components for cell 1' }).click()
    await page.getByRole('dialog').getByLabel('Published variable', { exact: true }).fill('other')
    await page.getByRole('button', { name: 'Update notebook draft' }).click()
    await page.getByRole('button', { name: 'Save notebook', exact: true }).click()
    await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved')
    await expect(page.getByLabel('Published metric value', { exact: true })).toHaveText('Unavailable')
    const old = (await (await request(bob, `${execution(project.id)}/runs/${first.id}`)).json()).run
    expect(old.cells[0].metrics).toEqual([{ name: 'answer', value: '7' }])
    await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
    await expect(page.getByLabel('Published metric value', { exact: true })).toHaveText('99')
    await bob.reload(); await expect(bob.getByLabel('Published metric value', { exact: true })).toHaveText('99')
    await request(page, `/api/projects/${project.id}/memberships/${bobId}`, 'DELETE')
    await expect(bob.getByLabel('Published metric value', { exact: true })).toHaveText('Unavailable')
    expect((await request(bob, `${execution(project.id)}/runs/${first.id}`)).status()).toBe(404)
  } finally { await context.close(); await release(page, project.id) }
})

test('authored table fallback owns the implicit result and missing channels stay explicit', async ({ page }) => {
  await login(page)
  const cellUI = { inputs: [], pre: [], post: [
    { id: 'all_tables', kind: 'table', title: 'Result table' },
    { id: 'missing_table', kind: 'table', title: 'Missing table', table_id: 'missing' },
    { id: 'missing_image', kind: 'image', title: 'Missing image', image_id: 'missing' },
    { id: 'empty_chart', kind: 'live_chart', title: 'Empty chart', chart_id: 'empty' },
  ] }
  const { project } = await book(page, 'from notebook.ui import DataTableView\n[[9223372036854775807]]\n', ['ui'], cellUI)
  const component = (id: string) => page.locator(`[data-component-id="${id}"]`)
  try {
    expect((await run(page, project.id)).state).toBe('succeeded')
    await expect(page.getByTestId('rich-table')).toHaveCount(1)
    await expect(component('all_tables').getByTestId('rich-table')).toContainText('9223372036854775807')
    await expect(page.getByTestId('cell-presentation').getByTestId('rich-table')).toHaveCount(0)
    await expect(component('missing_table')).toContainText('Table unavailable')
    await expect(component('missing_image')).toContainText('Image channel unavailable')
    await expect(component('empty_chart')).toContainText('Waiting for chart samples')
    await expect(component('empty_chart').getByRole('button', { name: 'Export samples CSV…' })).toBeDisabled()
    await save(page, 'from notebook.ui import DataTableView\nnotebook.show(DataTableView([[3]], columns: ["Published"]), id: "published")\n[[4]]\n')
    expect((await run(page, project.id)).state).toBe('succeeded')
    await expect(page.getByTestId('rich-table')).toHaveCount(2)
    await expect(component('all_tables').getByTestId('rich-table')).toContainText('Published')
    await expect(page.getByTestId('cell-presentation').getByTestId('rich-table')).toHaveCount(1)
  } finally { await release(page, project.id) }
})
