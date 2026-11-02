import { expect, test, type Page } from '@playwright/test'

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
async function book(page: Page, sources: string[]) {
  const created = await request(page, '/api/projects', 'POST', { title: `Execution ${crypto.randomUUID()}` })
  expect(created.status()).toBe(201)
  const project = (await created.json()).project
  const path = `/api/projects/${project.id}/notebook`
  const initial = (await (await request(page, path, 'POST', {})).json()).notebook
  const document = JSON.parse(initial.document)
  document.sheets[0].cells = sources.map((source, index) => ({ id: String(index + 1), kind: 'code', source, mode: 'manual' }))
  const saved = await request(page, path, 'PUT', { command_id: crypto.randomUUID(), base_revision: initial.revision, document: JSON.stringify(document) })
  expect(saved.status()).toBe(200)
  return { project, notebook: (await saved.json()).notebook }
}
async function registry(page: Page, id: string) {
  const result = await request(page, execution(id))
  expect(result.status()).toBe(200)
  return result.json()
}
async function getRun(page: Page, id: string, runId: string) {
  const result = await request(page, `${execution(id)}/runs/${runId}`)
  expect(result.status()).toBe(200)
  return (await result.json()).run
}
async function waitRun(page: Page, id: string, runId: string, state: string | RegExp = /^(succeeded|failed|cancelled|force-stopped|interrupted)$/) {
  let run: any
  await expect.poll(async () => { run = await getRun(page, id, runId); return run.state }, { timeout: 15_000 }).toMatch(typeof state === 'string' ? new RegExp(`^${state}$`) : state)
  return run
}
async function save(page: Page) {
  await page.getByRole('button', { name: 'Save notebook', exact: true }).click()
  await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved')
}
async function release(page: Page, id: string) {
  const current = await registry(page, id)
  for (const run of current.runs.filter((value: any) => !['succeeded', 'failed', 'cancelled', 'force-stopped', 'interrupted'].includes(value.state))) {
    expect((await request(page, `${execution(id)}/runs/${run.id}/stop`, 'POST', { command_id: crypto.randomUUID(), runtime_epoch: run.runtime_epoch, force: true })).status()).toBe(200)
    await waitRun(page, id, run.id)
  }
  const latest = new Map<string, any>()
  for (const runtime of current.runtimes) if (!current.reset_epochs.includes(runtime.runtime_epoch)) latest.set(runtime.sheet_id, runtime)
  for (const runtime of latest.values()) {
    const response = await request(page, `${execution(id)}/restart`, 'POST', { command_id: crypto.randomUUID(), sheet_id: runtime.sheet_id, runtime_epoch: runtime.runtime_epoch })
    expect(response.status()).toBe(200)
  }
}

