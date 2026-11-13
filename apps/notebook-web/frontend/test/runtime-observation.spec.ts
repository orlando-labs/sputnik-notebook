import { test, expect, type Page } from '@playwright/test'
import { readFile } from 'node:fs/promises'
async function login(page: Page, user = 'Alice') { await page.goto('/'); await page.getByRole('button', { name: 'Continue with GitHub' }).click(); await page.getByRole('button', { name: `Sign in as ${user}` }).click(); await expect(page.getByTestId('account-name')).toHaveText(user) }
async function request(page: Page, path: string, method = 'GET', data?: unknown) {
  const token = (await page.context().cookies()).find(cookie => cookie.name === 'orbit-csrf')?.value
  return page.request.fetch(path, { method, data, headers: { Accept: 'application/json', Origin: new URL(page.url()).origin, ...(token ? { 'X-CSRF-Token': decodeURIComponent(token) } : {}) } })
}
const base = (id: string) => `/api/projects/${id}`
const stored = async (page: Page, id: string) => (await (await request(page, base(id)+'/notebook')).json()).notebook
const registry = async (page: Page, id: string) => (await (await request(page, base(id)+'/execution')).json())
const card = (page: Page, id: string) => page.locator(`[data-board-component="${id}"]`)
async function open(page: Page) { await page.getByRole('navigation', { name: 'Boards', exact: true }).getByRole('button', { name: 'Observations', exact: true }).click() }
const component = (id: string, kind: string, extra: any = {}) => ({ id, kind, title: id, row: 'row_'+id, span: 12, ...extra })
async function book(page: Page, source: string, components: any[], changes: any = {}, policy: any = {}) {
  const created = await request(page,'/api/projects','POST',{title:'Runtime observations'}), project = (await created.json()).project
  await request(page,base(project.id)+'/notebook','POST',{})
  const initial = await stored(page,project.id), document = JSON.parse(initial.document)
  Object.assign(document,{version:4,dependencies:[],inputs:[],resource_policy:policy,sheets:[{id:'main',title:'Main',cells:[{id:'1',kind:'code',mode:'manual',source}]}],boards:[{id:'observations',title:'Observations',sheet:'main',columns:1,rows:components.filter(c=>c.row).map(c=>({id:c.row})),components}]})
  if (changes['modules/jobs.s']) document.modules = [{id:'jobs',path:'modules/jobs.s'}]
  const saved = await request(page,base(project.id)+'/notebook','PUT',{command_id:crypto.randomUUID(),base_revision:initial.revision,document:JSON.stringify(document),changes})
  expect(saved.status(),await saved.text()).toBe(200)
  await page.goto(`/projects/${project.id}`);await open(page)
  return {id:project.id,document,notebook:(await saved.json()).notebook}
}
async function finish(page: Page, id: string) {
  let result: any
  await expect.poll(async()=> { const list = await registry(page,id), run = list.runs.at(-1); if (!run)return ''; result = (await (await request(page,base(id)+'/execution/runs/'+run.id)).json()).run;return result.state },{timeout:20000}).toMatch(/^(succeeded|failed|cancelled|force-stopped|interrupted)$/)
  return result
}
async function release(page: Page, id: string) {
  const list = await registry(page,id)
  for (const run of list.runs.filter((run:any)=>!['succeeded','failed','cancelled','force-stopped','interrupted'].includes(run.state))) await request(page,base(id)+`/execution/runs/${run.id}/stop`,'POST',{command_id:crypto.randomUUID(),runtime_epoch:run.runtime_epoch,force:true})
  for (const runtime of list.runtimes.filter((runtime:any)=>!list.reset_epochs.includes(runtime.runtime_epoch))) await request(page,base(id)+'/execution/restart','POST',{command_id:crypto.randomUUID(),sheet_id:runtime.sheet_id,runtime_epoch:runtime.runtime_epoch})
}

