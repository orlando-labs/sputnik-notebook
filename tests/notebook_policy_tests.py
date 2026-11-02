#!/usr/bin/env python3
"""Real-core coverage for retention, policy inheritance and disposable sessions."""
import argparse
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import sys
import time
import unittest
import uuid

import notebook_remote_tests as remote


class PolicyTests(remote.RemoteHarness):
    def call(self, method, **params):
        reply = remote.rpc(self.root, method, params)
        self.assertEqual(reply['status'], 200, reply)
        return reply['data']

    def configure(self, scope, identity, **limits):
        return self.call('policy.configure', scope=scope, id=identity, limits=limits)

    def collect(self, project=None):
        params = dict(command_id=uuid.uuid4().hex)
        if project is not None:
            params['project_id'] = project
        return self.call('storage.collect', **params)

    def restart_agent(self):
        type(self).agent.terminate()
        type(self).agent.wait(timeout=15)
        type(self).agent = type(self).start_agent()

    def test_operator_policy_file_applies_hierarchy_at_startup(self):
        with tempfile.TemporaryDirectory(prefix='policy-config-', dir='/tmp') as temporary:
            directory = Path(temporary)
            policy = directory / 'policy.json'
            policy.write_text(json.dumps(dict(core=dict(run_count=80), users=dict(trial=dict(run_count=7)), projects=dict(book=dict(run_count=5)))))
            root = directory / 'state'
            with (directory / 'agent.log').open('wb') as output:
                process = subprocess.Popen([remote.OPTIONS.core, '--mode', 'agent', '--root', str(root), '--worker', remote.OPTIONS.worker, '--policy-file', str(policy)], stdout=output, stderr=output)
                try:
                    remote.eventually(lambda: (root / 'agent.sock').exists() and remote.rpc(root, 'health')['status'] == 200)
                    def bound(project, user):
                        reply = remote.rpc(root, 'policy.bind', dict(project_id=project, user_id=user))
                        self.assertEqual(reply['status'], 200, reply)
                        return reply['data']['policy']['run_count']
                    self.assertEqual(bound('book', 'trial'), 5)
                    self.assertEqual(bound('sibling', 'trial'), 7)
                    self.assertEqual(bound('other', 'different'), 80)
                finally:
                    process.terminate()
                    process.wait(timeout=15)

    def test_desktop_app_and_authored_book_limits_cannot_raise_server_policy(self):
        self.assertIs(self.call('health')['allow_book_policy_overrides'], False)
        doc = remote.document()
        doc['resource_policy'] = dict(run_count=3)
        revision, _ = self.upload(doc)
        status, result = self.request('PUT', '/v1/projects/' + self.project + '/resource-policy', dict(command_id=uuid.uuid4().hex, limits=dict(run_count=2)))
        self.assertEqual(status, 200, result)
        self.assertEqual(result['effective']['run_count'], 2)
        self.configure('project', self.project, run_count=1)
        status, result = self.request('PUT', '/v1/projects/' + self.project + '/resource-policy', dict(command_id=uuid.uuid4().hex, limits=dict(run_count=200)))
        self.assertEqual(status, 200, result)
        self.assertEqual(result['effective']['run_count'], 1)
        status, _ = self.request('PUT', '/v1/projects/' + self.project + '/resource-policy', dict(command_id=uuid.uuid4().hex, limits=dict(persistence='durable', user_id='forged')))
        self.assertEqual(status, 422)
        self.assertEqual(self.call('policy.get', project_id=self.project)['effective']['run_count'], 1)

    def test_book_override_mode_requires_launch_flag_and_preserves_operator_ceilings(self):
        with tempfile.TemporaryDirectory(prefix='policy-mode-', dir='/tmp') as temporary:
            directory = Path(temporary)
            root = directory / 'state'
            doc = remote.document()
            doc['resource_policy'] = dict(run_count=200, minimum_free_bytes=67108864,
                                          run_seconds=180, total_run_seconds=180)
            # Reuse the same durable data: the mode is a process option, never
            # persisted in a book, client declaration or operator policy file.
            previous_project = None
            for enabled in (False, True, False):
                command = [remote.OPTIONS.core, '--mode', 'agent', '--root', str(root), '--worker', remote.OPTIONS.worker]
                if enabled:
                    command.append('--allow-book-policy-overrides')
                with (directory / ('agent-' + uuid.uuid4().hex + '.log')).open('wb') as output:
                    process = subprocess.Popen(command, stdout=output, stderr=output)
                    try:
                        def ready():
                            if not (root / 'agent.sock').exists():
                                return False
                            reply = remote.rpc(root, 'health')
                            return reply['status'] == 200 and reply['data']['agent_pid'] == process.pid
                        remote.eventually(ready)
                        def call(method, **params):
                            reply = remote.rpc(root, method, params)
                            self.assertEqual(reply['status'], 200, reply)
                            return reply['data']
                        self.assertIs(call('health')['allow_book_policy_overrides'], enabled)
                        if previous_project:
                            self.assertEqual(call('policy.get', project_id=previous_project)['effective']['run_count'],
                                             12 if enabled else 5, 'restart reinterprets existing declarations without changing them')
                        project = 'book_' + uuid.uuid4().hex
                        call('project.put', project_id=project, command_id='save', base_revision=None,
                             document=json.dumps(doc), files={})
                        bare = call('policy.get', project_id=project)
                        self.assertEqual(bare['effective']['run_count'], 200 if enabled else 100)
                        policy = call('policy.desktop', project_id=project, limits=dict(run_count=5,
                                      minimum_free_bytes=536870912, run_seconds=1, total_run_seconds=1),
                                      allow_book_policy_overrides=True)
                        self.assertIs(policy['allow_book_policy_overrides'], enabled)
                        self.assertEqual(policy['effective']['run_count'], 200 if enabled else 5)
                        self.assertEqual(policy['effective']['minimum_free_bytes'], 67108864 if enabled else 536870912)
                        self.assertEqual(policy['effective']['run_seconds'], 180 if enabled else 1)
                        self.assertEqual(policy['effective']['total_run_seconds'], 180 if enabled else 1)
                        self.assertEqual(policy['defaults']['run_count'], 5, 'defaults exclude authored book fields')
                        user = 'user_' + uuid.uuid4().hex
                        call('policy.configure', scope='user', id=user, limits=dict(run_count=80))
                        call('policy.bind', project_id=project, user_id=user)
                        self.assertEqual(call('policy.get', project_id=project)['effective']['run_count'], 80 if enabled else 5)
                        call('policy.configure', scope='project', id=project, limits=dict(run_count=12))
                        self.assertEqual(call('policy.get', project_id=project)['effective']['run_count'], 12 if enabled else 5)
                        call('policy.configure', scope='profile', id='public', limits=dict(
                            persistence='durable', run_seconds=600, total_run_seconds=600))
                        session = call('session.open', source_project=project, user_id=user, profile='public')
                        effective = call('policy.get', project_id=session['project_id'])['effective']
                        self.assertEqual(effective['total_run_seconds'], 60)
                        self.assertEqual(effective['run_seconds'], 60)
                        self.assertEqual(effective['persistence'], 'session')
                        call('session.close', project_id=session['project_id'])
                        call('policy.configure', scope='core', id='core', limits=dict(run_count=9))
                        self.assertEqual(call('policy.get', project_id=project)['effective']['run_count'], 9 if enabled else 5)
                        # Clear the operator ceiling to keep the next restart's
                        # baseline independent from the preceding case.
                        call('policy.configure', scope='core', id='core', limits={})
                        previous_project = project
                    finally:
                        process.terminate()
                        process.wait(timeout=15)

    def test_registry_is_bounded_and_history_pages_survive_collection(self):
        revision, _ = self.upload(remote.document())
        first, first_command = self.start(revision)
        self.assertEqual(self.wait_run(first)['state'], 'succeeded')
        initial = self.call('run.registry', project_id=self.project)
        self.assertEqual(self.call('policy.get', project_id=self.project)['effective']['run_count'], 100)
        fake_ids = ['seed_' + uuid.uuid4().hex for _ in range(240)]
        with sqlite3.connect(str(self.root / 'metadata.sqlite')) as db:
            template = db.execute('SELECT * FROM runs WHERE id=?', (first['run_id'],)).fetchone()
            for identity in fake_ids:
                row = list(template)
                row[0] = identity
                row[-1] = str(self.root / 'runs' / (identity + '.bin'))
                db.execute('INSERT INTO runs VALUES(' + ','.join('?' for _ in row) + ')', row)
                db.execute('INSERT INTO run_inputs VALUES(?,?,?)', (identity, '0', 'seeded frozen document'))
                db.execute('INSERT INTO run_storage(run,created,artifact_bytes,live_bytes) VALUES(?,?,?,?)',
                           (identity, int(time.time()), 4096, 128))
                (self.root / 'runs' / (identity + '.bin')).write_bytes(b'x' * 4096)
                (self.root / 'runs' / (identity + '.live.bin')).write_bytes(b'x' * 128)
        snapshot = self.call('run.registry', project_id=self.project)
        self.assertEqual([r['id'] for r in snapshot['runs']], [first['run_id']])
        self.assertLess(len(json.dumps(snapshot)), len(json.dumps(initial)) + 200)
        status, page = self.request('GET', '/v1/projects/' + self.project + '/runs?limit=17')
        self.assertEqual(status, 200, page)
        self.assertEqual(len(page['runs']), 17)
        cursor = page['next']
        self.assertIsInstance(cursor, int)
        self.collect(self.project)
        self.assertEqual(self.call('storage.status', project_id=self.project)['retained_runs'], 100)
        self.assertFalse((self.root / 'runs' / (fake_ids[0] + '.bin')).exists())
        self.assertFalse((self.root / 'runs' / (fake_ids[0] + '.live.bin')).exists())
        self.assertTrue((self.root / 'runs' / (first['run_id'] + '.bin')).exists(), 'latest presentation protected')
        page_ids = {r['id'] for r in page['runs']}
        seen = set(page_ids)
        while cursor:
            status, page = self.request('GET', '/v1/projects/' + self.project + '/runs?limit=17&before=' + str(cursor))
            self.assertEqual(status, 200, page)
            ids = {r['id'] for r in page['runs']}
            self.assertFalse(ids & seen)
            seen.update(ids)
            cursor = page['next']
        self.assertEqual(len(seen), 100)
        second, _ = self.start(revision)
        self.assertEqual(self.wait_run(second)['state'], 'succeeded')
        self.assertEqual(self.call('storage.status', project_id=self.project)['retained_runs'], 100)
        for query in ('?limit=101', '?before=0', '?before=-1', '?limit=2&limit=3'):
            self.assertEqual(self.request('GET', '/v1/projects/' + self.project + '/runs' + query)[0], 400)

    def test_inheritance_aggregate_user_quota_and_disk_reserve(self):
        revision, _ = self.upload(remote.document())
        user = 'owner_' + uuid.uuid4().hex
        self.configure('user', user, run_count=7, max_run_bytes=8192, total_run_seconds=9)
        self.call('policy.bind', project_id=self.project, user_id=user)
        with sqlite3.connect(str(self.root / 'metadata.sqlite')) as writer:
            writer.execute('BEGIN IMMEDIATE')
            started = time.monotonic()
            self.call('policy.bind', project_id=self.project, user_id=user)
            self.assertLess(time.monotonic() - started, 2.0, 'reading an existing policy binding must not need a write lock')
            writer.rollback()
        self.configure('project', self.project, run_count=50, total_run_seconds=50, run_seconds=2)
        effective = self.call('policy.get', project_id=self.project)['effective']
        self.assertEqual((effective['run_count'], effective['total_run_seconds'], effective['run_seconds']), (7, 9, 2))
        self.assertEqual(remote.rpc(self.root, 'policy.bind', dict(project_id=self.project, user_id='other'))['status'], 409)
        other = 'other_' + uuid.uuid4().hex
        self.call('policy.bind', project_id=other, user_id=user)
        self.call('project.put', project_id=other, command_id=uuid.uuid4().hex, base_revision=None,
                  document=json.dumps(remote.document()), files={})
        size = self.call('storage.status', project_id=self.project)['project_bytes']
        other_size = self.call('storage.status', project_id=other)['project_bytes']
        self.configure('user', user, total_bytes=size + other_size + 8192 - 512, max_run_bytes=8192)
        body = dict(command_id=uuid.uuid4().hex, revision=revision, sheet_id='main', cell_id='1')
        status, error = self.request('POST', '/v1/projects/' + self.project + '/runs', body)
        self.assertEqual(status, 507, error)
        self.assertIn('user storage', error['error'])
        self.assertEqual(self.request('GET', '/v1/projects/' + self.project + '/commands/' + body['command_id'])[0], 404)
        self.configure('user', user, max_run_bytes=8192)
        try:
            self.configure('core', 'core', minimum_free_bytes=9000000000000000000)
            self.assertEqual(self.request('POST', '/v1/projects/' + self.project + '/runs', body)[0], 507)
        finally:
            self.configure('core', 'core')
            self.call('project.delete', project_id=other, command_id=uuid.uuid4().hex)
        run, _ = self.start(revision)
        self.assertEqual(self.wait_run(run)['state'], 'succeeded')

    def test_collection_preserves_failure_and_previous_result_and_expires_receipts(self):
        self.configure('project', self.project, run_count=2, revision_count=1, event_count=3)
        revision, _ = self.upload(remote.document())
        first, command = self.start(revision)
        self.assertEqual(self.wait_run(first)['state'], 'succeeded')
        second, _ = self.start(revision)
        self.assertEqual(self.wait_run(second)['state'], 'succeeded')
        changed = remote.document('import task\ntask.sleep(60000)\n42\n')
        newer, _ = self.upload(changed, base=revision)
        third, _ = self.start(newer)
        self.wait_run(third, 'running')
        self.collect(self.project)
        self.assertEqual(self.request('GET', '/v1/runs/' + second['run_id'])[0], 200)
        self.assertEqual(self.request('GET', '/v1/runs/' + third['run_id'])[0], 200)
        self.assertEqual(self.request('GET', '/v1/runs/' + first['run_id'])[0], 404)
        self.assertEqual(self.request('POST', '/v1/projects/' + self.project + '/runs', command)[0], 410)
        self.assertEqual(self.request('GET', '/v1/projects/' + self.project + '/commands/' + command['command_id'])[0], 410)
        self.assertEqual(self.request('POST', '/v1/runs/' + third['run_id'] + '/stop',
                         dict(command_id=uuid.uuid4().hex, runtime_epoch=third['runtime_epoch'], force=True))[0], 200)
        self.assertEqual(self.wait_run(third)['state'], 'force-stopped')
        self.collect(self.project)
        registry = self.call('run.registry', project_id=self.project)
        self.assertEqual({r['id'] for r in registry['runs']}, {second['run_id'], third['run_id']})
        self.assertFalse((self.root / 'runs' / (third['run_id'] + '.live.bin')).exists())
        self.assertEqual(remote.rpc(self.root, 'revision.get', dict(project_id=self.project, revision=revision))['status'], 200,
                         'revision required by retained presentation is protected')
        events = self.call('events', project_id=self.project, after=1)
        self.assertLessEqual(len(events['events']), 3)
        self.assertTrue(events['reset_required'])
        self.restart_agent()
        self.assertEqual(self.request('POST', '/v1/projects/' + self.project + '/runs', command)[0], 410,
                         'expired command cannot replay after agent restart')

    def test_age_revision_retention_output_cap_and_deletion_recovery(self):
        self.configure('project', self.project, run_age_seconds=1, revision_count=1, max_run_bytes=4096)
        revision, _ = self.upload(remote.document('1\n'))
        first_revision = revision
        revision, _ = self.upload(remote.document('2\n'), base=revision)
        revision, _ = self.upload(remote.document('3\n'), base=revision)
        self.collect(self.project)
        self.assertEqual(remote.rpc(self.root, 'revision.get', dict(project_id=self.project, revision=first_revision))['status'], 404)
        runs = []
        for _ in range(3):
            run, body = self.start(revision)
            self.assertEqual(self.wait_run(run)['state'], 'succeeded')
            runs.append((run, body))
        with sqlite3.connect(str(self.root / 'metadata.sqlite')) as db:
            db.execute('UPDATE run_storage SET created=0 WHERE run IN (?,?)', tuple(run['run_id'] for run, _ in runs[:2]))
        self.collect(self.project)
        self.assertEqual(self.call('storage.status', project_id=self.project)['retained_runs'], 1)
        self.assertEqual(self.request('POST', '/v1/projects/' + self.project + '/runs', runs[0][1])[0], 410)
        # A committed deletion queue survives an agent restart before unlink.
        queued = 'recover_' + uuid.uuid4().hex + '.bin'
        (self.root / 'runs' / queued).write_bytes(b'pending unlink')
        with sqlite3.connect(str(self.root / 'metadata.sqlite')) as db:
            db.execute('INSERT INTO storage_deletions VALUES(?,?,?)', ('runs/' + queued, self.project, 14))
        self.restart_agent()
        remote.eventually(lambda: not (self.root / 'runs' / queued).exists())
        self.assertEqual(self.request('POST', '/v1/projects/' + self.project + '/runs', runs[0][1])[0], 410)
        # Never write an oversized final/live artifact beyond the reserved budget.
        revision, _ = self.upload(remote.document('"' + ('x' * 10000) + '"\n'), base=revision)
        # The input itself exceeds this run's allowance: rejection is pre-dispatch.
        status, _ = self.request('POST', '/v1/projects/' + self.project + '/runs', dict(command_id=uuid.uuid4().hex, revision=revision, sheet_id='main', cell_id='1'))
        self.assertEqual(status, 413)
        source = 'values = []\n10000.times: values.push!("x")\nvalues.join("")\n'
        revision, _ = self.upload(remote.document(source), base=revision)
        run, _ = self.start(revision)
        result = self.wait_run(run)
        self.assertEqual(result['state'], 'interrupted', result)
        self.assertIn('max_run_bytes', result['error'])
        self.assertFalse((self.root / 'runs' / (run['run_id'] + '.bin')).exists())

    def test_accounting_failure_stops_work_and_recovers_without_replay(self):
        revision, _ = self.upload(remote.document('import task\ntask.sleep(60000)\n42\n'))
        self.configure('project', self.project, total_run_seconds=60)
        run, body = self.start(revision)
        self.wait_run(run, 'running')
        with sqlite3.connect(str(self.root / 'metadata.sqlite')) as db:
            db.execute("CREATE TRIGGER policy_test_failure BEFORE INSERT ON policy_usage BEGIN SELECT RAISE(ABORT,'simulated policy write failure'); END")
        try:
            def stopped():
                status, registry = self.request('GET', '/v1/projects/' + self.project + '/registry')
                return status == 200 and all(r['worker_pid'] is None for r in registry['runtimes'])
            remote.eventually(stopped, timeout=5)
        finally:
            with sqlite3.connect(str(self.root / 'metadata.sqlite')) as db:
                db.execute('DROP TRIGGER policy_test_failure')
        result = self.wait_run(run)
        self.assertEqual(result['state'], 'force-stopped', result)
        self.assertIn('accounting unavailable', result['error'])
        self.assertEqual(self.request('POST', '/v1/projects/' + self.project + '/runs', body)[1]['run_id'], run['run_id'])
        self.assertEqual(self.call('storage.status', project_id=self.project)['retained_runs'], 1)

    def test_temporary_profile_rejects_dependency_installation_and_grants(self):
        revision, _ = self.upload(remote.document(), {'requirements.lock': b''})
        reply = remote.rpc(self.root, 'session.open', dict(source_project=self.project, user_id='visitor', profile='public'))
        self.assertEqual(reply['status'], 422, reply)
        revision, _ = self.upload(remote.document(), base=revision)
        session = self.call('session.open', source_project=self.project, user_id='visitor', profile='public')
        identity = session['project_id']
        reply = remote.rpc(self.root, 'project.put', dict(project_id=identity, command_id='inject', base_revision=session['revision'],
                    document=json.dumps(remote.document()), files={'requirements.lock': ''}))
        self.assertEqual(reply['status'], 422, reply)
        for method in ('environment.prepare', 'dependency.change', 'worker.configure'):
            self.assertEqual(remote.rpc(self.root, method, dict(project_id=identity))['status'], 403, method)
        self.call('session.close', project_id=identity)

    def test_parallel_runs_share_a_durable_total_time_budget(self):
        doc = remote.document('import task\ntask.sleep(60000)\n42\n')
        doc['sheets'].append(dict(id='second', title='Second', cells=[dict(id='2', kind='code', mode='manual', source=doc['sheets'][0]['cells'][0]['source'])]))
        revision, _ = self.upload(doc)
        self.configure('project', self.project, total_run_seconds=2, run_seconds=10)
        started = time.monotonic()
        first, _ = self.start(revision)
        second = self.call('run.start', project_id=self.project, command_id=uuid.uuid4().hex, revision=revision,
                           sheet_id='second', cell_id='2')
        for run in (first, second):
            result = self.wait_run(run)
            self.assertEqual(result['state'], 'force-stopped', result)
            self.assertIn('time budget', result['error'])
        self.assertLess(time.monotonic() - started, 3.0, 'parallel wall time is summed')
        spent = self.call('policy.get', project_id=self.project)['spent_ms']
        self.assertGreaterEqual(spent, 2000)
        self.assertLess(spent, 4000)
        self.restart_agent()
        self.assertGreaterEqual(self.call('policy.get', project_id=self.project)['spent_ms'], spent)
        reply = remote.rpc(self.root, 'run.start', dict(project_id=self.project, command_id=uuid.uuid4().hex,
                    revision=revision, sheet_id='main', cell_id='1'))
        self.assertEqual(reply['status'], 403, reply)

    def test_temporary_sessions_are_clean_on_reopen_expiry_and_restart(self):
        revision, _ = self.upload(remote.document())
        standard = self.call('session.open', source_project=self.project, user_id='preview_owner', profile='public')
        self.assertEqual(standard['policy']['effective']['total_run_seconds'], 60)
        self.call('session.close', project_id=standard['project_id'])
        self.configure('profile', 'short_preview', persistence='session', total_run_seconds=2, run_seconds=2,
                       lease_seconds=1, session_seconds=5, max_run_bytes=8192, project_bytes=65536)
        first = self.call('session.open', source_project=self.project, user_id='preview_owner', profile='short_preview')
        identity = first['project_id']
        self.call('project.put', project_id=identity, command_id='edit', base_revision=first['revision'],
                  document=json.dumps(remote.document('99\n')), files={})
        self.call('session.close', project_id=identity)
        remote.eventually(lambda: remote.rpc(self.root, 'project.get', dict(project_id=identity))['status'] in (404, 410))
        def purged():
            with sqlite3.connect(str(self.root / 'metadata.sqlite')) as db:
                return db.execute('SELECT COUNT(*) FROM policy_projects WHERE project=?', (identity,)).fetchone()[0] == 0
        remote.eventually(purged)
        with sqlite3.connect(str(self.root / 'metadata.sqlite')) as db:
            for table in ('runs', 'revisions', 'receipts', 'run_usage', 'services', 'policy_projects'):
                self.assertEqual(db.execute('SELECT COUNT(*) FROM ' + table + ' WHERE project=?', (identity,)).fetchone()[0], 0, table)
        self.assertEqual(self.call('project.get', project_id=self.project)['head'], revision)
        second = self.call('session.open', source_project=self.project, user_id='preview_owner', profile='short_preview')
        identity = second['project_id']
        self.assertNotEqual(identity, first['project_id'])
        self.assertIn('42', self.call('project.get', project_id=identity)['document'])
        self.assertEqual(self.call('run.registry', project_id=identity)['runs'], [])
        remote.eventually(lambda: remote.rpc(self.root, 'project.get', dict(project_id=identity))['status'] in (404, 410), timeout=5)
        self.assertEqual(remote.rpc(self.root, 'session.touch', dict(project_id=identity))['status'], 410)
        third = self.call('session.open', source_project=self.project, user_id='preview_owner', profile='short_preview')
        self.restart_agent()
        remote.eventually(lambda: remote.rpc(self.root, 'project.get', dict(project_id=third['project_id']))['status'] in (404, 410))

    def test_lease_expiry_stops_active_work_and_user_budget_survives_new_session(self):
        self.configure('profile', 'lease_preview', persistence='session', total_run_seconds=60, run_seconds=30,
                       lease_seconds=2, session_seconds=10, max_run_bytes=8192, project_bytes=65536)
        user = 'budget_' + uuid.uuid4().hex
        self.configure('user', user, total_run_seconds=1)
        revision, _ = self.upload(remote.document('import task\ntask.sleep(60000)\n42\n'))
        first = self.call('session.open', source_project=self.project, user_id=user, profile='lease_preview')
        run = self.call('run.start', project_id=first['project_id'], command_id='run', revision=first['revision'], sheet_id='main', cell_id='1')
        remote.eventually(lambda: remote.rpc(self.root, 'project.get', dict(project_id=first['project_id']))['status'] in (404, 410), timeout=6)
        remote.eventually(lambda: not (self.root / 'runs' / (run['run_id'] + '.bin')).exists())
        with sqlite3.connect(str(self.root / 'metadata.sqlite')) as db:
            spent = db.execute("SELECT milliseconds FROM policy_usage WHERE kind='user' AND id=?", (user,)).fetchone()[0]
        self.assertGreaterEqual(spent, 1000)
        second = self.call('session.open', source_project=self.project, user_id=user, profile='lease_preview')
        reply = remote.rpc(self.root, 'run.start', dict(project_id=second['project_id'], command_id='new-run',
                    revision=second['revision'], sheet_id='main', cell_id='1'))
        self.assertEqual(reply['status'], 403, reply)
        self.call('session.close', project_id=second['project_id'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--worker', required=True)
    parser.add_argument('--core', required=True)
    parser.add_argument('--python', default=sys.executable)
    parser.add_argument('--ruby', default=shutil.which('ruby') or 'ruby')
    parser.add_argument('--keep', action='store_true')
    parser.add_argument('--test')
    options = parser.parse_args()
    options.bridges = False
    remote.OPTIONS = options
    unittest.main(argv=[sys.argv[0]] + ([options.test] if options.test else []), verbosity=2)
