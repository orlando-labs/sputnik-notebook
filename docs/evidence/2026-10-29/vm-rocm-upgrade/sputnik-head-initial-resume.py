from pathlib import Path
import os,json,subprocess,socket,time,urllib.request
base=Path('/home/slowpilot/sputnik-remote-core');release=Path('/home/slowpilot/sputnik-releases/20261029-head-3eb0f05');root=base/'state'
assert (base/'current').resolve()==release
assert 'TORCH_TESTS_COMPLETE' in (release/'torch-tests.log').read_text()
for name in ['agent','gateway']:
    pid=int((base/(name+'.pid')).read_text())
    try:assert (Path('/proc')/str(pid)/'stat').read_text().split()[2]=='Z','previous process still alive'
    except FileNotFoundError:pass
start=base/'start-current.sh';script=start.read_text()
wait=f'''startup_attempt=0
while test ! -s {root}/token; do
  startup_attempt=$((startup_attempt + 1))
  test "$startup_attempt" -lt 100 || exit 1
  kill -0 $(cat {base}/agent.pid) || exit 1
  sleep 0.1
done
'''
needle=f'nohup {release}/sputnik-notebook-remote --mode gateway'
assert needle in script
if 'startup_attempt=0' not in script:script=script.replace(needle,wait+needle)
start.write_text(script);start.chmod(0o700);subprocess.check_call(['sh','-n',str(start)])
subprocess.check_call(['sh',str(start)])
deadline=time.monotonic()+30
while True:
    try:
        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
            s.settimeout(2);s.connect(str(root/'agent.sock'));s.sendall(b'{"method":"health","params":{}}\n')
            response=json.loads(s.makefile('rb').readline());assert response['status']==200,response
        req=urllib.request.Request('http://127.0.0.1:18765/v1/health',headers={'Authorization':'Bearer '+(root/'token').read_text().strip()})
        with urllib.request.urlopen(req,timeout=2) as http:assert http.status==200
        break
    except (OSError,AssertionError,ValueError):
        assert time.monotonic()<deadline,'startup readiness timeout'
        time.sleep(.1)
manifest=json.loads((release/'release.json').read_text())
report={'release':str(release),'language_commit':manifest['language_commit'],'torch_commit':manifest['torch_commit'],'health':response['data'],'processes':{},'gateway_ready':True,'first_start_token_race_fixed':True}
for name in ['agent','gateway']:
    pid=int((base/(name+'.pid')).read_text());exe=os.readlink('/proc/'+str(pid)+'/exe');assert exe==str(release/'sputnik-notebook-remote')
    report['processes'][name]={'pid':pid,'executable':exe}
(release/'deploy-result.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
