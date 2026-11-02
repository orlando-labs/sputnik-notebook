"""Stage or deploy a validated GPU container while preserving remote-core state."""
import argparse,datetime,hashlib,json,os,shutil,signal,sqlite3,stat,subprocess,time,urllib.request,uuid
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('--phase',choices=['stage','deploy'],required=True)
p.add_argument('--backend',choices=['rocm','cuda'],required=True)
p.add_argument('--release',type=Path,required=True)
p.add_argument('--image',required=True)
a=p.parse_args()
release=a.release;root=Path('/home/slowpilot/sputnik-remote-core');state=root/'state'
terminal=('succeeded','failed','cancelled','force-stopped','interrupted')
def run(cmd,**kw):return subprocess.run(list(map(str,cmd)),check=True,**kw)
def output(cmd):return subprocess.check_output(list(map(str,cmd)),text=True)
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def api(directory,port,method,path,body=None):
 req=urllib.request.Request('http://127.0.0.1:'+str(port)+path,method=method,
  headers={'Authorization':'Bearer '+(directory/'token').read_text().strip(),'Content-Type':'application/json'},
  data=None if body is None else json.dumps(body).encode())
 with urllib.request.urlopen(req,timeout=15) as reply:return json.load(reply)
def ready(directory,port):
 deadline=time.monotonic()+60
 while time.monotonic()<deadline:
  try:return api(directory,port,'GET','/v1/health')
  except (OSError,ValueError):time.sleep(.2)
 raise RuntimeError('container health timed out')
def quiescent(db):
 active=db.execute('SELECT id FROM runs WHERE state NOT IN (?,?,?,?,?)',terminal).fetchall()
 runtimes=db.execute("SELECT id FROM runtime_records WHERE state NOT IN ('terminated','interrupted')").fetchall()
 tables={row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
 jobs=db.execute("SELECT id FROM dependency_jobs WHERE state IN ('queued','running')").fetchall() if 'dependency_jobs' in tables else []
 envs=db.execute("SELECT id FROM foreign_environments WHERE state IN ('queued','installing')").fetchall() if 'foreign_environments' in tables else []
 services=[json.loads(row[0]) for row in db.execute('SELECT state FROM services')] if 'services' in tables else []
 if active or runtimes or jobs or envs or any(s.get('enabled') or s.get('running') for s in services):raise RuntimeError('active work; deployment refused')
def launch(name,directory,port):
 cmd=['python3.12',release/'run-container','--image',a.image,'--name',name,'--backend',a.backend,
  '--state',directory,'--root',state,'--packages',release/'container-packages','--cache',release/'container-cache','--port',port]
 if a.backend=='cuda':cmd+=['--gpu-devices','GPU-08a27f45-3e58-12a9-4626-4997e56e765f,GPU-f8d896e0-2607-a025-88a1-7ed8979035af']
 else:cmd+=['--tensile','/home/slowpilot/sputnik-remote-core/deps/rocblas-gfx906/opt/rocm-6.3.4/lib/rocblas/library']
 run(cmd)
 return ready(directory,port)
def gpu_check(name):
 fixture=release/('registry-rocm-014/installed-check/check.s' if a.backend=='rocm' else 'registry-cuda-014/installed-check/check.s')
 if not fixture.exists():
  fixture=release/'registry-rocm-014/verify/installed.s'
 if not fixture.exists():raise RuntimeError('missing checked GPU fixture')
 run(['docker','cp',fixture,name+':/tmp/sputnik-gpu-check.s'])
 run(['docker','exec','-e','SPUTNIK_NATIVE_CXX=/no/compiler',name,'sputnik','run','/tmp/sputnik-gpu-check.s','--grant','ffi'])
def smoke(directory,port):
 project='container_validation_'+uuid.uuid4().hex
 doc={'format':'sputnik-notebook','version':1,'title':'Container validation','active_sheet':'main',
  'sheets':[{'id':'main','title':'Main','cells':[{'id':'1','kind':'code','source':'40 + 2\n','mode':'manual'}]}],
  'modules':[],'auto_imports':[]}
 uploaded=api(directory,port,'PUT','/v1/projects/'+project,{'command_id':uuid.uuid4().hex,'base_revision':None,'document':json.dumps(doc),'files':{}})
 started=api(directory,port,'POST','/v1/projects/'+project+'/runs',{'command_id':uuid.uuid4().hex,'revision':uploaded['revision'],'sheet_id':'main','cell_id':'1','action':'run'})
 deadline=time.monotonic()+60
 while time.monotonic()<deadline:
  result=api(directory,port,'GET','/v1/runs/'+started['run_id'])
  if result['state'] in terminal:break
  time.sleep(.1)
 assert result['state']=='succeeded',result
 assert result['result']['cells'][0]['result']=='42',result
 api(directory,port,'DELETE','/v1/projects/'+project,{'command_id':uuid.uuid4().hex})
 return started['run_id']
def owned(mode):
 pid=int((root/(mode+'.pid')).read_text())
 command=(Path('/proc')/str(pid)/'cmdline').read_bytes().split(b'\0')
 assert b'--mode' in command and command[command.index(b'--mode')+1]==mode.encode()
 assert b'--root' in command and command[command.index(b'--root')+1]==str(state).encode()
 assert str((root/'current').resolve()).encode() in command[0]
 return pid
def alive(pid):
 try:return (Path('/proc')/str(pid)/'stat').read_text().split(') ',1)[1].split()[0]!='Z'
 except FileNotFoundError:return False
def stop(pid):
 os.kill(pid,signal.SIGTERM)
 deadline=time.monotonic()+25
 while alive(pid) and time.monotonic()<deadline:time.sleep(.1)
 if alive(pid):raise RuntimeError('bare service did not stop')

if a.phase=='stage':
 stage=release/'container-stage-state'
 with sqlite3.connect(str(state/'metadata.sqlite')) as db:quiescent(db)
 def ignored(path,names):return [n for n in names if stat.S_ISSOCK(os.lstat(Path(path)/n).st_mode) or n in ['metadata.sqlite','metadata.sqlite-wal','metadata.sqlite-shm']]
 if not stage.exists():shutil.copytree(state,stage,ignore=ignored)
 with sqlite3.connect(str(state/'metadata.sqlite')) as source:
  with sqlite3.connect(str(stage/'metadata.sqlite')) as target:source.backup(target)
 name='sputnik-remote-core-stage'
 health=launch(name,stage,18766)
 run(['docker','exec',name,'sputnik','pkg','install','slowpilot/torch','--version','0.1.4','--backend',a.backend,'--bundle','runtime','--allow-native','--allow-native-large'])
 gpu_check(name)
 run_id=smoke(stage,18766);token=sha(stage/'token')
 run(['docker','restart',name]);ready(stage,18766)
 assert sha(stage/'token')==token
 assert api(stage,18766,'GET','/v1/runs/'+run_id)['state']=='succeeded'
 run(['docker','stop',name]);run(['docker','rm',name])
 report={'image':a.image,'backend':a.backend,'gpu':'passed','api':'passed','restart':'passed','token_preserved':True}
 (release/'container-stage-result.json').write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps(report,indent=2))
