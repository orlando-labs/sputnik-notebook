#!/usr/bin/env python3
"""Switch a validated, quiescent remote core release; restore the launcher on failure."""
from pathlib import Path
import datetime,hashlib,json,os,signal,sqlite3,subprocess,time,urllib.request
ROOT=Path('/home/slowpilot/sputnik-remote-core')
STATE=ROOT/'state'
RELEASE=Path('/home/slowpilot/sputnik-releases/20261031-lazy-thread-pools')
PREVIOUS=Path('/home/slowpilot/sputnik-releases/20261030-auto-5d291d7')
TERMINAL=('succeeded','failed','cancelled','force-stopped','interrupted')
def digest(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def args(pid):
 try: return [x.decode() for x in (Path('/proc')/str(pid)/'cmdline').read_bytes().split(b'\0') if x]
 except FileNotFoundError: return []
def alive(pid):
 try: return (Path('/proc')/str(pid)/'stat').read_text().split(') ',1)[1].split()[0]!='Z'
 except FileNotFoundError: return False
def owned(mode):
 pid=int((ROOT/(mode+'.pid')).read_text()); command=args(pid)
 if not command or command[0]!=str(PREVIOUS/'sputnik-notebook-remote') or command[command.index('--mode')+1]!=mode or command[command.index('--root')+1]!=str(STATE): raise RuntimeError('unexpected managed process '+mode)
 return pid,command
def stop(pid):
 if alive(pid): os.kill(pid,signal.SIGTERM)
 deadline=time.monotonic()+20
 while alive(pid) and time.monotonic()<deadline: time.sleep(.1)
 if alive(pid): raise RuntimeError('managed process did not stop')
def health():
 request=urllib.request.Request('http://127.0.0.1:18765/v1/health',headers={'Authorization':'Bearer '+(STATE/'token').read_text().strip()})
 with urllib.request.urlopen(request,timeout=3) as response: return json.load(response)
def launch(text):
 tmp=ROOT/'start-current.sh.next';tmp.write_text(text);tmp.chmod(0o700);os.replace(tmp,ROOT/'start-current.sh')
 subprocess.run(['/bin/sh',str(ROOT/'start-current.sh')],check=True)
def wait_health(expected):
 deadline=time.monotonic()+40
 while time.monotonic()<deadline:
  try:
   h=health()
   if Path(os.readlink(Path('/proc')/str(h['agent_pid'])/'exe'))==expected: return h
  except (OSError,ValueError,KeyError): pass
  time.sleep(.2)
 raise RuntimeError('updated service did not become healthy')
manifest=json.loads((RELEASE/'release.json').read_text())
if manifest['checks']!={'language':'passed','vm_and_full_native_ffi':'passed','remote_api':'passed'}: raise RuntimeError('release checks incomplete')
for name,value in manifest['sha256'].items():
 if digest(RELEASE/name)!=value: raise RuntimeError('release hash mismatch '+name)
agent,agent_args=owned('agent');gateway,gateway_args=owned('gateway')
old_text=(ROOT/'start-current.sh').read_text()
if str(PREVIOUS) not in old_text or str(RELEASE) in old_text: raise RuntimeError('unexpected launcher')
new_text=old_text.replace(str(PREVIOUS),str(RELEASE)).replace('agent-'+PREVIOUS.name+'.log','agent-'+RELEASE.name+'.log').replace('gateway-'+PREVIOUS.name+'.log','gateway-'+RELEASE.name+'.log')
limit=os.cpu_count() or 2
position=new_text.index('nohup ')
new_text=new_text[:position]+'export SPUTNIK_TASK_MAX_THREADS='+str(limit)+'\nexport SPUTNIK_FFI_MAX_THREADS='+str(max(4,min(32,limit*2)))+'\n'+new_text[position:]
(RELEASE/'start-proposed.sh').write_text(new_text)
subprocess.run(['/bin/sh','-n',str(RELEASE/'start-proposed.sh')],check=True)
before_health=health();token_digest=digest(STATE/'token')
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
backup=ROOT/'backups'/('before-lazy-thread-pools-'+stamp);backup.mkdir(parents=True,mode=0o700)
(backup/'start-current.sh').write_text(old_text)
(backup/'previous-processes.json').write_text(json.dumps({'agent':agent_args,'gateway':gateway_args},indent=2))
connection=sqlite3.connect(str(STATE/'metadata.sqlite'),timeout=30)
switch_started=False
try:
 connection.execute('BEGIN IMMEDIATE')
 try:
  active=connection.execute('SELECT id,state FROM runs WHERE state NOT IN (?,?,?,?,?)',TERMINAL).fetchall()
  runtimes=connection.execute("SELECT id,state FROM runtime_records WHERE state NOT IN ('terminated','interrupted')").fetchall()
  services=[json.loads(row[0]) for row in connection.execute('SELECT state FROM services')]
  dependencies=connection.execute("SELECT id FROM dependency_jobs WHERE state IN ('queued','running')").fetchall()
  environments=connection.execute("SELECT id FROM foreign_environments WHERE state IN ('queued','installing')").fetchall()
  if active or runtimes or dependencies or environments or any(s.get('enabled') or s.get('running') for s in services): raise RuntimeError('active work; release switch refused')
  projects=connection.execute('SELECT id,head,state FROM projects ORDER BY id').fetchall()
  run_count=connection.execute('SELECT count(*) FROM runs').fetchone()[0]
  switch_started=True
  stop(gateway);stop(agent)
 finally:
  connection.rollback();connection.close()
 with sqlite3.connect(str(STATE/'metadata.sqlite')) as source:
  with sqlite3.connect(str(backup/'metadata.sqlite')) as target: source.backup(target)
 launch(new_text)
 after_health=wait_health(RELEASE/'sputnik-notebook-remote')
 if digest(STATE/'token')!=token_digest: raise RuntimeError('token changed')
 with sqlite3.connect(str(STATE/'metadata.sqlite')) as connection:
  if projects!=connection.execute('SELECT id,head,state FROM projects ORDER BY id').fetchall(): raise RuntimeError('project state changed')
  if run_count!=connection.execute('SELECT count(*) FROM runs').fetchone()[0]: raise RuntimeError('run history changed')
  if connection.execute('PRAGMA quick_check').fetchone()[0]!='ok': raise RuntimeError('SQLite check failed')
 result={'release':str(RELEASE),'backup':str(backup),'before_health':before_health,'health':after_health,'projects_preserved':len(projects),'runs_preserved':run_count,'sqlite_quick_check':'ok','limits':{'SPUTNIK_TASK_MAX_THREADS':limit,'SPUTNIK_FFI_MAX_THREADS':max(4,min(32,limit*2))}}
 (RELEASE/'deploy-result.json').write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps(result,indent=2))
except BaseException:
 if switch_started:
  for mode in ['gateway','agent']:
   try:
    pid=int((ROOT/(mode+'.pid')).read_text())
    if args(pid) and args(pid)[0] in {str(RELEASE/'sputnik-notebook-remote'),str(PREVIOUS/'sputnik-notebook-remote')}: stop(pid)
   except Exception: pass
  launch(old_text)
  wait_health(PREVIOUS/'sputnik-notebook-remote')
 raise
