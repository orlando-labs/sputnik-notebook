from pathlib import Path
import os,json,hashlib,subprocess,socket,time,signal
base=Path('/home/slowpilot/sputnik-remote-core')
release=Path('/home/slowpilot/sputnik-releases/20261029-head-3eb0f05')
root=base/'state'
assert not (base/'current').exists() and not (base/'current').is_symlink(),'existing install must use a state-preserving upgrade'
assert 'BUILD_COMPLETE' in (release/'build.log').read_text()
assert 'TESTS_COMPLETE' in (release/'tests.log').read_text()
assert 'TORCH_TESTS_COMPLETE' in (release/'torch-tests.log').read_text()
manifest=json.loads((release/'release.json').read_text())
assert manifest['language_commit']=='3eb0f05da50ba307d5f719e0b194de6317304b29'
for name,digest in manifest['sha256'].items():
    assert hashlib.sha256((release/name).read_bytes()).hexdigest()==digest,name
root.mkdir(mode=0o700)
script=f'''#!/bin/sh
set -eu
. {release}/env.sh
export LD_LIBRARY_PATH=/usr/local/lib64/python3.12/site-packages/torch/lib:${{LD_LIBRARY_PATH:-}}
nohup {release}/sputnik-notebook-remote --mode agent --root {root} --worker {release}/sputnik-notebook-worker --sputnik {release}/src/sputnik-lang/build/sputnik >{base}/agent-20261029-head-3eb0f05.log 2>&1 </dev/null &
echo $! >{base}/agent.pid
nohup {release}/sputnik-notebook-remote --mode gateway --root {root} --port 18765 >{base}/gateway-20261029-head-3eb0f05.log 2>&1 </dev/null &
echo $! >{base}/gateway.pid
'''
start=base/'start-current.sh';start.write_text(script);start.chmod(0o700)
subprocess.check_call(['sh','-n',str(start)])
os.symlink(str(release),str(base/'current'))
subprocess.check_call(['sh',str(start)])
try:
    deadline=time.monotonic()+30
    while True:
        try:
            with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
                s.settimeout(2);s.connect(str(root/'agent.sock'));s.sendall(b'{"method":"health","params":{}}\n')
                health=json.loads(s.makefile('rb').readline());assert health['status']==200,health
            break
        except (OSError,AssertionError,ValueError):
            assert time.monotonic()<deadline,'agent readiness timeout'
            time.sleep(.1)
    report={'release':str(release),'language_commit':manifest['language_commit'],'health':health,'processes':{}}
    for name in ['agent','gateway']:
        pid=int((base/(name+'.pid')).read_text());exe=os.readlink('/proc/'+str(pid)+'/exe')
        assert exe==str(release/'sputnik-notebook-remote')
        report['processes'][name]={'pid':pid,'executable':exe}
    (release/'deploy-result.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
except BaseException:
    for name in ['gateway','agent']:
        pid=int((base/(name+'.pid')).read_text())
        try:
            if os.readlink('/proc/'+str(pid)+'/exe')==str(release/'sputnik-notebook-remote'):os.kill(pid,signal.SIGTERM)
        except FileNotFoundError:pass
    raise
