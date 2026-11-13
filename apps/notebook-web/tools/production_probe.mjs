// Local acceptance of backend/main, independent Core and the documented proxy
// contract. A disposable catalog session is seeded; no OAuth provider is mocked
// or contacted. This does not deploy a server or exercise real GitHub consent.
import assert from 'node:assert/strict'
import http from 'node:http'
import https from 'node:https'
import net from 'node:net'
import path from 'node:path'
import { spawn, execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { cp, lstat, mkdir, mkdtemp, open, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { randomBytes, createHash } from 'node:crypto'
import { APP, COMPILER, stop, sleep } from './common.mjs'

const run = promisify(execFile), root = await mkdtemp('/private/tmp/nbprod-')
const nginx = process.env.NOTEBOOK_WEB_PROBE_NGINX, variant = nginx ? 'nginx-tls-probe' : 'production-probe'
const log = await open(path.join(APP, `build/${variant}.log`), 'w'), stdio = ['ignore', log.fd, log.fd]
const cookie = new Map(), secret = randomBytes(32).toString('hex'), csrf = randomBytes(32).toString('hex')
async function freePort() { const listener = net.createServer(); await new Promise(resolve => listener.listen(0, '127.0.0.1', resolve)); const port = listener.address().port; await new Promise(resolve => listener.close(resolve)); return port }
const port = await freePort(), backendPort = await freePort(), database = path.join(root, 'catalog.sqlite'), coreRoot = path.join(root, 'core'), templatesFile = path.join(root,'public-templates.json')
const origin = `https://notebook.example.test${nginx ? ':' + port : ''}`, host = new URL(origin).host
let core, web, edge, proxy, certificate, tlsProtocol
const checks = []
function agent() { return spawn(path.resolve(APP, '../../build/sputnik-notebook-remote'), ['--mode','agent','--root',coreRoot,'--worker',path.resolve(APP,'../../build/sputnik-notebook-worker'),'--sputnik',COMPILER], { cwd: APP, stdio, detached: false }) }
function application() { return spawn(path.join(APP,'build/native/notebook-web'), ['--mode','production','--origin',origin,'--port',String(backendPort),'--database',database,'--core-root',coreRoot,'--public-templates',templatesFile,'--behind-proxy','--client-id','unused-local-probe','--client-secret','unused-local-probe','--session-secret',secret,'--csrf-secret',csrf], { cwd: APP, stdio, detached: false }) }
async function until(read, predicate, label, timeout = 30000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) { const value = await read(); if (predicate(value)) return value; await sleep(100) }
  throw new Error('Timed out: ' + label)
}
async function request(route, method = 'GET', data, options = {}) {
  const bytes = data === undefined ? null : Buffer.from(JSON.stringify(data))
  const headers = { Host:host, Accept:'application/json', Origin:origin, ...options.headers }
  const jar = options.jar || cookie
  if (options.auth !== false) headers.Cookie = [...jar].map(([key,value]) => `${key}=${value}`).join('; ')
  if (method !== 'GET' && options.csrf !== false) headers['X-CSRF-Token'] = decodeURIComponent(jar.get('orbit-csrf') || '')
  if (bytes) { headers['Content-Type'] = 'application/json'; headers['Content-Length'] = String(bytes.length) }
  return new Promise((resolve,reject) => {
    const secure = nginx && !options.direct
    const call = (secure ? https : http).request({ hostname:'127.0.0.1',port:options.direct ? backendPort : port,path:route,method,headers,...(secure ? { ca:certificate, servername:'notebook.example.test' } : {}) }, response => {
      if (secure) tlsProtocol = response.socket.getProtocol()
      const chunks=[]; response.on('data',chunk=>chunks.push(chunk)); response.on('end',()=>{
        if (options.auth !== false) for (const value of response.headers['set-cookie'] || []) { const pair=value.split(';')[0], i=pair.indexOf('='); jar.set(pair.slice(0,i),pair.slice(i+1)) }
        const body=Buffer.concat(chunks), text=body.toString('utf8'); let json; try { json=JSON.parse(text) } catch {}
        resolve({ status:response.statusCode,headers:response.headers,body,text,json })
      })
    }); call.setTimeout(15000,()=>call.destroy(new Error('request timeout')));call.on('error',reject);call.end(bytes)
  })
}
async function ready() { await until(async()=>{assert.equal(web.exitCode,null,'main exited');try{return await request('/api/session')}catch{return null}},value=>value?.status===200,'main readiness') }
async function nginxProxy() {
  const key = path.join(root,'key.pem'), cert = path.join(root,'cert.pem'), config = path.join(root,'nginx.conf'), access = path.join(root,'access.log')
  await writeFile(path.join(root,'openssl.cnf'),'[req]\nprompt=no\ndistinguished_name=subject\nx509_extensions=certificate\n[subject]\nCN=notebook.example.test\n[certificate]\nsubjectAltName=DNS:notebook.example.test\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n')
  await run(process.env.NOTEBOOK_WEB_PROBE_OPENSSL || 'openssl',['req','-x509','-newkey','rsa:2048','-sha256','-nodes','-days','1','-config',path.join(root,'openssl.cnf'),'-keyout',key,'-out',cert])
  certificate = await readFile(cert)
  // Exercise the deployable example itself, with only test-owned addresses,
  // certificate/log paths and the current production asset directory substituted.
  const quote = value => '"' + value.replaceAll('\\','\\\\').replaceAll('"','\\"') + '"'
  let example = await readFile(path.join(APP,'deploy/nginx.conf.example'),'utf8')
  for(const [from,to] of [['listen 443 ssl;',`listen 127.0.0.1:${port} ssl;`],['notebook.example.com','notebook.example.test'],['/etc/ssl/notebook/fullchain.pem',quote(cert)],['/etc/ssl/notebook/privkey.pem',quote(key)],['/srv/sputnik-notebook/apps/notebook-web/frontend/dist',quote(await realpath(path.join(APP,'frontend/dist')))],['/var/log/nginx/notebook-access.log',quote(access)],['http://127.0.0.1:3000',`http://127.0.0.1:${backendPort}`]]){
    assert(example.includes(from),'nginx template substitution missing: '+from);example=example.replaceAll(from,to)
  }
  await writeFile(config,`pid ${quote(path.join(root,'nginx.pid'))};\nerror_log ${quote(path.join(root,'nginx-error.log'))};\nevents { worker_connections 128; }\nhttp {\ntypes { text/css css; application/javascript js; application/wasm wasm; }\n${example}\n}\n`)
  await mkdir(path.join(root,'logs'))
  await run(nginx,['-p',root+'/','-c',config,'-t'])
  proxy = spawn(nginx,['-p',root+'/','-c',config,'-g','daemon off; master_process off;'],{cwd:APP,stdio,detached:false})
  return access
}
try {
  // Seed with the same session codec/secret. Its stdout contains a token and is
  // kept only in memory; tokens/secrets never enter the acceptance report/log.
  let seeded
  try { seeded = await run(COMPILER,['run','test/production_seed.s','--grant','ffi','--grant','fs.read','--grant','fs.write','--grant','fs.metadata','--grant','time.now','--grant','random.secure','--','--database',database,'--session-secret',secret],{cwd:APP,env:{...process.env,SPUTNIK_VM_CACHE:path.join(APP,'build/production-seed-cache')}}) } catch (error) { throw new Error('Seed helper failed: '+error.stderr) }
  const account=JSON.parse(seeded.stdout.trim().split('\n').at(-1)), equal=account.cookie.indexOf('=');cookie.set(account.cookie.slice(0,equal),account.cookie.slice(equal+1))
  core=agent();await until(async()=>{try{return await realpath(path.join(coreRoot,'agent.sock'))}catch{return null}},Boolean,'Core socket')
  const publication=await run(COMPILER,['run','tools/public_template.s','--grant','net.connect','--grant','fs.read','--grant','fs.metadata','--grant','ffi','--','--core-root',coreRoot],{cwd:APP,env:{...process.env,SPUTNIK_VM_CACHE:path.join(APP,'build/public-provision-cache')}})
  await writeFile(templatesFile,publication.stdout.trim());web=application()
  const assets=await realpath(path.join(APP,'frontend/dist/assets'))
  let accessLog
  if(nginx) accessLog=await nginxProxy()
  else { edge=http.createServer(async(incoming,outgoing)=>{
    const url=new URL(incoming.url,origin)
    if(url.pathname.startsWith('/assets/')){
      try { const file=await realpath(path.join(assets,decodeURIComponent(url.pathname.slice(8))));if(!file.startsWith(assets+path.sep))throw new Error('outside assets');const data=await readFile(file);outgoing.writeHead(200,{'content-type':file.endsWith('.css')?'text/css':'text/javascript','cache-control':'public, max-age=31536000, immutable','x-content-type-options':'nosniff'});outgoing.end(data) } catch { outgoing.writeHead(404);outgoing.end() }
      return
    }
    if(/^\/(\.vite|\.sputnik|build|db|backend|test|deploy)(\/|$)/.test(url.pathname)){outgoing.writeHead(404);outgoing.end();return}
    const headers={...incoming.headers,host,'x-forwarded-host':host,'x-forwarded-proto':'https','x-forwarded-for':'2001:db8::42',connection:'close'}
    const upstream=http.request({hostname:'127.0.0.1',port:backendPort,path:incoming.url,method:incoming.method,headers},reply=>{outgoing.writeHead(reply.statusCode,reply.headers);reply.pipe(outgoing)})
    upstream.on('error',()=>{outgoing.writeHead(502);outgoing.end()});incoming.pipe(upstream)
  });await new Promise(resolve=>edge.listen(port,'127.0.0.1',resolve)) } await ready()
  const home=await request('/', 'GET',undefined,{auth:false,headers:{Accept:'text/html'}});assert.equal(home.status,200);assert.match(home.text,/notebook-bootstrap/);assert.match(home.headers['content-security-policy'],/object-src 'none'/)
  assert.equal((await request('/api/projects','GET',undefined,{auth:false})).status,401)
  assert.equal((await request('/api/session','GET',undefined,{direct:true})).status,403)
  assert.equal((await request('/api/session','GET',undefined,{headers:{'X-Forwarded-Host':'attacker.invalid','X-Forwarded-Proto':'http'}})).status,200)
  checks.push('production SSR, private API, origin/Host and overwritten forwarded headers')
  const session=await request('/api/session');assert.equal(session.json.account.id,account.account_id)
  assert.equal((await request('/api/projects','POST',{title:'Denied CSRF'},{csrf:false})).status,403)
  const created=await request('/api/projects','POST',{title:'Production acceptance'});assert.equal(created.status,201,created.text);const id=created.json.project.id,base='/api/projects/'+id
  const initial=await request(base+'/notebook','POST',{});assert.equal(initial.status,200,initial.text)
  const doc=JSON.parse(initial.json.notebook.document);doc.version=4;doc.dependencies=[];doc.boards=[];doc.inputs=[];doc.resource_policy={total_run_seconds:60,run_seconds:60,project_bytes:67108864,max_run_bytes:4194304};doc.sheets[0].cells[0].source='import task\ntask.sleep(1800)\n42\n'
  const payload=randomBytes(1200000),saved=await request(base+'/notebook','PUT',{command_id:'production-save',base_revision:initial.json.notebook.revision,document:JSON.stringify(doc),changes:{'resources/payload.bin':{encoding:'base64',data:payload.toString('base64')}}});assert.equal(saved.status,200,saved.text)
  const revision=saved.json.notebook.revision,download=await request(base+'/notebook/download?revision='+revision+'&path=resources/payload.bin');assert.equal(download.status,200);assert.deepEqual(download.body,payload)
  checks.push('seeded signed session, CSRF, real Core save and upload larger than 1 MiB, exact download')
  const manifest=JSON.parse(await readFile(path.join(APP,'frontend/dist/.vite/manifest.json'),'utf8')),asset=await request('/assets/'+manifest['src/main.ts'].file.replace(/^assets\//,''));assert.equal(asset.status,200);assert.match(asset.headers['cache-control'],/immutable/)
  for(const route of ['/.vite/manifest.json','/backend/main.s','/db/migrations/001_accounts_projects.sql','/build/native/notebook-web','/test/production_seed.s'])assert.equal((await request(route)).status,404)
  checks.push('hashed production assets; Vite manifest, source, migrations and test helpers denied')
  const accepted=await request(base+'/execution/runs','POST',{command_id:'production-run',revision,sheet_id:'main',cell_id:'1',action:'run'});assert.equal(accepted.status,200,accepted.text);const runID=accepted.json.run.id
  await until(()=>request(base+'/execution/runs/'+runID),r=>r.status===200&&r.json.run.state==='running','running accepted work')
  await stop(web,false);assert.equal(core.exitCode,null,'web shutdown must not stop Core');web=application();await ready()
  const finished=await until(()=>request(base+'/execution/runs/'+runID),r=>r.status===200&&r.json.run.state==='succeeded','run after main restart');assert.equal(finished.json.run.cells[0].result,'42')
  const replay=await request(base+'/execution/runs','POST',{command_id:'production-run',revision,sheet_id:'main',cell_id:'1',action:'run'});assert.equal(replay.json.run.id,runID)
  const registry=await request(base+'/execution');assert.equal(registry.json.runs.length,1);const resources=await request(base+'/resources');assert.equal(resources.json.resources.effective.total_run_seconds,'60');assert.equal(resources.json.resources.effective.project_bytes,'67108864');const spent=resources.json.resources.spent_ms;assert.ok(BigInt(spent)>0n,'completed work must remain charged')
  checks.push('accepted work survives real main restart; identical command returns same run; cumulative quota retained')
  await stop(core,false);const unavailable=await request(base+'/resources');assert.equal(unavailable.status,503);assert.doesNotMatch(unavailable.text,/\/private\/|agent.sock|core_project_id/)
  core=agent();await until(()=>request(base+'/resources'),r=>r.status===200,'Core restart');const restored=await request(base+'/resources');assert.ok(BigInt(restored.json.resources.spent_ms)>=BigInt(spent));assert.equal((await request(base+'/execution/runs/'+runID)).json.run.state,'succeeded')
  checks.push('Core outage is sanitized; independent restart retains results and charged time')
  const visitor = new Map(), guest = (route,method='GET',data) => request(route,method,data,{jar:visitor})
  assert.equal((await guest('/api/session')).json.account,null)
  const opened=await guest('/api/public/sessions','POST',{template_id:'starter',command_id:'public-open'});assert.equal(opened.status,200,opened.text)
  const publicDay = Math.floor(Date.now() / 86400000)
  const publicBase='/api/public/sessions/'+opened.json.session_id, publicDoc=(await guest(publicBase)).json.notebook
  assert.equal(opened.json.resources.remaining_ms,'60000');assert.equal((await request(publicBase)).status,404,'private account cookie must not own anonymous copy')
  const changed=JSON.parse(publicDoc.document);changed.sheets[0].cells[0].source='import task\ntask.sleep(1800)\n99\n'
  const edited=await guest(publicBase+'/notebook','PUT',{command_id:'public-save',base_revision:publicDoc.revision,document:JSON.stringify(changed)});assert.equal(edited.status,200,edited.text)
  const publicRun=await guest(publicBase+'/runs','POST',{command_id:'public-run',revision:edited.json.notebook.revision,sheet_id:'main',cell_id:'1',action:'run_all'});assert.equal(publicRun.status,200,publicRun.text)
  await stop(web,false);web=application();await ready()
  const publicFinal=await until(()=>guest(publicBase+'/runs/'+publicRun.json.run.id),r=>r.status===200&&r.json.run.state==='succeeded','anonymous run survives HTTP restart')
  assert.equal(publicFinal.json.run.cells[0].result,'99')
  const heartbeat = await guest(publicBase + '/lease', 'POST', { status: true })
  assert.equal(heartbeat.status, 200, heartbeat.text)
  assert.deepEqual(Object.keys(heartbeat.json).sort(), ['lease_seconds', 'renewed', 'resources', 'runs'])
  assert.equal(heartbeat.json.runs.length, 1)
  assert.equal(heartbeat.json.runs[0].id, publicRun.json.run.id)
  assert.equal(heartbeat.json.runs[0].state, 'succeeded')
  const publicResources = heartbeat.json.resources
  const charged = publicResources.spent_ms
  assert.ok(BigInt(charged) > 0n)
  if (Math.floor(Date.now() / 86400000) === publicDay) {
    assert.ok(BigInt(publicResources.ip_remaining_ms) < BigInt(opened.json.resources.ip_remaining_ms))
  }
  await guest(publicBase,'DELETE');await stop(core,false);core=agent();await until(()=>request(base+'/resources'),r=>r.status===200,'Core ready for new public copy')
  const fresh=await guest('/api/public/sessions','POST',{template_id:'starter',command_id:'after-core-restart'});assert.equal(fresh.status,200,fresh.text)
  assert.ok(BigInt(fresh.json.resources.spent_ms)>=BigInt(charged));assert.ok(BigInt(fresh.json.resources.remaining_ms)<60000n);await guest('/api/public/sessions/'+fresh.json.session_id,'DELETE')
  const freshVisitor = new Map()
  await request('/api/session', 'GET', undefined, { jar: freshVisitor })
  const freshCopy = await request('/api/public/sessions', 'POST', { template_id: 'starter', command_id: 'ip-after-restart' },
    { jar: freshVisitor, headers: { 'X-Forwarded-For': '192.0.2.42' } })
  assert.equal(freshCopy.status, 200, freshCopy.text)
  assert.equal(freshCopy.json.resources.spent_ms, '0')
  if (Math.floor(Date.now() / 86400000) === publicDay) {
    assert.equal(freshCopy.json.resources.ip_remaining_ms, publicResources.ip_remaining_ms)
  }
  await request('/api/public/sessions/' + freshCopy.json.session_id, 'DELETE', undefined, { jar: freshVisitor })
  checks.push('anonymous pinned template and ownership, HTTP/Core restart retains cookie and shared IP budgets, proxy replaces client forwarding headers')
  if(nginx){
    const marker='never-log-query-'+randomBytes(12).toString('hex')
    await request('/api/session?code='+marker)
    assert(! (await readFile(accessLog,'utf8')).includes(marker),'OAuth query must not enter the access log')
    const secureSession=await request('/api/session','GET',undefined,{jar:new Map()})
    assert(secureSession.headers['set-cookie'].some(value=>/orbit-session=/.test(value)&&/; Secure(?:;|$)/i.test(value)&&/; HttpOnly(?:;|$)/i.test(value)))
    assert.match(tlsProtocol,/^TLSv1\.[23]$/)
    checks.push('actual nginx -t, verified local TLS, Secure/HttpOnly session and query-free access logs')
  }
  // Offline backup and restore at the original absolute paths. Never relocate
  // Core state: retained revision/bundle records contain absolute member paths.
  await stop(web,false);await stop(core,false)
  const backup=path.join(root,'backup');await mkdir(backup)
  await cp(coreRoot,path.join(backup,'core'),{recursive:true,filter:async source=>!(await lstat(source)).isSocket()})
  const catalogFiles=[]
  for(const suffix of ['','-wal']){try{await lstat(database+suffix);catalogFiles.push(suffix)}catch(error){if(error.code!=='ENOENT'||!suffix)throw error}}
  for(const suffix of catalogFiles)await cp(database+suffix,path.join(backup,'catalog.sqlite'+suffix))
  await rm(coreRoot,{recursive:true});for(const suffix of ['','-wal','-shm'])await rm(database+suffix,{force:true})
  await cp(path.join(backup,'core'),coreRoot,{recursive:true})
  for(const suffix of catalogFiles)await cp(path.join(backup,'catalog.sqlite'+suffix),database+suffix)
  core=agent();await until(async()=>{try{return await realpath(path.join(coreRoot,'agent.sock'))}catch{return null}},Boolean,'restored Core socket');web=application();await ready()
  await until(()=>request(base+'/resources'),r=>r.status===200,'restored Core readiness')
  assert.equal((await request(base+'/execution/runs/'+runID)).json.run.cells[0].result,'42')
  const afterBackup=await guest('/api/public/sessions','POST',{template_id:'starter',command_id:'after-backup'})
  assert.equal(afterBackup.status,200,afterBackup.text);assert.ok(BigInt(afterBackup.json.resources.spent_ms)>=BigInt(charged))
  await guest('/api/public/sessions/'+afterBackup.json.session_id,'DELETE')
  checks.push('offline catalog/Core backup restored at original paths retains signed session, results and anonymous charged time')
  const report={entry:'backend/main.s',backend:'full native',core:'independent full-native agent',origin,transport:nginx?'actual loopback nginx HTTPS with an explicitly trusted ephemeral test certificate':'loopback HTTP with original Host and one-hop HTTPS proxy contract',oauth_provider_contacted:false,authentication:'disposable locally seeded signed session plus an actual anonymous cookie; actual production session middleware',nginx_executed:!!nginx,tls_handshake_tested:!!nginx,tls_protocol:tlsProtocol,external_deployment:false,checks,upload_sha256:createHash('sha256').update(payload).digest('hex'),run_count:1,quota_seconds:60,project_storage_bytes:'67108864'}
  await writeFile(path.join(APP,`build/${variant}.json`),JSON.stringify(report,null,2)+'\n');console.log('PASS '+variant+' acceptance: '+checks.length+' groups')
} finally {
  if(edge){edge.closeAllConnections();await new Promise(resolve=>edge.close(resolve))}await stop(proxy,false);await stop(web,false);await stop(core,false);await log.close();await rm(root,{recursive:true,force:true})
}
