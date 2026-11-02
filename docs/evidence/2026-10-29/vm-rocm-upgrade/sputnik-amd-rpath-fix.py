from pathlib import Path
import os,json,sqlite3,subprocess,signal,time,shutil,hashlib,socket
base=Path('/home/slowpilot/sputnik-remote-core');r=(base/'current').resolve();root=base/'state';pcre=base/'deps/pcre2-10.47/lib'
assert r.name=='20261029-head-3eb0f05'
backup=r/'rpath-original';backup.mkdir(mode=0o700)
shutil.copy2(r/'release.json',backup/'release.json')
report={'pcre2':str(pcre),'binaries':{}}
con=sqlite3.connect(str(root/'metadata.sqlite'),timeout=15);con.execute('begin immediate')
assert con.execute("select count(*) from runs where state not in ('succeeded','failed','cancelled','force-stopped','interrupted')").fetchone()[0]==0
assert con.execute("select count(*) from runtime_records where state not in ('terminated','interrupted')").fetchone()[0]==0
assert con.execute("select count(*) from dependency_jobs where state in ('queued','running')").fetchone()[0]==0
for name in ['gateway','agent']:
    pid=int((base/(name+'.pid')).read_text());assert os.readlink('/proc/'+str(pid)+'/exe')==str(r/'sputnik-notebook-remote')
    os.kill(pid,signal.SIGTERM);deadline=time.monotonic()+15
    while (Path('/proc')/str(pid)).exists() and time.monotonic()<deadline:
        if (Path('/proc')/str(pid)/'stat').read_text().split()[2]=='Z':break
        time.sleep(.05)
    assert not (Path('/proc')/str(pid)).exists() or (Path('/proc')/str(pid)/'stat').read_text().split()[2]=='Z'
con.commit();con.close()
with sqlite3.connect(str(root/'metadata.sqlite')) as src,sqlite3.connect(str(backup/'metadata.sqlite')) as dst:src.backup(dst)
(backup/'metadata.sqlite').chmod(0o600)
names=['sputnik-notebook-remote','sputnik-notebook-worker','src/sputnik-lang/build/sputnik','src/sputnik-lang/build/isputnik','src/sputnik-notebook/build/sputnik-notebook-remote','src/sputnik-notebook/build/sputnik-notebook-worker']
try:
    for index,name in enumerate(names):
        path=r/name;shutil.copy2(path,backup/str(index))
        old=subprocess.check_output(['patchelf','--print-rpath',str(path)],text=True).strip()
        new=':'.join([str(pcre)]+[v for v in old.split(':') if v and v!=str(pcre)])
        staged=path.with_name(path.name+'.pcre-next');shutil.copy2(path,staged)
        subprocess.check_call(['patchelf','--force-rpath','--set-rpath',new,str(staged)]);os.replace(staged,path)
        report['binaries'][name]={'old_rpath':old,'new_rpath':new}
    cxx=r/'cxx';shutil.copy2(cxx,backup/'cxx');cxx.write_text(cxx.read_text().replace('-Wl,-rpath,/usr/lib64 ',''));cxx.chmod(0o755)
    manifest_path=r/'release.json';manifest=json.loads(manifest_path.read_text())
    for name in manifest['sha256']:manifest['sha256'][name]=hashlib.sha256((r/name).read_bytes()).hexdigest()
    manifest['pcre2_rpath_corrected']=True;manifest_path.write_text(json.dumps(manifest,indent=2)+'\n')
    subprocess.check_call(['sh',str(base/'start-current.sh')])
    deadline=time.monotonic()+30
    while True:
        try:
            with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
                s.settimeout(2);s.connect(str(root/'agent.sock'));s.sendall(b'{"method":"health","params":{}}\n')
                health=json.loads(s.makefile('rb').readline());assert health['status']==200
            break
        except (OSError,AssertionError,ValueError):
            assert time.monotonic()<deadline
            time.sleep(.1)
    report['health']=health['data'];(r/'rpath-fix.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
except BaseException:
    for role in ['gateway','agent']:
        try:
            pid=int((base/(role+'.pid')).read_text())
            if os.readlink('/proc/'+str(pid)+'/exe').removesuffix(' (deleted)')==str(r/'sputnik-notebook-remote'):
                os.kill(pid,signal.SIGTERM)
                for attempt in range(150):
                    if not (Path('/proc')/str(pid)).exists() or (Path('/proc')/str(pid)/'stat').read_text().split()[2]=='Z':break
                    time.sleep(.1)
        except FileNotFoundError:pass
    for index,name in enumerate(names):
        if (backup/str(index)).exists():shutil.copy2(backup/str(index),r/name)
    if (backup/'cxx').exists():shutil.copy2(backup/'cxx',r/'cxx')
    shutil.copy2(backup/'release.json',r/'release.json')
    subprocess.check_call(['sh',str(base/'start-current.sh')]);raise
