from pathlib import Path
import os,json,sqlite3,hashlib,datetime,subprocess,time,signal,socket,shutil
base=Path('/home/slowpilot/sputnik-remote-core')
release=Path('/ssd1Tb/sputnik-remote-core-releases/20261029-membership')
previous=Path('/ssd1Tb/sputnik-remote-core-releases/20261028-regexp-77650e1')
root=base/'state'
assert (base/'current').resolve()==previous,'production changed since preparation'
assert 'BUILD_COMPLETE' in (release/'build.log').read_text()
assert 'TESTS_COMPLETE' in (release/'tests.log').read_text(),'Linux checks have not passed'
manifest=json.loads((release/'release.json').read_text())
assert manifest['language_commit']=='7f2665b8d1538bf6b4667920cafe752d676d8782'
for name,digest in manifest['sha256'].items():
    assert hashlib.sha256((release/name).read_bytes()).hexdigest()==digest,name
def alive(pid):
    try:return (Path('/proc')/str(pid)/'stat').read_text().split()[2]!='Z'
    except FileNotFoundError:return False
def owned(pid,name):
    if not alive(pid):return False
    exe=os.readlink('/proc/'+str(pid)+'/exe')
    args=(Path('/proc')/str(pid)/'cmdline').read_bytes().split(b'\0')
    return exe in [str(p/'sputnik-notebook-remote') for p in [previous,release]] and name.encode() in args and str(root).encode() in args
def terminate(pid,name):
    if alive(pid):
        assert owned(pid,name),'unexpected process identity '+str(pid)
        os.kill(pid,signal.SIGTERM)
    deadline=time.monotonic()+15
    while alive(pid) and time.monotonic()<deadline:time.sleep(.05)
    assert not alive(pid),'process failed to stop '+str(pid)
def health():
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
        s.settimeout(5);s.connect(str(root/'agent.sock'));s.sendall(b'{"method":"health","params":{}}\n')
        result=json.loads(s.makefile('rb').readline());assert result['status']==200,result
        return result['data']
def fingerprint(conn):
    result={}
    for table in ['projects','revisions','runs','receipts','runtime_records','services']:
        rows=conn.execute('select * from '+table+' order by 1,2').fetchall()
        result[table]={'count':len(rows),'sha256':hashlib.sha256(json.dumps(rows,ensure_ascii=False,sort_keys=True).encode()).hexdigest()}
    return result
def set_current(target):
    staged=base/('current.next.'+str(os.getpid()))
    os.symlink(str(target),str(staged));os.replace(str(staged),str(base/'current'))
start=base/'start-current.sh'
old_start=start.read_bytes();old_current=os.readlink(str(base/'current'))
new_start=old_start.decode().replace(str(previous),str(release)).replace('20261026-templates-2622f9d.log','20261029-membership.log')
assert str(release/'env.sh') in new_start and str(previous) not in new_start
staged=base/('start-current.next.'+str(os.getpid()));staged.write_text(new_start);staged.chmod(0o700)
subprocess.check_call(['sh','-n',str(staged)])
pids={name:int((base/(name+'.pid')).read_text()) for name in ['agent','gateway']}
for name,pid in pids.items():
    assert owned(pid,name) and os.readlink('/proc/'+str(pid)+'/exe')==str(previous/'sputnik-notebook-remote')
