import base64, json, os, pathlib, signal, socket, sqlite3, subprocess, tempfile, time, uuid

REPO = pathlib.Path(__file__).resolve().parents[4]
TEMP = pathlib.Path(tempfile.mkdtemp(prefix='notebook-release-audit-', dir='/tmp'))
ROOT = TEMP / 'state'
LOG = (TEMP / 'agent.log').open('wb')
agent = subprocess.Popen([str(REPO/'build/sputnik-notebook-remote'), '--mode', 'agent', '--root', str(ROOT), '--worker', str(REPO/'build/sputnik-notebook-worker'), '--sputnik', str(REPO.parent/'sputnik-lang/build/sputnik')], stdout=LOG, stderr=LOG)
def rpc(method, **params):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(20); s.connect(str(ROOT/'agent.sock'))
        s.sendall((json.dumps(dict(method=method, params=params))+'\n').encode())
        with s.makefile('rb') as f: return json.loads(f.readline())
def call(method, **params):
    value = rpc(method, **params)
    assert value['status'] == 200, value
    return value['data']
def wait(f, timeout=20):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        value=f()
        if value: return value
        time.sleep(.05)
    raise AssertionError('timeout')
def cmd(): return uuid.uuid4().hex
def doc(source):
    return dict(format='sputnik-notebook',version=1,title='Audit',active_sheet='main',sheets=[dict(id='main',title='Main',cells=[dict(id='1',kind='code',source=source,mode='manual')])],modules=[],auto_imports=[])
def upload(project, document, files=None):
    return call('project.put',project_id=project,command_id=cmd(),base_revision=None,document=json.dumps(document),files={k:base64.b64encode(v.encode()).decode() for k,v in (files or {}).items()})['revision']
def terminal(run):
    r=call('run.get',run_id=run)
    return r if r['state'] in ['succeeded','failed','cancelled','force-stopped','interrupted'] else None
try:
    wait(lambda: (ROOT/'agent.sock').exists())
    marker=TEMP/'child-finished'
    started=TEMP/'child-started'
    script=f'echo ready > {started}; sleep 4; echo STILL_RUNNING > {marker}'
    revision=upload('force',doc('system.command("/bin/sh", "-c", '+json.dumps(script)+').capture(timeout: 30.0)\n42\n'))
    settings=call('worker.settings',project_id='force',sheet_id='main')
    call('worker.configure',project_id='force',sheet_id='main',command_id=cmd(),base_version=settings['version'],runtime_epoch=None,grants=['process.spawn=/bin/sh'])
    run=call('run.start',project_id='force',command_id=cmd(),revision=revision,sheet_id='main',cell_id='1')
    wait(started.exists)
    call('run.stop',run_id=run['run_id'],runtime_epoch=run['runtime_epoch'],command_id=cmd(),force=True)
    stopped=wait(lambda: terminal(run['run_id']))
    print(json.dumps(dict(test='force_stop',terminal_state=stopped['state'],child_finished_at_stop=marker.exists())),flush=True)
    time.sleep(4.5)
    print(json.dumps(dict(test='force_stop_after_4_seconds',child_continued_after_stop=marker.exists())),flush=True)

    document=doc('raise ValueError("boom")\nx = 40\n')
    document['sheets'][0]['cells'].append(dict(id='2',kind='code',source='x + 2\n',mode='manual'))
    revision=upload('failure',document)
    run=call('run.start',project_id='failure',command_id=cmd(),revision=revision,sheet_id='main',cell_id='2')
    result=wait(lambda:terminal(run['run_id']))
    print(json.dumps(dict(test='dependency_failure',state=result['state'],result=result['result'])),flush=True)

    document=doc('42\n');document['version']=2;document['inputs']=[]
    document['modules']=[dict(id='jobs',path='modules/jobs.s')]
    document['boards']=[dict(id='board',title='Board',sheet='main',columns=1,components=[dict(id='timer',kind='periodic_work',title='Timer',module_id='jobs',function='tick',period_seconds=1.0,run_immediately=False,retention='none')])]
    revision=upload('service',document,{'modules/jobs.s':'package jobs\ndef tick(): 42\nexport tick\n'})
    call('service.configure',project_id='service',revision=revision,board_id='board',component_id='timer',operation='start',command_id=cmd())
    db=sqlite3.connect(ROOT/'metadata.sqlite');db.execute('BEGIN IMMEDIATE')
    time.sleep(7)
    db.rollback();db.close()
    time.sleep(.5)
    services=call('service.list',project_id='service')
    runs=call('run.registry',project_id='service')
    restart=rpc('service.configure',project_id='service',revision=revision,board_id='board',component_id='timer',operation='start',command_id=cmd())
    print(json.dumps(dict(test='periodic_sqlite_busy',services=services,runs=runs['runs'],restart=restart)),flush=True)
finally:
    agent.terminate()
    try: agent.wait(10)
    except subprocess.TimeoutExpired: agent.kill();agent.wait()
    LOG.close()
    print('state: '+str(TEMP),flush=True)
