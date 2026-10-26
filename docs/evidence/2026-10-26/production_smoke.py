#!/usr/bin/env python3
"""Exercise the deployed template-enabled worker through the authenticated API."""
import hashlib
import json
from pathlib import Path
import sqlite3
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path('/home/slowpilot/sputnik-remote-core')
RELEASE = Path('/ssd1Tb/sputnik-remote-core-releases/20261026-templates-2622f9d')
STATE = ROOT / 'state'
TOKEN = (STATE / 'token').read_text().strip()
TERMINAL = {'succeeded', 'failed', 'cancelled', 'force-stopped', 'interrupted'}


def request(method, route, body=None):
    req = urllib.request.Request('http://127.0.0.1:18765' + route,
        data=json.dumps(body).encode() if body is not None else None,
        headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + TOKEN},
        method=method)
    try:
        response = urllib.request.urlopen(req, timeout=20)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        result = json.load(response)
        if response.status != 200:
            raise RuntimeError('API status {}: {}'.format(response.status, result))
        return result


def wait(function, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = function()
        if value:
            return value
        time.sleep(.1)
    raise RuntimeError('production smoke timed out')


project = 'template_smoke_' + uuid.uuid4().hex
route = '/v1/projects/' + project
created = False
source = ('from system import cmd\n'
          'values = ["a b", "$(opaque);", ""]\n'
          'command = cmd"""\n'
          '  echo\n'
          '  %for value with_index i in values:\n'
          '    #{i.str}:#{value}\n'
          '  """\n'
          'raise ValueError("template argv changed") unless command.argv == ["echo", "0:a b", "1:$(opaque);", "2:"]\n'
          '42\n')
document = {'format': 'sputnik-notebook', 'version': 1,
    'title': 'Template release smoke', 'active_sheet': 'main', 'modules': [], 'auto_imports': [],
    'sheets': [{'id': 'main', 'title': 'Main', 'cells': [
        {'id': '1', 'kind': 'code', 'source': source, 'mode': 'manual'}]}]}
report = {'project': project, 'release': str(RELEASE)}
try:
    uploaded = request('PUT', route, {'command_id': uuid.uuid4().hex,
        'base_revision': None, 'document': json.dumps(document), 'files': {}})
    created = True
    body = {'command_id': uuid.uuid4().hex, 'revision': uploaded['revision'],
            'sheet_id': 'main', 'cell_id': '1', 'action': 'run'}
    run = request('POST', route + '/runs', body)
    repeated = request('POST', route + '/runs', body)
    assert repeated == run, 'receipt replay changed'

    def terminal():
        value = request('GET', '/v1/runs/' + run['run_id'])
        return value if value['state'] in TERMINAL else None

    result = wait(terminal)
    assert result['state'] == 'succeeded', result
    assert result['result']['cells'][0]['result'] == '42', result
    report.update(run_id=run['run_id'], state=result['state'], result='42',
                  template_argv_preserved=True, receipt_replay_preserved=True)
finally:
    if created:
        request('DELETE', route, {'command_id': uuid.uuid4().hex})
        wait(lambda: request('GET', route)['state'] == 'deleted')
        report['test_project_deleted'] = True
        with sqlite3.connect(str(STATE / 'metadata.sqlite')) as connection:
            remaining = connection.execute(
                "SELECT count(*) FROM runtime_records WHERE project=? AND state NOT IN ('terminated','interrupted')",
                (project,)).fetchone()[0]
        assert remaining == 0, 'smoke runtime was not retired'
        report['test_runtimes_retired'] = True

(RELEASE / 'production-smoke.json').write_text(json.dumps(report, indent=2) + '\n')
build = json.loads((RELEASE / 'build-result.json').read_text())
processes = {}
for mode in ['agent', 'gateway']:
    pid = int((ROOT / (mode + '.pid')).read_text())
    proc = Path('/proc') / str(pid)
    executable = (proc / 'exe').resolve()
    digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    assert executable == RELEASE / 'sputnik-notebook-remote'
    assert digest == build['binaries']['sputnik-notebook-remote']
    processes[mode] = {'pid': pid, 'executable': str(executable), 'sha256': digest}
with sqlite3.connect(str(STATE / 'metadata.sqlite')) as connection:
    quick_check = connection.execute('PRAGMA quick_check').fetchone()[0]
    assert quick_check == 'ok'
final = {'health': request('GET', '/v1/health'), 'processes': processes,
         'sqlite_quick_check': quick_check, 'test_project_deleted': True,
         'test_runtimes_retired': True, 'compiler_sha256': build['binaries']['sputnik'],
         'worker_sha256': build['binaries']['sputnik-notebook-worker']}
(RELEASE / 'final-health.json').write_text(json.dumps(final, indent=2) + '\n')
print(json.dumps({'state': report['state'], 'result': report['result'],
                  'receipt_replay_preserved': True, 'test_project_deleted': True,
                  'test_runtimes_retired': True, 'sqlite_quick_check': quick_check}))
