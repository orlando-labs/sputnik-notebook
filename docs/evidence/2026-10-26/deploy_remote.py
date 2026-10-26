#!/usr/bin/env python3
"""Quiescent release switch; refuses active work and preserves rollback inputs."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import sqlite3
import subprocess
import time
import urllib.request

ROOT = Path('/home/slowpilot/sputnik-remote-core')
RELEASE = Path('/ssd1Tb/sputnik-remote-core-releases/20261026-templates-2622f9d')
STATE = ROOT / 'state'
TERMINAL = ('succeeded', 'failed', 'cancelled', 'force-stopped', 'interrupted')


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def process_args(pid):
    p = Path('/proc') / str(pid) / 'cmdline'
    try:
        return [x.decode() for x in p.read_bytes().split(b'\0') if x]
    except FileNotFoundError:
        return []


def alive(pid):
    p = Path('/proc') / str(pid) / 'stat'
    try:
        return p.read_text().split(') ', 1)[1].split()[0] != 'Z'
    except FileNotFoundError:
        return False


def owned_pid(mode):
    pid = int((ROOT / (mode + '.pid')).read_text())
    args = process_args(pid)
    if not args or Path(args[0]).name != 'sputnik-notebook-remote' or '--mode' not in args:
        raise RuntimeError('unexpected process for ' + mode)
    if args[args.index('--mode') + 1] != mode or args[args.index('--root') + 1] != str(STATE):
        raise RuntimeError('process owner/root mismatch')
    return pid, args


def stop(pid):
    if alive(pid):
        os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 20
    while alive(pid) and time.monotonic() < deadline:
        time.sleep(.1)
    if alive(pid):
        os.kill(pid, signal.SIGKILL)
        deadline = time.monotonic() + 5
        while alive(pid) and time.monotonic() < deadline:
            time.sleep(.1)
    if alive(pid):
        raise RuntimeError('could not stop managed process')


def health():
    token = (STATE / 'token').read_text().strip()
    request = urllib.request.Request('http://127.0.0.1:18765/v1/health',
                                    headers={'Authorization': 'Bearer ' + token})
    with urllib.request.urlopen(request, timeout=3) as reply:
        return json.load(reply)


def wait_health(expected_executable):
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        try:
            value = health()
            _, args = owned_pid('agent')
            if Path(args[0]).resolve() == expected_executable.resolve():
                return value
        except Exception:
            pass
        time.sleep(.2)
    raise RuntimeError('managed service did not become healthy')


def launch(script):
    subprocess.check_call(['/bin/sh', str(script)])


def atomic_script(path, contents):
    temporary = path.with_name(path.name + '.next')
    temporary.write_text(contents)
    temporary.chmod(0o700)
    os.replace(str(temporary), str(path))


build = json.loads((RELEASE / 'build-result.json').read_text())
for name, value in build['binaries'].items():
    if digest(RELEASE / name) != value:
        raise RuntimeError('binary hash mismatch: ' + name)
if build['checks'] != {'language_tests': 'passed', 'remote_integration': 'passed'}:
    raise RuntimeError('release tests are not complete')
agent_pid, agent_args = owned_pid('agent')
gateway_pid, gateway_args = owned_pid('gateway')
previous_health = health()
old_text = (ROOT / 'start-current.sh').read_text()
new_core = RELEASE / 'sputnik-notebook-remote'
new_worker = RELEASE / 'sputnik-notebook-worker'
new_compiler = RELEASE / 'src/sputnik-lang/build/sputnik'
if digest(new_compiler) != build['binaries']['sputnik']:
    raise RuntimeError('source-tree compiler hash mismatch')
old_worker = agent_args[agent_args.index('--worker') + 1]
old_compiler = agent_args[agent_args.index('--sputnik') + 1]
for previous in [agent_args[0], gateway_args[0], old_worker, old_compiler]:
    if previous not in old_text:
        raise RuntimeError('launcher does not match current managed processes')
new_text = old_text.replace(agent_args[0], str(new_core)).replace(gateway_args[0], str(new_core))
new_text = new_text.replace(old_worker, str(new_worker)).replace(old_compiler, str(new_compiler))
for mode in ['agent', 'gateway']:
    previous_log = ROOT / (mode + '-' + Path(agent_args[0]).parent.name + '.log')
    new_text = new_text.replace(str(previous_log), str(ROOT / (mode + '-' + RELEASE.name + '.log')))
extra_environment = ('export SPUTNIK_NATIVE_CXX=/home/slowpilot/sputnik-remote-core/cxx\n'
                     'export SPUTNIK_NATIVE_RT_CACHE=' + shlex.quote(str(RELEASE / 'native-rt-cache')) + '\n'
                     'export SPUTNIK_NATIVE_EXT_CACHE=' + shlex.quote(str(RELEASE / 'native-ext-cache')) + '\n')
position = new_text.index('nohup ')
new_text = new_text[:position] + extra_environment + new_text[position:]
# Prepare the complete launcher before stopping any process.
(RELEASE / 'start-proposed.sh').write_text(new_text)
subprocess.check_call(['/bin/sh', '-n', str(RELEASE / 'start-proposed.sh')])
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
backup = ROOT / 'backups' / ('before-templates-' + stamp)
backup.mkdir(parents=True, mode=0o700)
(backup / 'start-current.sh').write_text(old_text)
(backup / 'previous-processes.json').write_text(json.dumps({'agent': agent_args, 'gateway': gateway_args}, indent=2))
for mode in ['agent', 'gateway']:
    (backup / (mode + '.pid')).write_bytes((ROOT / (mode + '.pid')).read_bytes())
token_hash = digest(STATE / 'token')
connection = sqlite3.connect(str(STATE / 'metadata.sqlite'), timeout=30)
switch_started = False
try:
    connection.execute('BEGIN IMMEDIATE')
    try:
        active = connection.execute("SELECT id,state FROM runs WHERE state NOT IN (?,?,?,?,?)", TERMINAL).fetchall()
        runtimes = connection.execute("SELECT id,state FROM runtime_records WHERE state NOT IN ('terminated','interrupted')").fetchall()
        services = [json.loads(row[0]) for row in connection.execute('SELECT state FROM services')]
        if active or runtimes or any(s.get('enabled') or s.get('running') for s in services):
            raise RuntimeError('active runs/runtimes/services; release switch refused')
        projects = connection.execute('SELECT id,head,state FROM projects ORDER BY id').fetchall()
        run_count = connection.execute('SELECT count(*) FROM runs').fetchone()[0]
        # The SQLite writer lock closes the check/stop race with new Run commits.
        switch_started = True
        stop(agent_pid)
        stop(gateway_pid)
    finally:
        connection.rollback()
        connection.close()
    with sqlite3.connect(str(STATE / 'metadata.sqlite')) as source:
        with sqlite3.connect(str(backup / 'metadata.sqlite')) as destination:
            source.backup(destination)
    alias = ROOT / 'releases' / RELEASE.name
    if not alias.exists():
        alias.symlink_to(RELEASE)
    atomic_script(ROOT / 'start-current.sh', new_text)
    launch(ROOT / 'start-current.sh')
    current_health = wait_health(new_core)
    if token_hash != digest(STATE / 'token'):
        raise RuntimeError('token changed')
    with sqlite3.connect(str(STATE / 'metadata.sqlite')) as connection:
        if projects != connection.execute('SELECT id,head,state FROM projects ORDER BY id').fetchall():
            raise RuntimeError('project state changed during maintenance')
        if connection.execute('SELECT count(*) FROM runs').fetchone()[0] != run_count:
            raise RuntimeError('run history changed during maintenance')
        check = connection.execute('PRAGMA quick_check').fetchone()[0]
        if check != 'ok':
            raise RuntimeError('SQLite quick_check failed')
    result = {'release': str(RELEASE), 'backup': str(backup),
              'source_commits': {k: v['commit'] for k, v in build['repositories'].items()},
              'previous_health': previous_health, 'health': current_health,
              'metadata_preserved': True, 'token_preserved': True,
              'project_count': len(projects), 'run_history_count': run_count,
              'active_runs_interrupted': 0, 'idle_runtimes_reset': 0, 'sqlite_quick_check': check,
              'processes': {m: {'pid': owned_pid(m)[0], 'argv': owned_pid(m)[1]} for m in ['agent', 'gateway']}}
    (RELEASE / 'deploy-result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
except Exception:
    if not switch_started:
        raise
    for mode in ['agent', 'gateway']:
        try:
            pid, args = owned_pid(mode)
            if Path(args[0]).resolve() in (new_core.resolve(), Path(agent_args[0]).resolve(), Path(gateway_args[0]).resolve()):
                stop(pid)
        except Exception:
            pass
    atomic_script(ROOT / 'start-current.sh', old_text)
    launch(ROOT / 'start-current.sh')
    wait_health(Path(agent_args[0]))
    raise
