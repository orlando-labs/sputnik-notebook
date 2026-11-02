from pathlib import Path
import json,os,re,subprocess,time
root=Path('/opt/sputnik-registry')
image='docker.orlando-labs.com/sputnik-registry@sha256:c691db1040a9138f272422f836cb19fc5bb634cf0a9875d1520addbb9778c20a'
backup=Path('/md0/sputnik-registry/backups/before-language-1-20261031')
# The old native backup already verified all 55 immutable artifacts.
subprocess.run(['docker','image','pull',image],check=True)
old=(root/'.env').read_text()
saved=root/'.env.before-language-1-20261031'
if saved.exists():
 if saved.read_text()!=old:raise RuntimeError('configuration changed since snapshot')
else:
 saved.write_text(old);saved.chmod(0o600)
if not re.search(r'^REGISTRY_IMAGE=',old,re.M):raise RuntimeError('missing image setting')
new=re.sub(r'^REGISTRY_IMAGE=.*$', 'REGISTRY_IMAGE='+image,old,flags=re.M)
def write(text):
 tmp=root/'.env.next';tmp.write_text(text);tmp.chmod(0o600);os.replace(tmp,root/'.env')
def up():
 subprocess.run(['docker','compose','up','-d'],cwd=root,check=True)
 deadline=time.monotonic()+120
 while time.monotonic()<deadline:
  ids=subprocess.check_output(['docker','compose','ps','-q','web','worker'],cwd=root,text=True).split()
  if len(ids)==2:
   states=json.loads(subprocess.check_output(['docker','inspect']+ids,text=True))
   if all(c['State']['Running'] and c['State'].get('Health',{}).get('Status','healthy')=='healthy' for c in states):return
  time.sleep(1)
 raise RuntimeError('registry containers did not become ready')
try:
 write(new);up()
 health=json.loads(subprocess.check_output(['docker','compose','exec','-T','web','curl','--fail','--silent','http://127.0.0.1:8080/api/v1/capabilities'],cwd=root,text=True))
 if 'language-semver' not in health['features']:raise RuntimeError('new validator is not running')
 report={'image':image,'backup':str(backup),'previous_env':str(saved),'features':health['features'],'status':'healthy'}
 (root/'deployment-language-1-20261031.json').write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps(report,indent=2))
except BaseException:
 subprocess.run(['docker','compose','logs','--tail','60'],cwd=root)
 write(old);up();raise
