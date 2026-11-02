from pathlib import Path
import os,json,socket,sqlite3,hashlib
base=Path('/home/slowpilot/sputnik-remote-core');release=(base/'current').resolve(strict=True);root=base/'state'
with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
    s.settimeout(5);s.connect(str(root/'agent.sock'));s.sendall(b'{"method":"health","params":{}}\n')
    response=json.loads(s.makefile('rb').readline());assert response['status']==200,response
report={'release':str(release),'health':response['data'],'processes':{}}
for name in ['agent','gateway']:
    pid=int((base/(name+'.pid')).read_text());exe=os.readlink('/proc/'+str(pid)+'/exe')
    assert exe==str(release/'sputnik-notebook-remote')
    paths=sorted({line.split()[-1] for line in (Path('/proc')/str(pid)/'maps').read_text().splitlines() if 'libpcre2' in line})
    assert paths and all('/sputnik-remote-core/deps/pcre2-10.47/' in path for path in paths)
    report['processes'][name]={'pid':pid,'executable':exe,'pcre2_libraries':paths}
with sqlite3.connect(f'file:{root}/metadata.sqlite?mode=ro',uri=True) as c:
    report['sqlite_quick_check']=c.execute('pragma quick_check').fetchone()[0]
    assert report['sqlite_quick_check']=='ok'
    report['active_runs']=c.execute("select count(*) from runs where state not in ('succeeded','failed','cancelled','force-stopped','interrupted')").fetchone()[0]
report['token_mode']=oct((root/'token').stat().st_mode & 0o777)
assert report['token_mode']=='0o600'
manifest=json.loads((release/'release.json').read_text())
report['language_commit']=manifest['language_commit'];report['binary_hashes_verified']=True
for name,digest in manifest['sha256'].items():
    assert hashlib.sha256((release/name).read_bytes()).hexdigest()==digest,name
(release/'final-health.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