test('Run All, single-cell run, output, failure, provenance and history', async ({ page }) => {
  await login(page)
  const { project } = await book(page, ['amount = 21\namount\n', 'print "computed"\namount * 2\n'])
  try {
    await page.goto(`/projects/${project.id}`)
    await page.getByRole('button', { name: 'Run All', exact: true }).click()
    const cells = page.getByTestId('notebook-cell')
    await expect(cells.nth(0).getByLabel('Cell result', { exact: true })).toHaveText('21')
    await expect(cells.nth(1).getByLabel('Cell result', { exact: true })).toHaveText('42')
    await expect(cells.nth(1).getByLabel('Cell output', { exact: true })).toHaveText('computed\n')
    const initial = (await registry(page, project.id)).runs[0]
    await page.getByRole('textbox', { name: 'Code cell 1', exact: true }).fill('amount = 30\namount\n')
    await expect(page.getByRole('button', { name: 'Run All', exact: true })).toBeDisabled()
    await expect(cells.nth(1)).toContainText('Previous result')
    await save(page)
    await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
    await expect(cells.nth(0).getByLabel('Cell result', { exact: true })).toHaveText('30')
    await page.getByRole('button', { name: 'Run cell 2', exact: true }).click()
    await expect(cells.nth(1).getByLabel('Cell result', { exact: true })).toHaveText('60')
    await page.getByTestId('project-heading').click()
    for (const colorScheme of ['light', 'dark'] as const) {
      await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' })
      for (const width of [1280, 375, 320]) {
        await page.setViewportSize({ width, height: 900 })
        await page.evaluate(() => { window.scrollTo(0, 0); return new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))) })
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
        if (width !== 320) await page.screenshot({ path: `../build/execution-results-${colorScheme}-${width}.png`, fullPage: true })
      }
    }
    await page.emulateMedia({ colorScheme: 'light', reducedMotion: 'reduce' })
    await page.setViewportSize({ width: 1280, height: 900 })
    await page.getByRole('textbox', { name: 'Code cell 2', exact: true }).fill('missing_name()\n')
    await save(page)
    await page.getByRole('button', { name: 'Run cell 2', exact: true }).click()
    await expect(cells.nth(1).getByLabel('Cell error', { exact: true })).toContainText('missing_name')
    await page.locator('.run-history > summary').click()
    await page.getByRole('button', { name: `View run ${initial.id}`, exact: true }).click()
    await expect(cells.nth(1).getByLabel('Cell result', { exact: true })).toHaveText('42')
    await expect(cells.nth(1)).toContainText('Previous result')
    await expect(page.getByRole('textbox', { name: 'Code cell 2', exact: true })).toHaveValue('missing_name()\n')
    await page.getByRole('button', { name: 'Show latest results', exact: true }).click()
    await expect(cells.nth(1).getByLabel('Cell error', { exact: true })).toContainText('missing_name')
    expect((await registry(page, project.id)).runs.length).toBeLessThanOrEqual(2)
    const history = await page.request.get(`/api/projects/${project.id}/execution/history`)
    expect((await history.json()).runs).toHaveLength(4)
  } finally { await release(page, project.id) }
})

test('live output and accepted work survive reload and closing the page without replay', async ({ page, context }) => {
  await login(page)
  const { project } = await book(page, ['import task\nprint "working"\ntask.sleep(6000)\n42\n'])
  try {
    await page.goto(`/projects/${project.id}`)
    await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
    await expect(page.getByLabel('Cell output', { exact: true })).toHaveText('working\n')
    const first = (await registry(page, project.id)).runs[0]
    const posts: string[] = []
    page.on('request', request => { if (request.method() === 'POST' && request.url().endsWith('/execution/runs')) posts.push(request.url()) })
    await page.reload()
    await expect(page.getByTestId('execution-status')).toContainText(/Running|Finishing/)
    expect(posts).toEqual([])
    await page.close()
    const restored = await context.newPage()
    restored.on('request', request => { if (request.method() === 'POST' && request.url().endsWith('/execution/runs')) posts.push(request.url()) })
    await restored.goto(`/projects/${project.id}`)
    await restored.bringToFront()
    await expect(restored.getByLabel('Cell result', { exact: true })).toHaveText('42', { timeout: 15_000 })
    const records = await registry(restored, project.id)
    expect(records.runs).toHaveLength(1)
    expect(records.runs[0].id).toBe(first.id)
    expect(records.runs[0].runtime_epoch).toBe(first.runtime_epoch)
    expect(posts).toEqual([])
  } finally { await release(page, project.id) }
})