test('sheet/cell/runtime status and real nested task failures remain bounded, source-safe and inert',async({page})=>{
  await login(page)
  const {id,notebook} = await book(page,'import task\nchild = task.spawn:\n  nested = task.spawn:\n    task.sleep(100)\n    1 / 0\n  task.sleep(600)\n  7\nprint "parent output"\ntask.sleep(1500)\n42\n',[
    component('sheet_status','status'),component('cell_status','status',{cell:'1',p1:{target_kind:'cell'}}),component('runtime_status','status',{p1:{target_kind:'runtime'}}),component('tasks','task_monitor')])
  try {
    await expect(card(page,'sheet_status')).toContainText('Ready');await expect(card(page,'runtime_status')).toContainText('Connected');await expect(card(page,'tasks')).toContainText('No task telemetry loaded')
    expect((await registry(page,id)).runs).toEqual([]);expect(await stored(page,id)).toEqual(notebook)
    await page.getByRole('button',{name:'Run Sheet',exact:true}).click()
    await expect(card(page,'sheet_status').getByRole('status')).toHaveText(/Preparing|Running|Finishing|Error/)
    const result=await finish(page,id);expect(result.state).toBe('failed');expect(result.rich_error).toBe('')
    expect(result.task_telemetry.tasks.length).toBeGreaterThanOrEqual(2)
    expect(result.task_telemetry.tasks.some((task:any)=>task.parent!=='0')).toBe(true)
    expect(result.task_telemetry.tasks.some((task:any)=>task.state==='failed')).toBe(true)
    expect(result.task_telemetry.tasks.every((task:any)=>typeof task.id==='string'&&typeof task.elapsed_ms==='string'&&!('file' in task)&&(!task.cell||task.cell==='1'))).toBe(true)
    await expect(card(page,'tasks')).toContainText('registered');await expect(card(page,'tasks')).toContainText('failed')
    await card(page,'tasks').getByRole('checkbox',{name:'Errors only',exact:true}).check()
    expect(await card(page,'tasks').locator('.runtime-task').count()).toBeGreaterThan(0)
    await expect(card(page,'tasks').locator('.runtime-task:not(.task-failed)')).toHaveCount(0)
    for(const scheme of ['light','dark'] as const)for(const width of [1280,375]){await page.emulateMedia({colorScheme:scheme});await page.setViewportSize({width,height:1000});expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);await card(page,'tasks').screenshot({path:`../build/runtime-tasks-${scheme}-${width}-${process.env.ORBIT_E2E_MODE||'production'}-${process.env.ORBIT_E2E_NATIVE==='1'?'native':'vm'}.png`})}
    await card(page,'cell_status').getByRole('button',{name:'Open source',exact:true}).click();await expect(page.getByLabel('Code cell 1',{exact:true})).toBeFocused()
    await page.getByLabel('Code cell 1',{exact:true}).fill('43\n');await open(page);await expect(card(page,'cell_status')).toContainText('Stale')
    expect((await registry(page,id)).runs).toHaveLength(1)
  } finally {await release(page,id)}
})

