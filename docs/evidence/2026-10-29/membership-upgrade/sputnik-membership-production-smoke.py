from pathlib import Path
import json,time,urllib.request,urllib.error,uuid,os
base=Path('/home/slowpilot/sputnik-remote-core')
release=Path('/ssd1Tb/sputnik-remote-core-releases/20261029-membership')
token=(base/'state/token').read_text().strip()
origin='http://127.0.0.1:18765'
project='membership_upgrade_'+uuid.uuid4().hex[:12]
def request(method,route,body=None):
    raw=json.dumps(body,ensure_ascii=False).encode() if body is not None else None
    req=urllib.request.Request(origin+route,data=raw,method=method,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
    try:
        with urllib.request.urlopen(req,timeout=30) as r:return r.status,json.loads(r.read().decode())
    except urllib.error.HTTPError as e:raise RuntimeError(str(e.code)+' '+e.read().decode())
source=(base/'transfer/sputnik-membership-smoke-source.txt').read_text()
doc={'format':'sputnik-notebook','version':1,'title':'Membership upgrade smoke','active_sheet':'main','sheets':[{'id':'main','title':'Smoke','cells':[{'id':'1','kind':'code','source':source,'mode':'manual'}]}],'modules':[],'auto_imports':[]}
report={'project':project,'origin':origin,'language_commit':'7f2665b8d1538bf6b4667920cafe752d676d8782'}
created=False
try:
    deadline=time.monotonic()+15
    while True:
        try:
            _,report['health']=request('GET','/v1/health');break
        except (OSError,RuntimeError):
            assert time.monotonic()<deadline,'gateway readiness timeout'
            time.sleep(.1)
    _,upload=request('PUT','/v1/projects/'+project,{'command_id':uuid.uuid4().hex,'base_revision':None,'document':json.dumps(doc,ensure_ascii=False),'files':{}})
    created=True;report['revision']=upload['revision']
    body={'command_id':uuid.uuid4().hex,'revision':upload['revision'],'sheet_id':'main','cell_id':'1','action':'run'}
    _,accepted=request('POST','/v1/projects/'+project+'/runs',body)
    report['run_id']=accepted['run_id']
    deadline=time.monotonic()+60
    while True:
        _,result=request('GET','/v1/runs/'+accepted['run_id'])
        if result['state'] in ['succeeded','failed','cancelled','force-stopped','interrupted']:break
        assert time.monotonic()<deadline,'production smoke timeout'
        time.sleep(.1)
    assert result['state']=='succeeded',result
    assert result['result']['cells'][0]['result']=='42',result
    _,replay=request('POST','/v1/projects/'+project+'/runs',body)
    assert replay==accepted,(accepted,replay)
    report.update(state=result['state'],result=result['result']['cells'][0]['result'],receipt_replay_same_run=True,runtime_id=result.get('runtime_id'),epoch=result.get('epoch'))
finally:
    if created:
        request('DELETE','/v1/projects/'+project,{'command_id':uuid.uuid4().hex})
        deadline=time.monotonic()+30
        while True:
            _,state=request('GET','/v1/projects/'+project)
            if state['state']=='deleted':break
            assert time.monotonic()<deadline,'smoke project deletion timeout'
            time.sleep(.1)
        report['smoke_project_deleted']=True
(release/'production-smoke.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
print(json.dumps(report,ensure_ascii=False))