test('cooperative Stop, Force Stop, explicit restart and stale epoch protection', async ({ page }) => {
  await login(page)
  const { project, notebook } = await book(page, ['import task\ntask.sleep(60000)\n42\n'])
  try {
    await page.goto(`/projects/${project.id}`)
    await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
    let run = (await registry(page, project.id)).runs.at(-1)
    await waitRun(page, project.id, run.id, 'running')
    await page.getByRole('button', { name: 'Stop', exact: true }).click()
    await waitRun(page, project.id, run.id, 'cancelled')
    await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
    run = (await registry(page, project.id)).runs.at(-1)
    await waitRun(page, project.id, run.id, 'running')
    page.once('dialog', dialog => dialog.accept())
    await page.getByRole('button', { name: 'Force Stop…', exact: true }).click()
    await waitRun(page, project.id, run.id, 'force-stopped')
    await expect(page.getByTestId('execution-status')).toHaveText('Restart required')
    await expect(page.getByRole('button', { name: 'Run All', exact: true })).toBeDisabled()
    const blocked = await request(page, `${execution(project.id)}/runs`, 'POST', { command_id: crypto.randomUUID(), revision: notebook.revision, sheet_id: 'main', cell_id: '1', action: 'run' })
    expect(blocked.status()).toBe(409)
    expect((await blocked.json()).error.code).toBe('runtime_restart_required')
    page.once('dialog', dialog => dialog.accept())
    await page.getByRole('button', { name: 'Restart Worker…', exact: true }).click()
    await expect(page.getByLabel('Cell result', { exact: true })).toHaveCount(0)
    await page.getByRole('textbox', { name: 'Code cell 1', exact: true }).fill('import task\ntask.sleep(2000)\n42\n')
    await save(page)
    await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
    const fresh = (await registry(page, project.id)).runs.at(-1)
    expect(fresh.runtime_epoch).not.toBe(run.runtime_epoch)
    const stale = await request(page, `${execution(project.id)}/runs/${fresh.id}/stop`, 'POST', { command_id: crypto.randomUUID(), runtime_epoch: run.runtime_epoch, force: true })
    expect(stale.status()).toBe(409)
    await expect(page.getByLabel('Cell result', { exact: true })).toHaveText('42', { timeout: 10_000 })
  } finally { await release(page, project.id) }
})

test('lost accepted Run response is recovered by receipt after reload with one physical run', async ({ page }) => {
  await login(page)
  const { project } = await book(page, ['42\n'])
  try {
    let sends = 0
    await page.route(`**${execution(project.id)}/runs`, async route => {
      if (route.request().method() !== 'POST') return route.continue()
      sends++
      expect((await route.fetch()).status()).toBe(200)
      await route.abort('failed')
    })
    await page.route(`**${execution(project.id)}/commands/*`, route => route.fulfill({ status: 503, contentType: 'application/json', body: JSON.stringify({ error: { message: 'Receipt connection interrupted.' } }) }))
    await page.goto(`/projects/${project.id}`)
    await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
    await expect(page.getByTestId('execution-message')).toContainText('command outcome')
    await page.reload()
    await expect(page.getByTestId('execution-message')).toContainText('command outcome')
    await expect(page.getByRole('button', { name: 'Run All', exact: true })).toBeDisabled()
    expect(sends).toBe(1)
    await page.unroute(`**${execution(project.id)}/commands/*`)
    await expect(page.getByLabel('Cell result', { exact: true })).toHaveText('42')
    expect(sends).toBe(1)
    expect((await registry(page, project.id)).runs).toHaveLength(1)
    expect(await page.evaluate(() => Object.keys(sessionStorage).filter(key => key.startsWith('sputnik.execution.pending.')))).toEqual([])
  } finally { await release(page, project.id) }
})

test('an unaccepted request retries only on explicit action with its original ID and revision', async ({ page }) => {
  await login(page)
  const { project } = await book(page, ['42\n'])
  try {
    const bodies: any[] = []
    await page.route(`**${execution(project.id)}/runs`, async route => {
      if (route.request().method() !== 'POST') return route.continue()
      bodies.push(route.request().postDataJSON())
      if (bodies.length === 1) await route.abort('failed')
      else await route.continue()
    })
    await page.goto(`/projects/${project.id}`)
    await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
    await expect(page.getByRole('button', { name: 'Retry pending command', exact: true })).toBeVisible()
    expect((await registry(page, project.id)).runs).toHaveLength(0)
    expect(bodies).toHaveLength(1)
    await page.getByRole('textbox', { name: 'Code cell 1', exact: true }).fill('84\n')
    await page.getByRole('button', { name: 'Retry pending command', exact: true }).click()
    await expect(page.getByLabel('Cell result', { exact: true })).toHaveText('42')
    expect(bodies).toHaveLength(2)
    expect(bodies[1]).toEqual(bodies[0])
    await expect(page.getByRole('textbox', { name: 'Code cell 1', exact: true })).toHaveValue('84\n')
    await expect(page.getByTestId('notebook-cell').first()).toContainText('Previous result')
    await save(page)
    await page.getByRole('button', { name: 'Run cell 1', exact: true }).click()
    await expect(page.getByLabel('Cell result', { exact: true })).toHaveText('84')
    expect((await runHistory(page, project.id)).runs).toHaveLength(2)
    expect(bodies[2].command_id).not.toBe(bodies[0].command_id)
  } finally { await release(page, project.id) }
})