test('captured Inspect/Pretty/table, literal Unicode Find and filtered logs export without execution',async({page})=>{
  await login(page)
  const {id}=await book(page,'print "Alpha 🛰️"\nprint "beta"\n[{name: "<script>Alpha [.*]</script>", count: 9223372036854775807}, {name: "alpha", count: 2}]\n',[component('result','result',{cell:'1'}),component('logs','log',{cell:'1'})])
  try {
    await page.getByRole('button',{name:'Run Sheet',exact:true}).click();const result=await finish(page,id);expect(result.state).toBe('succeeded');expect(result.cells[0].result_format.pretty).toBeTruthy()
    const inspector=card(page,'result');await expect(inspector.getByLabel('Captured result',{exact:true})).toContainText('9223372036854775807')
    await inspector.getByLabel('Result format',{exact:true}).selectOption('pretty');await inspector.getByRole('button',{name:'Find in result…',exact:true}).click();await inspector.getByLabel('Find substring in result',{exact:true}).fill('[.*]');await expect(inspector.locator('mark')).toHaveCount(1)
    await inspector.getByLabel('Find substring in result',{exact:true}).fill('alpha');await expect(inspector.locator('mark')).toHaveCount(2);await inspector.getByRole('checkbox',{name:'Match case',exact:true}).check();await expect(inspector.locator('mark')).toHaveCount(1)
    await inspector.getByRole('button',{name:'Next match',exact:true}).click();await inspector.getByRole('checkbox',{name:'Wrap lines',exact:true}).uncheck();expect(await inspector.locator('script,img').count()).toBe(0)
    const download=page.waitForEvent('download');await inspector.getByRole('button',{name:'Save result…',exact:true}).click();expect(await readFile((await(await download).path())!,'utf8')).toBe(result.cells[0].result_format.pretty)
    await inspector.getByLabel('Result format',{exact:true}).selectOption('table');await expect(inspector.getByRole('table')).toBeVisible()
    const logs=card(page,'logs');await expect(logs.getByLabel('Cell output',{exact:true})).toContainText('Alpha 🛰️');await logs.getByLabel('Log stream',{exact:true}).selectOption('stderr');await expect(logs).toContainText('No matching output');await logs.getByLabel('Log stream',{exact:true}).selectOption('stdout');await logs.getByLabel('Find in output',{exact:true}).fill('missing');await expect(logs).toContainText('No matching output');await logs.getByLabel('Find in output',{exact:true}).fill('Alpha')
    const logDownload=page.waitForEvent('download');await logs.getByRole('button',{name:'Save output…',exact:true}).click();expect(await readFile((await(await logDownload).path())!,'utf8')).toContain('[stdout] Alpha 🛰️')
    expect((await registry(page,id)).runs).toHaveLength(1)
  } finally {await release(page,id)}
})

test('Apply Modules on a board prepares its sheet to run the saved module revision', async ({ page }) => {
  await login(page)
  const { id } = await book(page, 'from jobs import work\nwork()\n', [], {
    'modules/jobs.s': { encoding: 'utf8', data: 'package jobs\nexport work\ndef work(): 1\n' },
  })
  const apply = page.getByRole('button', { name: 'Apply Modules', exact: true })
  const run = page.getByRole('button', { name: 'Run Sheet', exact: true })
  try {
    await expect(apply).toBeDisabled()
    await run.click()
    const previous = await finish(page, id)
    expect(previous.state).toBe('succeeded')
    expect(previous.cells[0].result).toBe('1')

    await page.getByRole('button', { name: 'jobs', exact: true }).click()
    await page.getByRole('textbox', { name: 'Module jobs', exact: true }).fill('package jobs\nexport work\ndef work(): 42\n')
    await open(page)
    await expect(apply).toBeDisabled()
    await page.getByRole('button', { name: 'Save notebook', exact: true }).click()
    await expect(page.getByTestId('execution-status')).toHaveText('Restart required')
    await expect(run).toBeDisabled()

    page.once('dialog', dialog => dialog.dismiss())
    await apply.click()
    await expect(run).toBeDisabled()
    page.once('dialog', dialog => dialog.accept())
    await apply.click()
    await expect(run).toBeEnabled()
    const reset = await registry(page, id)
    expect(reset.reset_epochs).toContain(previous.runtime_epoch)
    expect(reset.runs.map((entry: any) => entry.id)).toEqual([previous.id])
    await expect(page.getByTestId('notebook-board')).toBeVisible()

    await run.click()
    await expect.poll(async () => (await registry(page, id)).runs.at(-1)?.id).not.toBe(previous.id)
    const updated = await finish(page, id)
    expect(updated.state).toBe('succeeded')
    expect(updated.runtime_epoch).not.toBe(previous.runtime_epoch)
    expect(updated.revision).toBe((await stored(page, id)).revision)
    expect(updated.cells[0].result).toBe('42')
  } finally { await release(page, id) }
})

