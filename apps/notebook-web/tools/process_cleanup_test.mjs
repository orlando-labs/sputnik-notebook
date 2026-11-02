// POSIX integration: real smoke services and a running Core worker must leave no
// processes after normal termination or forced process-group cancellation.
import assert from 'node:assert/strict'
import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'
import { mkdtemp, open, rm, writeFile } from 'node:fs/promises'
import net from 'node:net'
import path from 'node:path'
import { APP, sleep } from './common.mjs'
const run = promisify(execFile)
if (process.platform === 'win32') throw new Error('This process-group acceptance requires POSIX ps/signals.')
async function processes() {
  const { stdout } = await run('ps',['-axo','pid=,ppid=,pgid=,state=,command='])
  return stdout.trim().split('\n').flatMap(line => {
    const match = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/.exec(line)
    return match ? [{ pid:Number(match[1]), parent:Number(match[2]), group:Number(match[3]), state:match[4], command:match[5] }] : []
  })
}
async function until(read,predicate,label,timeout=20000) {
  const deadline=Date.now()+timeout
  while(Date.now()<deadline){const result=await read();if(predicate(result))return result;await sleep(100)}
  throw new Error('Timed out: '+label)
}
async function freePort(){const server=net.createServer();await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const port=server.address().port;await new Promise(resolve=>server.close(resolve));return port}
function core(root, method, params) {
  return new Promise((resolve,reject)=>{
    const socket=net.connect(path.join(root,'agent.sock'));let text=''
    socket.setTimeout(5000,()=>socket.destroy(new Error('Core timeout')))
    socket.on('connect',()=>socket.write(JSON.stringify({method,params})+'\n'));socket.on('error',reject)
    socket.on('data',chunk=>{text+=chunk;if(!text.includes('\n'))return;socket.end();try{const reply=JSON.parse(text.split('\n')[0]);assert.equal(reply.status,200,JSON.stringify(reply));resolve(reply.data)}catch(error){reject(error)}})
  })
}
const results=[]
for(const native of [false,true])for(const signal of ['SIGTERM','SIGKILL']){
  const root=await mkdtemp('/private/tmp/nbcleanup-'),coreRoot=path.join(root,'core'),port=await freePort(),mode=native?'production':'development'
  const log=await open(path.join(APP,`build/process-cleanup-${native?'native':'vm'}-${signal}.log`),'w')
  const server=spawn(process.execPath,[path.join(APP,'tools/smoke_server.mjs'),'--mode',mode,'--port',String(port),'--database',path.join(root,'catalog.sqlite'),'--core-root',coreRoot,...(native?['--native-backend']:[])],{
    cwd:APP,env:{...process.env,NOTEBOOK_WEB_PACKAGE_FIXTURE:'0'},stdio:['ignore',log.fd,log.fd],detached:true,
  })
  const owned=rows=>rows.filter(row=>(row.group===server.pid||row.command.includes(coreRoot))&&!row.state.startsWith('Z'))
  try{
    await until(async()=>{assert.equal(server.exitCode,null,'smoke exited');try{return(await fetch(`http://127.0.0.1:${port}/api/session`)).status}catch{return null}},status=>status===200,'smoke readiness',60000)
    const document={format:'sputnik-notebook',version:1,title:'Cleanup acceptance',active_sheet:'main',sheets:[{id:'main',title:'Main',cells:[{id:'1',kind:'code',mode:'manual',source:'import task\ntask.sleep(60000)\n42\n'}]}],modules:[],auto_imports:[]}
    const saved=await core(coreRoot,'project.put',{project_id:'cleanup',command_id:'save',base_revision:null,document:JSON.stringify(document),files:{}})
    const accepted=await core(coreRoot,'run.start',{project_id:'cleanup',command_id:'run',revision:saved.revision,sheet_id:'main',cell_id:'1',action:'run'})
    await until(()=>core(coreRoot,'run.get',{run_id:accepted.run_id}),run=>run.state==='running','running worker')
    const before=owned(await processes())
    assert(before.some(row=>row.command.includes('sputnik-notebook-worker --notebook-worker')),'acceptance must include a real running worker')
    assert(before.some(row=>row.command.includes('test/github_fixture.s')),'OAuth fixture must be running')
    if(!native)assert(before.some(row=>row.command.includes('/vite/bin/vite.js')),'Vite must be running')
    // Match Playwright cancellation: signal the owned runner group. Detached Core
    // workers exit when their host control/data channels close.
    process.kill(-server.pid,signal)
    await until(async()=>owned(await processes()),rows=>rows.length===0,'all owned processes exited',15000)
    results.push({backend:native?'native':'VM',assets:mode,signal,owned_processes_before:before.length,remaining:0})
    console.log(`PASS ${native?'native':'VM'}/${mode} ${signal}: ${before.length} owned processes → 0 (including active worker)`)
  }finally{
    try{process.kill(-server.pid,'SIGKILL')}catch(error){if(error.code!=='ESRCH')throw error}
    // Test-owned roots only, including an isolated worker if an assertion fails.
    for(const row of owned(await processes())){try{process.kill(row.pid,'SIGKILL')}catch(error){if(error.code!=='ESRCH')throw error}}
    await log.close();await rm(root,{recursive:true,force:true})
  }
}
await writeFile(path.join(APP,'build/process-cleanup-summary.json'),JSON.stringify({checks:results,scope:'Only test-owned process groups/state roots; no production service lifetime changes.'},null,2)+'\n')