report={'release':str(release),'language_commit':manifest['language_commit'],'previous_health':health()}
backup=base/'backups'/('before-membership-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
backup.mkdir(mode=0o700);report['backup']=str(backup)
(backup/'start-current.sh').write_bytes(old_start);(backup/'start-current.sh').chmod(0o700)
(backup/'release.json').write_text(json.dumps({'previous':str(previous),'current_symlink':old_current,'pids':pids},indent=2)+'\n')
shutil.copy2(root/'token',backup/'token');(backup/'token').chmod(0o600)
token_digest=hashlib.sha256((root/'token').read_bytes()).hexdigest()
connection=sqlite3.connect(str(root/'metadata.sqlite'),timeout=15)
stopped=False
try:
    connection.execute('begin immediate')
    active=connection.execute("select count(*) from runs where state not in ('succeeded','failed','cancelled','force-stopped','interrupted')").fetchone()[0]
    live=connection.execute("select count(*) from runtime_records where state not in ('terminated','interrupted')").fetchone()[0]
    services=[json.loads(r[0]) for r in connection.execute('select state from services')]
    assert not active and not live and not any(s.get('enabled') or s.get('running') for s in services),('active work found',active,live)
    report.update(active_runs_interrupted=0,idle_runtimes_reset=0,enabled_services_interrupted=0)
    before=fingerprint(connection)
    (backup/'metadata.sql').write_text('\n'.join(connection.iterdump())+'\n');(backup/'metadata.sql').chmod(0o600)
    terminate(pids['gateway'],'gateway');stopped=True
    terminate(pids['agent'],'agent')
    connection.commit();connection.close()
    with sqlite3.connect(str(root/'metadata.sqlite')) as source:
        with sqlite3.connect(str(backup/'metadata.sqlite')) as destination:source.backup(destination)
    (backup/'metadata.sqlite').chmod(0o600)
    os.replace(str(staged),str(start));set_current(release)
    subprocess.check_call(['sh',str(start)])
    deadline=time.monotonic()+30
    while True:
        try:
            current=health()
            if current['agent_pid']!=pids['agent']:break
        except (OSError,AssertionError,ValueError):pass
        assert time.monotonic()<deadline,'new agent startup failed'
        time.sleep(.1)
    subprocess.check_call(['/usr/bin/python3.12',str(base/'transfer/sputnik-membership-production-smoke.py')])
    with sqlite3.connect(str(root/'metadata.sqlite')) as c,sqlite3.connect(str(backup/'metadata.sqlite')) as original:
        for table in ['projects','revisions','runs','receipts','runtime_records','services']:
            info=original.execute('pragma table_info('+table+')').fetchall()
            columns=[r[1] for r in info];pk=[r[1] for r in sorted(info,key=lambda r:r[5]) if r[5]] or columns
            for row in original.execute('select * from '+table):
                where=' and '.join('"'+key+'" is ?' for key in pk)
                actual=c.execute('select * from '+table+' where '+where,[row[columns.index(key)] for key in pk]).fetchone()
                if table=='services':
                    assert actual is not None and row[:2]==actual[:2]
                    old=json.loads(row[2]);new=json.loads(actual[2])
                    for key in ['enabled','running','next_at','status']:
                        old.pop(key,None);new.pop(key,None)
                    assert old==new,'service configuration/history changed'
                else:assert tuple(row)==actual,'pre-existing '+table+' row changed'
        report.update(health=current,metadata_preserved=True,token_preserved=token_digest==hashlib.sha256((root/'token').read_bytes()).hexdigest(),sqlite_quick_check=c.execute('pragma quick_check').fetchone()[0],before=before,after=fingerprint(c))
    assert report['token_preserved'] and report['sqlite_quick_check']=='ok'
    report['processes']={}
    for name in ['agent','gateway']:
        pid=int((base/(name+'.pid')).read_text());assert owned(pid,name)
        exe=os.readlink('/proc/'+str(pid)+'/exe');assert exe==str(release/'sputnik-notebook-remote')
        report['processes'][name]={'pid':pid,'executable':exe}
    (release/'deploy-result.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
except BaseException:
    try:connection.rollback();connection.close()
    except sqlite3.Error:pass
    if stopped:
        for name in ['gateway','agent']:
            terminate(int((base/(name+'.pid')).read_text()),name)
        start.write_bytes(old_start);start.chmod(0o700);set_current(old_current)
        subprocess.check_call(['sh',str(start)])
        print('ROLLED_BACK_TO '+str(previous),flush=True)
    raise
finally:
    if staged.exists():staged.unlink()