test('artifact references use the captured revision, reject external/traversal paths and preserve exact downloads',async({page})=>{
  await login(page)
  const binary=Buffer.from([0,255,128,1,13,10]), source='[{path: "resources/report.txt", name: "Report", caption: "literal <b>caption</b>"}, {path: "resources/data.bin", name: "Binary"}, {path: "/etc/passwd", name: "External"}, {path: "../secrets", name: "Traversal"}, {path: "resources/missing.txt", name: "Missing"}]\n'
  const {id}=await book(page,source,[component('files','artifacts',{cell:'1'})],{'resources/report.txt':{encoding:'utf8',data:'old revision 🛰️'},'resources/data.bin':{encoding:'base64',data:binary.toString('base64')}})
  try {
    await page.getByRole('button',{name:'Run Sheet',exact:true}).click();const oldRun=await finish(page,id);expect(oldRun.state).toBe('succeeded')
    const files=card(page,'files'), row=(name:string)=>files.locator('article').filter({has:page.getByText(name,{exact:true})})
    await expect(row('Report')).toContainText('literal <b>caption</b>');expect(await files.locator('b').count()).toBe(0)
    await expect(row('External').getByRole('button',{name:'Preview',exact:true})).toBeDisabled();await expect(row('Traversal').getByRole('button',{name:'Save copy…',exact:true})).toBeDisabled()
    await row('Report').getByRole('button',{name:'Preview',exact:true}).click();await expect(row('Report')).toContainText('old revision 🛰️')
    const waiting=page.waitForEvent('download');await row('Binary').getByRole('button',{name:'Save copy…',exact:true}).click();expect(await readFile((await(await waiting).path())!)).toEqual(binary)
    await row('Missing').getByRole('button',{name:'Preview',exact:true}).click();await expect(files.getByRole('alert')).toBeVisible()
    const current=await stored(page,id);expect((await request(page,base(id)+'/notebook','PUT',{command_id:crypto.randomUUID(),base_revision:current.revision,document:current.document,changes:{'resources/report.txt':{encoding:'utf8',data:'new revision'}}})).status()).toBe(200)
    await page.reload();await open(page);await expect(files).toContainText('Previous run · stale');await row('Report').getByRole('button',{name:'Preview',exact:true}).click();await expect(row('Report')).toContainText('old revision 🛰️')
    page.once('dialog',dialog=>dialog.accept());await page.getByRole('button',{name:'Apply Modules',exact:true}).click();await expect(page.getByRole('button',{name:'Run Sheet',exact:true})).toBeEnabled()
    await page.getByRole('button',{name:'Run Sheet',exact:true}).click();await expect.poll(async()=>(await registry(page,id)).runs.filter((run:any)=>run.id!==oldRun.id).length).toBe(1);const newRun=await finish(page,id);expect(newRun.id).not.toBe(oldRun.id);expect(newRun.revision).toBe((await stored(page,id)).revision);await row('Report').getByRole('button',{name:'Preview',exact:true}).click();await expect(row('Report')).toContainText('new revision')
    const invalid=await request(page,base(id)+'/notebook/file?revision='+current.revision+'&path=../secret');expect(invalid.status()).toBe(422)
  } finally {await release(page,id)}
})

test('new palette tools and status targets stage/save inertly and retain native extension fields',async({page})=>{
  await login(page)
  const {id}=await book(page,'42\n',[component('state','status',{future:{exact:'preserved'}})])
  try {
    const before=await stored(page,id);await page.getByRole('button',{name:'Design board Observations',exact:true}).click();const dialog=page.getByRole('dialog',{name:'Board Designer',exact:true})
    for(const title of ['Artifact Browser','Task Monitor','Status / Alert']){await dialog.getByRole('tab',{name:'Display',exact:true}).click();await dialog.getByRole('button',{name:'Add '+title,exact:true}).click()}
    await dialog.getByLabel('Execution target',{exact:true}).selectOption('runtime');await dialog.getByRole('button',{name:'Update notebook draft',exact:true}).click();expect(await stored(page,id)).toEqual(before);expect((await registry(page,id)).runs).toEqual([])
    await page.getByRole('button',{name:'Save notebook',exact:true}).click();await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved');const saved=JSON.parse((await stored(page,id)).document)
    expect(saved.boards[0].components.map((c:any)=>c.kind)).toEqual(['status','artifacts','task_monitor','status']);expect(saved.boards[0].components.at(-1).p1.target_kind).toBe('runtime');expect(saved.boards[0].components[0].future).toEqual({exact:'preserved'});expect((await registry(page,id)).runs).toEqual([])
  }finally{await release(page,id)}
})