else:
 checked=json.loads((release/'container-stage-result.json').read_text())
 assert checked['image']==a.image and checked['backend']==a.backend and checked['gpu']=='passed'
 agent=owned('agent');gateway=owned('gateway');old=(root/'start-current.sh').read_text();previous=(root/'current').resolve()
 backup=root/'backups'/('before-docker-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
 backup.mkdir(mode=0o700);(backup/'start-current.sh').write_text(old)
 token=sha(state/'token');switched=False
 try:
  with sqlite3.connect(str(state/'metadata.sqlite'),timeout=30) as db:
   db.execute('BEGIN IMMEDIATE');quiescent(db)
   projects=db.execute('SELECT id,head,state FROM projects ORDER BY id').fetchall()
   count=db.execute('SELECT count(*) FROM runs').fetchone()[0]
   switched=True;stop(gateway);stop(agent);db.rollback()
  with sqlite3.connect(str(state/'metadata.sqlite')) as source:
   with sqlite3.connect(str(backup/'metadata.sqlite')) as target:source.backup(target)
  health=launch('sputnik-remote-core',state,18765)
  assert sha(state/'token')==token
  with sqlite3.connect(str(state/'metadata.sqlite')) as db:
   assert projects==db.execute('SELECT id,head,state FROM projects ORDER BY id').fetchall()
   assert count==db.execute('SELECT count(*) FROM runs').fetchone()[0]
   assert db.execute('PRAGMA quick_check').fetchone()[0]=='ok'
  gpu_check('sputnik-remote-core')
  launcher='#!/bin/sh\nset -eu\ndocker start sputnik-remote-core >/dev/null\n'
  temp=root/'start-current.sh.next';temp.write_text(launcher);temp.chmod(0o700);os.replace(temp,root/'start-current.sh')
  report={'image':a.image,'backend':a.backend,'backup':str(backup),'health':health,'projects_preserved':len(projects),'runs_preserved':count,'token_preserved':True,'gpu':'passed','sqlite_quick_check':'ok','previous_toolchain':str(previous)}
  (release/'container-deploy-result.json').write_text(json.dumps(report,indent=2)+'\n')
  print(json.dumps(report,indent=2))
 except BaseException:
  if switched:
   subprocess.run(['docker','rm','-f','sputnik-remote-core'])
   if (backup/'metadata.sqlite').exists():
    for suffix in ['', '-wal', '-shm']:
     path=state/('metadata.sqlite'+suffix)
     if path.exists():path.unlink()
    shutil.copy2(backup/'metadata.sqlite',state/'metadata.sqlite')
   (root/'start-current.sh').write_text(old);run(['/bin/sh',root/'start-current.sh']);ready(state,18765)
  raise