test('execution enforces project/run ownership, role changes, receipts, CSRF and safe DTOs', async ({ page, browser, baseURL }) => {
  await login(page)
  const { project, notebook } = await book(page, ['import task\ntask.sleep(60000)\n42\n'])
  const otherBook = await book(page, ['84\n'])
  const foreign = await browser.newContext({ baseURL })
  try {
    const body = { command_id: crypto.randomUUID(), revision: notebook.revision, sheet_id: 'main', cell_id: '1', action: 'run' }
    const accepted = await request(page, `${execution(project.id)}/runs`, 'POST', body)
    expect(accepted.status()).toBe(200)
    const run = (await accepted.json()).run
    await waitRun(page, project.id, run.id, 'running')
    expect((await request(page, `${execution(otherBook.project.id)}/runs/${run.id}`)).status()).toBe(404)
    expect((await request(page, `${execution(otherBook.project.id)}/runs/${run.id}/stop`, 'POST', { command_id: crypto.randomUUID(), runtime_epoch: run.runtime_epoch, force: true })).status()).toBe(404)
    expect((await (await request(page, `${execution(otherBook.project.id)}/commands/${body.command_id}`)).json()).command.state).toBe('unknown')
    expect((await page.request.post(`${execution(project.id)}/runs`, { data: body })).status()).toBe(403)
    const duplicate = await request(page, `${execution(project.id)}/runs`, 'POST', body)
    expect((await duplicate.json()).run.id).toBe(run.id)
    const busy = await request(page, `${execution(project.id)}/runs`, 'POST', { ...body, command_id: crypto.randomUUID() })
    expect(busy.status()).toBe(409)
    expect((await busy.json()).error.code).toBe('runtime_busy')
    const bob = await foreign.newPage()
    await login(bob, 'Bob')
    const bobId = (await (await request(bob, '/api/session')).json()).account.id
    expect((await request(bob, execution(project.id))).status()).toBe(404)
    expect((await request(bob, `${execution(project.id)}/runs/${run.id}`)).status()).toBe(404)
    await request(page, `/api/projects/${project.id}/memberships`, 'POST', { account_id: bobId, role: 'viewer' })
    expect((await request(bob, execution(project.id))).status()).toBe(200)
    expect((await request(bob, `${execution(project.id)}/runs/${run.id}`)).status()).toBe(200)
    expect((await request(bob, `${execution(project.id)}/runs`, 'POST', { ...body, command_id: crypto.randomUUID() })).status()).toBe(403)
    expect((await request(bob, `${execution(project.id)}/runs/${run.id}/stop`, 'POST', { command_id: crypto.randomUUID(), runtime_epoch: run.runtime_epoch, force: true })).status()).toBe(403)
    expect((await request(bob, `${execution(project.id)}/restart`, 'POST', { command_id: crypto.randomUUID(), sheet_id: 'main', runtime_epoch: run.runtime_epoch })).status()).toBe(403)
    await bob.goto(`/projects/${project.id}`)
    await expect(bob.getByTestId('execution-status')).toHaveText('Running')
    await expect(bob.getByRole('button', { name: 'Run All', exact: true })).toHaveCount(0)
    await expect(bob.getByRole('button', { name: 'Run cell 1', exact: true })).toHaveCount(0)
    await request(page, `/api/projects/${project.id}/memberships`, 'POST', { account_id: bobId, role: 'editor' })
    await expect(bob.getByRole('button', { name: 'Run All', exact: true })).toBeVisible()
    await bob.getByRole('button', { name: 'Stop', exact: true }).click()
    await waitRun(page, project.id, run.id, 'cancelled')
    await request(page, `/api/projects/${project.id}/memberships`, 'POST', { account_id: bobId, role: 'viewer' })
    await expect(bob.getByRole('button', { name: 'Run All', exact: true })).toHaveCount(0)
    const publicResult = await getRun(page, project.id, run.id)
    const publicRegistry = await registry(page, project.id)
    expect(JSON.stringify([publicResult, publicRegistry])).not.toMatch(/"project":|"runtime_id":|worker_pid|execution_document|live_presentation|agent\.sock|\/private\//)
    expect((await (await request(page, `${execution(project.id)}/commands/${body.command_id}`)).json()).command.run.id).toBe(run.id)
    expect((await (await request(page, `${execution(project.id)}/commands/web-initialize`)).json()).command.state).toBe('unknown')
    expect((await request(page, `${execution(otherBook.project.id)}/restart`, 'POST', { command_id: crypto.randomUUID(), sheet_id: 'missing_sheet', runtime_epoch: null })).status()).toBe(404)
    expect((await request(page, `${execution(project.id)}/runs`, 'POST', { ...body, command_id: crypto.randomUUID(), project_id: 'forged' })).status()).toBe(400)
    expect((await request(page, `${execution(project.id)}/runs`, 'POST', { ...body, command_id: crypto.randomUUID(), action: 'watch' })).status()).toBe(422)
    expect((await request(page, `${execution(project.id)}/runs`, 'POST', { ...body, command_id: crypto.randomUUID(), revision: '0'.repeat(64) })).status()).toBe(409)
    await request(page, `/api/projects/${project.id}/memberships/${bobId}`, 'DELETE')
    expect((await request(bob, `${execution(project.id)}/runs/${run.id}`)).status()).toBe(404)
    expect((await request(bob, `${execution(project.id)}/commands/${body.command_id}`)).status()).toBe(404)
  } finally { await foreign.close(); await release(page, project.id); await release(page, otherBook.project.id) }
})

test('Stop during preparation is cancellation; an unobserved child error fails the run', async ({ page }) => {
  await login(page)
  const { project, notebook } = await book(page, ['import task\ntask.sleep(60000)\n42\n'])
  try {
    const accepted = await request(page, `${execution(project.id)}/runs`, 'POST', { command_id: crypto.randomUUID(), revision: notebook.revision, sheet_id: 'main', cell_id: '1', action: 'run' })
    expect(accepted.status()).toBe(200)
    const run = (await accepted.json()).run
    expect((await request(page, `${execution(project.id)}/runs/${run.id}/stop`, 'POST', { command_id: crypto.randomUUID(), runtime_epoch: run.runtime_epoch, force: false })).status()).toBe(200)
    expect((await waitRun(page, project.id, run.id, 'cancelled')).error).toBe('')
    await page.goto(`/projects/${project.id}`)
    await page.getByRole('textbox', { name: 'Code cell 1', exact: true }).fill('import task\nchild = task.spawn:\n  task.sleep(50)\n  1 / 0\n42\n')
    await save(page)
    await expect(page.getByRole('button', { name: 'Run cell 1', exact: true })).toBeEnabled()
    await page.getByRole('textbox', { name: 'Code cell 1', exact: true }).click()
    await page.keyboard.press('Shift+Enter')
    await expect(page.locator('.execution-failure')).toContainText(/zero|Zero|division|Division/)
    const last = (await registry(page, project.id)).runs.at(-1)
    expect(last.state).toBe('failed')
    const failed = await getRun(page, project.id, last.id)
    expect(failed.task_errors.length).toBeGreaterThan(0)
    expect(failed.task_errors.every((message: unknown) => typeof message === 'string')).toBe(true)
  } finally { await release(page, project.id) }
})

async function runHistory(page: Page, id: string) {
  const response = await page.request.get(`/api/projects/${id}/execution/history`)
  expect(response.ok()).toBe(true)
  return response.json()
}