test('runtime status reports exhausted computation while observation controls remain inert',async({page})=>{
  await login(page)
  const {id}=await book(page,'import task\ntask.sleep(10000)\n42\n',[component('quota','status',{p1:{target_kind:'runtime'}}),component('tasks','task_monitor')],{},{total_run_seconds:1,run_seconds:60})
  try {await page.getByRole('button',{name:'Run Sheet',exact:true}).click();expect((await finish(page,id)).state).toBe('force-stopped');await expect(card(page,'quota')).toContainText('Computation quota exhausted');await expect(card(page,'quota')).toContainText('One run:');await expect(page.getByRole('button',{name:'Run Sheet',exact:true})).toBeDisabled();expect((await registry(page,id)).runs).toHaveLength(1)}finally{await release(page,id)}
})

test('viewer can inspect saved artifacts and telemetry; revocation removes the loaded observations',async({page,browser,baseURL})=>{
  await login(page)
  const {id}=await book(page,'import task\nchild = task.spawn: 7\n[{path: "resources/report.txt", name: "Report"}]\n',[component('files','artifacts',{cell:'1'}),component('tasks','task_monitor')],{'resources/report.txt':{encoding:'utf8',data:'private report'}})
  const context=await browser.newContext({baseURL}),bob=await context.newPage()
  try {
    await page.getByRole('button',{name:'Run Sheet',exact:true}).click();await finish(page,id);await login(bob,'Bob');const profile=(await(await request(bob,'/api/session')).json()).account
    expect((await request(bob,base(id)+'/notebook')).status()).toBe(404)
    expect((await request(page,base(id)+'/memberships','POST',{account_id:profile.id,role:'viewer'})).status()).toBe(200)
    await bob.goto(`/projects/${id}`);await open(bob);await card(bob,'files').getByRole('button',{name:'Preview',exact:true}).click();await expect(card(bob,'files')).toContainText('private report');await expect(card(bob,'tasks')).toContainText('registered');await expect(bob.getByRole('button',{name:'Run Sheet',exact:true})).toHaveCount(0);const saved=await stored(bob,id);expect((await request(bob,base(id)+'/execution/runs','POST',{command_id:crypto.randomUUID(),revision:saved.revision,sheet_id:'main',cell_id:'1',action:'run'})).status()).toBe(403)
    expect((await request(page,base(id)+'/memberships/'+profile.id,'DELETE')).status()).toBe(204)
    await expect(card(bob,'files')).not.toContainText('private report');await expect(card(bob,'tasks')).not.toContainText('registered');expect((await request(bob,base(id)+'/notebook')).status()).toBe(404)
  }finally{await context.close();await release(page,id)}
})


test('status follows explicit action and service commands using saved targets and exact counters',async({page})=>{
  await login(page)
  const {id}=await book(page,'42\n',[
    component('invoke','action',{module_id:'jobs',function:'work',p1:{arguments:[]}}),
    {id:'clock',kind:'periodic_work',title:'Clock',module_id:'jobs',function:'work',period_seconds:60,retention:'tail',tail_limit:100,run_immediately:false},
    component('action_status','status',{p1:{target_kind:'action',target_component:'invoke'}}),
    component('service_status','status',{p1:{target_kind:'service',target_component:'clock'}}),
  ],{'modules/jobs.s':{encoding:'utf8',data:'package jobs\nexport work\ndef work(): 42\n'}})
  try {
    await expect(card(page,'action_status')).toContainText('Ready');expect((await registry(page,id)).runs).toEqual([])
    await card(page,'invoke').getByRole('button',{name:'invoke',exact:true}).click();expect((await finish(page,id)).state).toBe('succeeded');await expect(card(page,'action_status').getByRole('status')).toHaveText('Success')
    await page.getByRole('region',{name:'Services',exact:true}).getByRole('button',{name:'Run Once',exact:true}).click()
    await expect.poll(async()=>(await registry(page,id)).runs.length).toBe(2);await finish(page,id);await expect(card(page,'service_status')).toContainText('1 runs · 0 errors')
    expect((await registry(page,id)).runs).toHaveLength(2)
  }finally{await release(page,id)}
})
