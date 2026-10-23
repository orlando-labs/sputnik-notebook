#!/usr/bin/env python3
"""Real-worker integration tests for the remote preview, including caller loss."""
import argparse
import base64
import hashlib
import io
import os
import zipfile
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
import uuid

from notebook_package_catalog_test import PackageCatalogFixture

TOOLS = Path(__file__).resolve().parents[1] / "tools" / "notebook-remote"
TERMINAL = {"succeeded", "failed", "cancelled", "force-stopped", "interrupted"}


def rpc(root, method, params=None):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(30)
        connection.connect(str(root / "agent.sock"))
        connection.sendall((json.dumps({"method": method, "params": params or {}}) + "\n").encode())
        with connection.makefile("rb") as stream:
            return json.loads(stream.readline(96 * 1024 * 1024).decode())

OPTIONS = None


def eventually(function, timeout=15):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = function()
            if last:
                return last
        except (OSError, ValueError):
            pass
        time.sleep(0.03)
    raise AssertionError("timeout; last value: {!r}".format(last))


def document(source="42\n", modules=False, board=False):
    value = {"format": "sputnik-notebook", "version": 2 if board else 1,
             "title": "Remote test", "active_sheet": "main",
             "sheets": [{"id": "main", "title": "Main", "cells": [
                 {"id": "1", "kind": "code", "source": source, "mode": "manual"}]}],
             "modules": [{"id": "helpers", "path": "modules/helpers.s"}] if modules else [],
             "auto_imports": ["helpers"] if modules else [],
             "future_metadata": {"integer": 9007199254740995, "text": "сохранить"}}
    if board:
        value.update(inputs=[], boards=[{"id": "dashboard", "title": "Board", "sheet": "main",
                                         "columns": 1, "components": []}])
    return value


class RemoteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = Path(tempfile.mkdtemp(prefix="spr-test-", dir="/tmp"))
        # Exercise durable creation of a state root and multiple new ancestors.
        cls.root = cls.directory / "new" / "state"
        cls.logs = []
        cls.process_env = dict(os.environ)
        compiler = Path(__file__).resolve().parents[2] / "sputnik-lang/build/sputnik"
        cls.catalog_fixture = PackageCatalogFixture(compiler)
        cls.process_env["SPUTNIK_PKG_REGISTRY"] = cls.catalog_fixture.origin
        cls.process_env.pop("SPUTNIK_PKG_CREDENTIALS", None)
        if OPTIONS.bridges:
            workspace = Path(__file__).resolve().parents[2]
            compiler = workspace / "sputnik-lang/build/sputnik"
            cls.process_env["SPUTNIK_PKG_HOME"] = str(cls.directory / "packages")
            for name in ("pycall", "rbcall"):
                subprocess.run([str(compiler), "pkg", "install", str(workspace / name)], env=cls.process_env,
                               check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            cls.port = probe.getsockname()[1]
        cls.agent = cls.start_agent()
        cls.gateway = cls.start_gateway()

    @classmethod
    def start_agent(cls):
        log = (cls.directory / ("agent-" + uuid.uuid4().hex + ".log")).open("wb")
        cls.logs.append(log)
        compiler = Path(__file__).resolve().parents[2] / "sputnik-lang/build/sputnik"
        agent = subprocess.Popen([OPTIONS.core, "--mode", "agent", "--root", str(cls.root), "--worker", OPTIONS.worker, "--python", OPTIONS.python, "--ruby", OPTIONS.ruby, "--sputnik", str(compiler)], stdout=log, stderr=log, env=cls.process_env)
        eventually(lambda: (cls.root / "agent.sock").exists() and rpc(cls.root, "health")["status"] == 200, timeout=90)
        cls.token = (cls.root / "token").read_text().strip()
        return agent

    @classmethod
    def start_gateway(cls):
        log = (cls.directory / ("gateway-" + uuid.uuid4().hex + ".log")).open("wb")
        cls.logs.append(log)
        gateway = subprocess.Popen([OPTIONS.core, "--mode", "gateway", "--root", str(cls.root), "--port", str(cls.port)], stdout=log, stderr=log, env=cls.process_env)
        eventually(lambda: cls.request("GET", "/v1/health")[0] == 200)
        return gateway

    @classmethod
    def request(cls, method, route, body=None, token=True, binary=False):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + cls.token
        request = urllib.request.Request("http://127.0.0.1:{}{}".format(cls.port, route),
                                         data=json.dumps(body).encode() if body is not None else None,
                                         headers=headers, method=method)
        try:
            response = urllib.request.urlopen(request, timeout=20)
        except urllib.error.HTTPError as exc:
            response = exc
        with response:
            data = response.read()
            return response.getcode(), data if binary else json.loads(data.decode())

    @classmethod
    def tearDownClass(cls):
        for process in (cls.gateway, cls.agent):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for log in cls.logs:
            log.close()
        cls.catalog_fixture.close()
        if not OPTIONS.keep:
            shutil.rmtree(str(cls.directory))
        else:
            print("remote test state: " + str(cls.root))

    def setUp(self):
        self.project = "test_" + uuid.uuid4().hex

    def tearDown(self):
        status, reply = self.request("DELETE", "/v1/projects/" + self.project,
                                     {"command_id": uuid.uuid4().hex})
        self.assertIn(status, (200, 404), reply)
        if status == 200:
            eventually(lambda: self.request("GET", "/v1/projects/" + self.project)[1]["state"] == "deleted")

    def upload(self, doc, files=None, base=None, command=None):
        body = {"command_id": command or uuid.uuid4().hex, "base_revision": base,
                "document": json.dumps(doc, ensure_ascii=False),
                "files": {name: base64.b64encode(data).decode() for name, data in (files or {}).items()}}
        status, reply = self.request("PUT", "/v1/projects/" + self.project, body)
        self.assertEqual(status, 200, reply)
        return reply["revision"], body

    def start(self, revision, command=None, action="run"):
        body = {"command_id": command or uuid.uuid4().hex, "revision": revision, "sheet_id": "main",
                "cell_id": "1", "action": action}
        status, reply = self.request("POST", "/v1/projects/" + self.project + "/runs", body)
        self.assertEqual(status, 200, reply)
        return reply, body

    def wait_run(self, run, state=None):
        def ready():
            status, value = self.request("GET", "/v1/runs/" + run["run_id"])
            self.assertEqual(status, 200, value)
            return value if value["state"] == state or (state is None and value["state"] in TERMINAL) else None
        return eventually(ready)

    def test_managed_environment_reuse_restart_failure_and_logs(self):
        # A real, offline-installable wheel proves packages land in this notebook's venv.
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as wheel:
            wheel.writestr("sputnik_probe/__init__.py", "VALUE = 123\n")
            wheel.writestr("sputnik_probe-1.0.dist-info/METADATA", "Metadata-Version: 2.1\nName: sputnik-probe\nVersion: 1.0\n")
            wheel.writestr("sputnik_probe-1.0.dist-info/WHEEL", "Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\nTag: py3-none-any\n")
            wheel.writestr("sputnik_probe-1.0.dist-info/RECORD", "")
        data = archive.getvalue()
        files = {"requirements.lock": ("./wheels/sputnik_probe-1.0-py3-none-any.whl --hash=sha256:" + hashlib.sha256(data).hexdigest() + "\n").encode(),
                 "wheels/sputnik_probe-1.0-py3-none-any.whl": data}
        source = "42\n"
        if OPTIONS.bridges:
            source = "import pycall.sputnik_probe as probe\nfrom rbcall.sputnik_probe import SputnikProbe\n[probe.VALUE, SputnikProbe.value]\n"
            bundle = self.directory / ("bundle-" + uuid.uuid4().hex)
            bundle.mkdir()
            (bundle / "lib").mkdir()
            (bundle / "lib/sputnik_probe.rb").write_text('module SputnikProbe\n  def self.value = 456\nend\n')
            (bundle / "sputnik-probe.gemspec").write_text('Gem::Specification.new do |s|\n'
                '  s.name = "sputnik-probe"; s.version = "1.0"; s.summary = "Offline test"\n'
                '  s.authors = ["Sputnik"]; s.files = ["lib/sputnik_probe.rb"]\nend\n')
            subprocess.run([OPTIONS.ruby, "-S", "gem", "build", "sputnik-probe.gemspec"], cwd=bundle,
                           check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            (bundle / "vendor/cache").mkdir(parents=True)
            gem = (bundle / "sputnik-probe-1.0.gem").read_bytes()
            (bundle / "vendor/cache/sputnik-probe-1.0.gem").write_bytes(gem)
            (bundle / "Gemfile").write_text('source "https://rubygems.org"\ngem "sputnik-probe", "1.0"\n')
            bundler = subprocess.check_output([OPTIONS.ruby, "-rbundler", "-e", "print Bundler::VERSION"], text=True)
            (bundle / "Gemfile.lock").write_text("GEM\n  remote: https://rubygems.org/\n  specs:\n    sputnik-probe (1.0)\n\n"
                "PLATFORMS\n  ruby\n\nDEPENDENCIES\n  sputnik-probe (= 1.0)\n\nBUNDLED WITH\n   " + bundler + "\n")
            files["Gemfile"] = (bundle / "Gemfile").read_bytes()
            files["Gemfile.lock"] = (bundle / "Gemfile.lock").read_bytes()
            files["vendor/cache/sputnik-probe-1.0.gem"] = gem
        revision, _ = self.upload(document(source), files)
        if OPTIONS.bridges:
            settings_route = "/v1/projects/" + self.project + "/worker-settings/main"
            settings = self.request("GET", settings_route)[1]
            status, response = self.request("PUT", settings_route, dict(command_id=uuid.uuid4().hex, grants=["ffi.call", "ffi.load"], base_version=settings["version"], runtime_epoch=None))
            self.assertEqual(status, 200, response)
        route = "/v1/projects/" + self.project + "/environments"
        command = {"command_id": uuid.uuid4().hex}
        status, accepted = self.request("POST", route, command)
        self.assertEqual(status, 200, accepted)
        self.assertEqual(self.request("POST", route, command)[1], accepted)
        # Installation belongs to the agent and survives losing the HTTP process.
        self.gateway.terminate()
        self.gateway.wait(timeout=5)
        type(self).gateway = self.start_gateway()
        self.assertEqual(self.request("POST", route, command)[1], accepted)
        def ready():
            values = self.request("GET", route)[1]["environments"]
            return values[0] if values and values[0]["state"] in ("ready", "failed", "interrupted") else None
        installed = eventually(ready, timeout=60)
        self.assertEqual(installed["state"], "ready", installed)
        directory = Path(installed["directory"])
        probe = subprocess.check_output([str(directory / ".venv/bin/python"), "-c", "import sputnik_probe; print(sputnik_probe.VALUE)"])
        self.assertEqual(probe.strip(), b"123")
        run, _ = self.start(revision)
        completed = self.wait_run(run)
        self.assertEqual(completed["state"], "succeeded", completed)
        if OPTIONS.bridges:
            self.assertIn('123', completed["result"]["cells"][0]["result"])
            self.assertIn('456', completed["result"]["cells"][0]["result"])
        registry = self.request("GET", "/v1/projects/" + self.project + "/runs")[1]
        self.assertEqual(registry["runtimes"][0]["needs_restart"], False)
        status, reset = self.request("POST", "/v1/projects/" + self.project + "/restart", dict(command_id=uuid.uuid4().hex, sheet_id="main", runtime_epoch=run["runtime_epoch"]))
        self.assertEqual(status, 200, reset)
        again, _ = self.start(revision)
        self.assertEqual(self.wait_run(again)["state"], "succeeded")
        self.assertNotEqual(again["runtime_epoch"], run["runtime_epoch"])
        self.assertEqual(self.request("GET", route)[1]["environments"][0]["directory"], str(directory))
        self.agent.kill()
        self.agent.wait(timeout=5)
        type(self).agent = self.start_agent()
        restored = self.request("GET", route)[1]["environments"][0]
        self.assertEqual((restored["directory"], restored["state"]), (str(directory), "ready"))
        status, reset = self.request("POST", "/v1/projects/" + self.project + "/restart", dict(command_id=uuid.uuid4().hex, sheet_id="main", runtime_epoch=again["runtime_epoch"]))
        self.assertEqual(status, 200, reset)
        recovered, _ = self.start(revision)
        self.assertEqual(self.wait_run(recovered)["state"], "succeeded")
        self.assertEqual(self.request("GET", route)[1]["environments"][0]["directory"], str(directory))
        files["requirements.lock"] = b"./wheels/missing-1.0-py3-none-any.whl --hash=sha256:0000\n"
        newer, _ = self.upload(document(), files, base=revision)
        status, pending = self.request("POST", route, {"command_id": uuid.uuid4().hex})
        self.assertEqual(status, 200, pending)
        def failed():
            values = self.request("GET", route)[1]["environments"]
            return next((v for v in values if v["id"] != installed["id"] and v["state"] == "failed"), None)
        broken = eventually(failed, timeout=60)
        self.assertTrue((directory / "ready.json").exists(), "failed generation preserves the working environment")
        self.assertTrue((Path(broken["directory"]) / "stderr.log").exists())
        status, log = self.request("GET", route + "/" + broken["id"])
        self.assertEqual(status, 200, log)
        self.assertTrue(log["stdout"] or log["stderr"])
        self.assertEqual(self.request("POST", "/v1/projects/" + self.project + "/runs", dict(command_id=uuid.uuid4().hex, revision=newer, sheet_id="main", cell_id="1", action="run"))[0], 409)
        self.assertEqual(self.request("POST", route, {"command_id": uuid.uuid4().hex})[1]["directory"], broken["directory"])
        status, retry = self.request("POST", route, {"command_id": uuid.uuid4().hex, "retry": True})
        self.assertEqual(status, 200, retry)
        self.assertNotEqual(retry["directory"], broken["directory"])
        retried = eventually(failed, timeout=60)
        self.assertEqual(retried["directory"], retry["directory"])
        self.assertTrue(Path(broken["directory"]).exists(), "retry never overwrites an earlier installation attempt")

    def test_dependency_packages_install_remove_receipts_and_worker_imports(self):
        source = self.directory / (self.project + "-source")
        (source / "src").mkdir(parents=True)
        (source / "sputnik.toml").write_text('[package]\nname = "notebook-probe"\nversion = "1.0.0"\nroot = "notebook_probe"\n'
            '[[modules]]\nname = "notebook_probe"\npath = "src/probe.s"\n')
        (source / "src/probe.s").write_text('package notebook_probe\nexport answer\ndef answer(): 789\n')
        revision, _ = self.upload(document('from notebook_probe import answer\nanswer()\n'))
        route = "/v1/projects/" + self.project + "/dependencies"
        self.assertEqual(self.request("GET", route, token=False)[0], 401)
        self.assertEqual(self.request("GET", route)[1]["packages"], [])
        def change(action, package_source):
            body = dict(command_id=uuid.uuid4().hex, action=action, source=package_source, version="1.0.0")
            status, accepted = self.request("POST", route, body)
            self.assertEqual(status, 200, accepted)
            self.assertEqual(self.request("POST", route, body)[1], accepted)
            def ready():
                status, operation = self.request("GET", route + "/" + accepted["id"])
                self.assertEqual(status, 200, operation)
                return operation if operation["state"] not in ("queued", "running") else None
            result = eventually(ready, timeout=60)
            self.assertEqual(result["state"], "succeeded", result)
            return result
        installed = change("install_sputnik", str(source))
        self.assertTrue(installed["stdout"])
        packages = self.request("GET", route)[1]["packages"]
        self.assertEqual([(p["name"], p["version"]) for p in packages], [("notebook-probe", "1.0.0")])
        self.assertTrue((self.root / "projects" / self.project / "packages/notebook-probe/1.0.0/modules.index").exists())
        run, _ = self.start(revision)
        completed = self.wait_run(run)
        self.assertEqual(completed["state"], "succeeded", completed)
        self.assertEqual(completed["result"]["cells"][0]["result"], "789")
        change("remove_sputnik", "notebook-probe")
        self.assertEqual(self.request("GET", route)[1]["packages"], [])
        registry = self.request("GET", "/v1/projects/" + self.project + "/registry")[1]
        self.assertIn(run["runtime_epoch"], registry["reset_epochs"], "other clients discard results from the retired package runtime")
        run, _ = self.start(revision)
        self.assertEqual(self.wait_run(run)["state"], "failed")
        self.assertTrue(source.exists(), "removing an installation preserves original source")

    def test_package_catalog_uses_execution_host_without_retiring_workers(self):
        revision, _ = self.upload(document())
        run, _ = self.start(revision)
        self.assertEqual(self.wait_run(run)["state"], "succeeded")
        route = "/v1/projects/" + self.project + "/package-catalog"
        body = dict(command_id=uuid.uuid4().hex, query="versions", source="editor-probe")
        self.assertEqual(self.request("POST", route, body, token=False)[0], 401)
        status, versions = self.request("POST", route, body)
        self.assertEqual(status, 200, versions)
        self.assertEqual(versions["package_ref"], "test/editor-probe")
        self.assertEqual([r["version"] for r in versions["versions"]], ["3.0.0", "2.0.0-rc.1", "1.1.0", "1.0.0", "0.9.0"])
        body.update(command_id=uuid.uuid4().hex, query="variants", source="test/editor-probe@1.0.0")
        request_file = self.directory / (uuid.uuid4().hex + ".json")
        request_file.write_text(json.dumps(body))
        checked = subprocess.run([OPTIONS.core, "--mode", "cli", "--url", "http://127.0.0.1:" + str(self.port),
                                  "--token-file", str(self.root / "token"), "--command", "package_catalog",
                                  "--project", self.project, "--request-file", str(request_file)],
                                 capture_output=True, text=True, timeout=30, env=self.process_env)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        builds = json.loads(checked.stdout)
        self.assertEqual(builds["recommended_variant"], "source")
        selections = {a["variant"]: a["host_selection"] for a in builds["artifacts"]}
        self.assertTrue(selections["source"]["compatible"])
        self.assertFalse(selections["foreign"]["compatible"])
        self.assertIn(builds["host"]["os"], ["macos", "linux"])
        self.assertEqual(self.request("POST", route, dict(query="install", source="editor-probe"))[0], 400)
        self.assertEqual(self.request("POST", route, dict(query="versions", source="--help"))[0], 400)
        self.assertEqual(self.request("POST", route, dict(query="versions", source="missing"))[0], 422)
        dependencies = self.request("GET", "/v1/projects/" + self.project + "/dependencies")[1]
        self.assertEqual(dependencies["packages"], [])
        self.assertEqual(dependencies["jobs"], [])
        registry = self.request("GET", "/v1/projects/" + self.project + "/registry")[1]
        self.assertNotIn(run["runtime_epoch"], registry["reset_epochs"])
        again, _ = self.start(revision)
        self.assertEqual(self.wait_run(again)["state"], "succeeded")
        self.assertEqual(again["runtime_epoch"], run["runtime_epoch"], "catalog inspection keeps the execution runtime")

    def test_dependency_operation_rejects_active_run_and_resolves_ruby_lock(self):
        revision, _ = self.upload(document('import task\ntask.sleep(1500)\n42\n'), {"Gemfile": b'source "https://rubygems.org"\n'})
        # A missing lock blocks managed preparation, so resolve it first.
        route = "/v1/projects/" + self.project + "/dependencies"
        status, accepted = self.request("POST", route, dict(command_id=uuid.uuid4().hex, action="lock_ruby"))
        self.assertEqual(status, 200, accepted)
        def ready():
            value = self.request("GET", route + "/" + accepted["id"])[1]
            return value if value["state"] not in ("queued", "running") else None
        resolved = eventually(ready, timeout=30)
        self.assertEqual(resolved["state"], "succeeded", resolved)
        self.assertIn("BUNDLED WITH", json.loads(resolved["result"])["gemfile_lock"])
        self.assertFalse((self.root / "revisions" / revision / "Gemfile.lock").exists(), "lock resolution returns a draft without changing source revisions")
        newer, _ = self.upload(document('import task\ntask.sleep(1500)\n42\n'), base=revision)
        run, _ = self.start(newer)
        self.wait_run(run, "running")
        status, denied = self.request("POST", route, dict(command_id=uuid.uuid4().hex, action="remove_sputnik", source="absent"))
        self.assertEqual(status, 409, denied)
        self.assertEqual(self.wait_run(run)["state"], "succeeded")

    def test_first_run_prepares_python_environment(self):
        revision, _ = self.upload(document(), {"requirements.lock": b""})
        route = "/v1/projects/" + self.project + "/environments"
        self.assertEqual(self.request("GET", route)[1]["environments"], [])
        run, _ = self.start(revision)
        completed = self.wait_run(run)
        self.assertEqual(completed["state"], "succeeded", completed)
        installed = self.request("GET", route)[1]["environments"]
        self.assertEqual(len(installed), 1)
        self.assertEqual(installed[0]["state"], "ready")
        self.assertTrue((Path(installed[0]["directory"]) / "ready.json").exists())

    def test_retry_after_cancelled_preparation_requires_runtime_restart(self):
        revision, _ = self.upload(document(), {"requirements.lock": b"./wheels/missing-1.0-py3-none-any.whl --hash=sha256:0000\n"})
        route = "/v1/projects/" + self.project + "/environments"
        run, _ = self.start(revision)
        self.wait_run(run, "preparing")
        status, stopped = self.request("POST", "/v1/runs/" + run["run_id"] + "/stop",
            dict(command_id=uuid.uuid4().hex, runtime_epoch=run["runtime_epoch"]))
        self.assertEqual(status, 200, stopped)
        self.assertEqual(self.wait_run(run)["state"], "cancelled")
        def failed():
            installed = self.request("GET", route)[1]["environments"]
            return installed[0] if installed and installed[0]["state"] == "failed" else None
        original = eventually(failed, timeout=60)
        status, retry = self.request("POST", route, dict(command_id=uuid.uuid4().hex, retry=True))
        self.assertEqual(status, 200, retry)
        self.assertNotEqual(original["directory"], retry["directory"])
        registry = self.request("GET", "/v1/projects/" + self.project + "/runs")[1]
        self.assertTrue(registry["runtimes"][0]["needs_restart"])
        status, error = self.request("POST", "/v1/projects/" + self.project + "/runs",
            dict(command_id=uuid.uuid4().hex, revision=revision, sheet_id="main", cell_id="1", action="run"))
        self.assertEqual(status, 409, error)
        self.assertIn("restart", error["error"])
        eventually(failed, timeout=60)

    def test_orphan_gc_uses_registry_ownership_and_first_seen_age(self):
        self.upload(document())
        projects = self.root / "projects"
        def directory(name):
            path = projects / name
            path.mkdir(parents=True)
            (path / ".sputnik-owner").write_text("sputnik-notebook-project.v1\n" + name + "\n" + uuid.uuid4().hex + "\n")
            (path / "keep").write_text("data")
            return path
        registered = directory(self.project)
        orphan_id = "orphan_" + uuid.uuid4().hex
        orphan = directory(orphan_id)
        outside = self.directory / ("outside_" + uuid.uuid4().hex)
        outside.mkdir()
        (outside / "keep").write_text("outside data")
        (orphan / "external").symlink_to(outside, target_is_directory=True)
        unknown = projects / ("unknown_" + uuid.uuid4().hex)
        unknown.mkdir()
        linked = projects / ("linked_" + uuid.uuid4().hex)
        linked.symlink_to(outside, target_is_directory=True)
        busy_id = "interrupted_" + uuid.uuid4().hex
        busy = directory(busy_id)
        with sqlite3.connect(str(self.root / "metadata.sqlite")) as db:
            db.execute("INSERT INTO foreign_environment_attempts VALUES(?,?,?,?)",
                       (busy_id, "test", str(busy / "install"), "interrupted"))
        def gc(age, dry=False):
            status, value = self.request("POST", "/v1/maintenance/orphans", dict(command_id=uuid.uuid4().hex, minimum_age_seconds=age, dry_run=dry))
            self.assertEqual(status, 200, value)
            return value
        self.assertIn(orphan_id, gc(3600)["pending"])
        self.assertTrue(orphan.exists())
        with sqlite3.connect(str(self.root / "metadata.sqlite")) as db:
            db.execute("UPDATE orphan_projects SET first_seen=first_seen-7200 WHERE id=?", (orphan_id,))
        (orphan / ".sputnik-owner").write_text("sputnik-notebook-project.v1\n" + orphan_id + "\n" + uuid.uuid4().hex + "\n")
        self.assertIn(orphan_id, gc(3600)["pending"], "a new ownership identity resets orphan age")
        with sqlite3.connect(str(self.root / "metadata.sqlite")) as db:
            db.execute("UPDATE orphan_projects SET first_seen=first_seen-7200 WHERE id=?", (orphan_id,))
        self.assertIn(orphan_id, gc(3600, True)["removed"])
        self.assertTrue(orphan.exists(), "dry run cannot remove files")
        self.assertIn(orphan_id, gc(3600)["removed"])
        self.assertFalse(orphan.exists())
        self.assertTrue(registered.exists(), "disconnected registered projects remain owned")
        self.assertTrue(unknown.exists(), "directories without an ownership marker are not collected")
        self.assertTrue(linked.is_symlink(), "symlinked project roots are skipped")
        self.assertTrue((outside / "keep").exists(), "child symlink targets are never traversed")
        self.assertTrue(busy.exists(), "unresolved interrupted installers protect project directories")

    def test_orphan_gc_schedule(self):
        root = self.directory / ("scheduled-" + uuid.uuid4().hex)
        log = (self.directory / (root.name + ".log")).open("wb")
        process = subprocess.Popen([OPTIONS.core, "--mode", "agent", "--root", str(root), "--worker", OPTIONS.worker,
                                    "--orphan-gc-interval", "1", "--orphan-min-age", "1"],
                                   stdout=log, stderr=log, env=self.process_env)
        try:
            eventually(lambda: (root / "agent.sock").exists() and rpc(root, "health")["status"] == 200)
            orphan_id = "scheduled_orphan"
            orphan = root / "projects" / orphan_id
            orphan.mkdir()
            (orphan / ".sputnik-owner").write_text("sputnik-notebook-project.v1\n" + orphan_id + "\n" + uuid.uuid4().hex + "\n")
            eventually(lambda: not orphan.exists(), timeout=10)
        finally:
            process.terminate()
            process.wait(timeout=10)
            log.close()

    def test_worker_environment_override_requires_restart_when_changed(self):
        revision, _ = self.upload(document('from system import cmd\ncmd"/usr/bin/env".output\n'))
        directory = self.directory / ("manual_environment_" + uuid.uuid4().hex)
        directory.mkdir()
        (directory / "Gemfile").write_text('# environment selection test\n')
        route = "/v1/projects/" + self.project + "/worker-settings/main"
        original = self.request("GET", route)[1]
        body = dict(command_id=uuid.uuid4().hex, grants=["process.spawn=/usr/bin/env"],
                    environment_directory="../relative", base_version=original["version"], runtime_epoch=None)
        self.assertEqual(self.request("PUT", route, body)[0], 400)
        self.assertEqual(self.request("GET", route)[1], original)
        body.update(command_id=uuid.uuid4().hex, environment_directory=str(directory))
        status, configured = self.request("PUT", route, body)
        self.assertEqual(status, 200, configured)
        self.assertEqual(configured["environment_directory"], str(directory))
        self.assertEqual(self.request("PUT", route, body)[1], configured)
        run, _ = self.start(revision)
        completed = self.wait_run(run)
        self.assertEqual(completed["state"], "succeeded", completed)
        self.assertIn("BUNDLE_GEMFILE=" + str((directory / "Gemfile").resolve()), completed["result"]["cells"][0]["result"])
        (directory / "Gemfile.lock").write_text('# changed after worker launch\n')
        registry = self.request("GET", "/v1/projects/" + self.project + "/runs")[1]
        self.assertTrue(registry["runtimes"][0]["needs_restart"])
        self.assertEqual(self.request("POST", "/v1/projects/" + self.project + "/runs",
            dict(command_id=uuid.uuid4().hex, revision=revision, sheet_id="main", cell_id="1", action="run"))[0], 409)
        settings = self.request("GET", route)[1]
        status, configured = self.request("PUT", route, dict(body, command_id=uuid.uuid4().hex,
            base_version=settings["version"], runtime_epoch=settings["runtime_epoch"]))
        self.assertEqual(status, 200, configured)
        again, _ = self.start(revision)
        self.assertEqual(self.wait_run(again)["state"], "succeeded")
        self.assertNotEqual(again["runtime_epoch"], run["runtime_epoch"])

    def test_worker_grants_scope_revoke_receipts_and_stale_settings(self):
        source = 'from system import cmd\ncmd"/usr/bin/printf granted".output\n'
        doc = document(source)
        doc["worker_grants"] = ["process.spawn"]  # Inert notebook metadata cannot grant host access.
        doc["sheets"].append(dict(id="other", title="Other", cells=[dict(id="2", kind="code", source=source, mode="manual")]))
        revision, _ = self.upload(doc)
        route = "/v1/projects/" + self.project + "/worker-settings/main"
        self.assertEqual(self.request("GET", route, token=False)[0], 401)
        run, _ = self.start(revision)
        denied = self.wait_run(run)
        self.assertEqual(denied["state"], "failed")
        self.assertIn("CapabilityError", denied["result"]["cells"][0]["error"])
        settings = self.request("GET", route)[1]
        self.assertEqual(settings["grants"], [])

        def body(grants, base=None):
            value = base or self.request("GET", route)[1]
            return dict(command_id=uuid.uuid4().hex, grants=grants,
                        base_version=value["version"], runtime_epoch=value["runtime_epoch"])

        for invalid in (["unknown.capability"], ["process.spawn="], ["process.spawn\nfs.write"], [42], "process.spawn"):
            self.assertEqual(self.request("PUT", route, body(invalid))[0], 400)
            self.assertEqual(self.request("GET", route)[1], settings, "invalid settings leave the heap and grants untouched")
        scoped = body(["process.spawn=/bin/cat"])
        self.assertEqual(self.request("PUT", route, scoped)[0], 200)
        run, _ = self.start(revision)
        self.assertEqual(self.wait_run(run)["state"], "failed", "a different executable stays denied")
        self.assertEqual(self.request("PUT", route, body(["process.spawn"], settings))[0], 409)
        accepted = body(["process.spawn=/usr/bin/printf", "process.spawn=/usr/bin/printf"])
        status, updated = self.request("PUT", route, accepted)
        self.assertEqual(status, 200, updated)
        self.assertEqual(updated["grants"], ["process.spawn=/usr/bin/printf"])
        allowed, _ = self.start(revision)
        success = self.wait_run(allowed)
        self.assertEqual(success["state"], "succeeded", success)
        self.assertIn("granted", success["result"]["cells"][0]["result"])
        other_route = "/v1/projects/" + self.project + "/runs"
        status, other = self.request("POST", other_route, dict(command_id=uuid.uuid4().hex,
            revision=revision, sheet_id="other", cell_id="2", action="run"))
        self.assertEqual(status, 200, other)
        self.assertEqual(self.wait_run(other)["state"], "failed", "grants do not leak into another sheet")
        self.assertEqual(self.request("PUT", route, accepted)[1], updated, "retry returns the original receipt")
        self.assertEqual(self.request("GET", route)[1]["runtime_epoch"], allowed["runtime_epoch"], "retry cannot reset the new worker")
        self.assertEqual(self.request("PUT", route, body([]))[0], 200)
        revoked, _ = self.start(revision)
        self.assertEqual(self.wait_run(revoked)["state"], "failed")
        self.assertNotEqual(revoked["runtime_epoch"], allowed["runtime_epoch"])

    def test_worker_grants_refuse_active_runtime(self):
        revision, _ = self.upload(document("import task\ntask.sleep(60000)\n42\n"))
        run, _ = self.start(revision)
        self.wait_run(run, "running")
        route = "/v1/projects/" + self.project + "/worker-settings/main"
        settings = self.request("GET", route)[1]
        status, response = self.request("PUT", route, dict(command_id=uuid.uuid4().hex,
            grants=["process.spawn"], base_version=settings["version"], runtime_epoch=settings["runtime_epoch"]))
        self.assertEqual(status, 409, response)
        self.assertIn("stop active run", response["error"])
        self.assertEqual(self.request("GET", route)[1], settings)

    def test_auth_and_snapshot_roundtrip(self):
        self.assertEqual(self.request("GET", "/v1/health", token=False)[0], 401)
        doc = document("answer()\n", modules=True, board=True)
        files = {"modules/helpers.s": b"package helpers\ndef answer(): 42\nexport answer\n",
                 "assets/note.txt": "данные".encode()}
        revision, body = self.upload(doc, files)
        # A retry succeeds even though its original base_revision is now old.
        self.assertEqual(self.request("PUT", "/v1/projects/" + self.project, body)[1]["revision"], revision)
        status, restored = self.request("GET", "/v1/projects/" + self.project + "/revisions/" + revision)
        self.assertEqual(status, 200, restored)
        self.assertEqual(json.loads(restored["document"]), doc)
        self.assertEqual(restored["files"], body["files"])
        run, _ = self.start(revision)
        result = self.wait_run(run)
        self.assertEqual(result["state"], "succeeded", result)
        self.assertEqual(result["result"]["cells"][0]["result"], "42")
        status, binary = self.request("GET", "/v1/runs/" + run["run_id"] + "/presentation", binary=True)
        self.assertEqual(status, 200, binary[:500])
        self.assertIn(b"sputnik.notebook.presentation", binary[:80])

    def test_snapshot_publication_failure_preserves_head_and_receipt(self):
        doc = document()
        del doc["future_metadata"]  # Keep the digest fixture entirely ASCII.
        revision, original = self.upload(doc)

        def revision_id(body):
            value = [self.project, body["document"], []]
            return hashlib.sha256(json.dumps(value, separators=(",", ":")).encode()).hexdigest()

        self.assertEqual(revision_id(original), revision)
        doc["title"] = "Next revision"
        body = dict(original, command_id=uuid.uuid4().hex, base_revision=revision,
                    document=json.dumps(doc))
        candidate = revision_id(body)
        # Fail manifest publication after the snapshot tree has been sealed and
        # renamed. SQL must not expose that incomplete publication or its receipt.
        obstacle = self.root / "revisions" / (candidate + ".manifest.json")
        obstacle.mkdir()
        try:
            status, reply = self.request("PUT", "/v1/projects/" + self.project, body)
            self.assertEqual(status, 500, reply)
            self.assertTrue((self.root / "revisions" / candidate / "project.json").is_file())
            self.assertEqual(self.request("GET", "/v1/projects/" + self.project)[1]["head"], revision)
            self.assertEqual(self.request("GET", "/v1/projects/" + self.project + "/commands/" + body["command_id"])[0], 404)
            self.assertEqual(self.request("GET", "/v1/projects/" + self.project + "/revisions/" + candidate)[0], 404)
        finally:
            obstacle.rmdir()
        status, reply = self.request("PUT", "/v1/projects/" + self.project, body)
        self.assertEqual(status, 200, reply)
        self.assertEqual(reply["revision"], candidate)
        self.assertEqual(self.request("PUT", "/v1/projects/" + self.project, body)[1], reply)

    def test_snapshot_nested_tree_survives_agent_restart(self):
        doc = document("answer()\n", modules=True, board=True)
        files = {"modules/helpers.s": b"package helpers\ndef answer(): 42\nexport answer\n",
                 "assets/deep/one/two/payload.bin": bytes(range(256)),
                 "assets/deep/other/note.txt": "данные".encode(),
                 "assets/empty.bin": b""}
        revision, body = self.upload(doc, files)
        self.agent.kill()
        self.agent.wait(timeout=5)
        type(self).agent = self.start_agent()
        status, restored = self.request("GET", "/v1/projects/" + self.project + "/revisions/" + revision)
        self.assertEqual(status, 200, restored)
        self.assertEqual(restored["document"], body["document"])
        self.assertEqual(restored["files"], body["files"])
        self.assertEqual(self.request("PUT", "/v1/projects/" + self.project, body)[1]["revision"], revision)
        run, _ = self.start(revision)
        result = self.wait_run(run)
        self.assertEqual(result["state"], "succeeded", result)
        self.assertEqual(result["result"]["cells"][0]["result"], "42")

    def test_parallel_request_correlation(self):
        self.upload(document())

        def check_request(index):
            for _ in range(10):
                if index % 2:
                    response = rpc(self.root, "project.get", {"project_id": self.project})
                    self.assertEqual(response["status"], 200, response)
                    self.assertEqual(response["data"]["id"], self.project, response)
                else:
                    response = rpc(self.root, "health")
                    self.assertEqual(response["status"], 200, response)
                    self.assertIn("agent_pid", response["data"])

        with ThreadPoolExecutor(max_workers=8) as clients:
            list(clients.map(check_request, range(8)))

    def test_native_cli_upload_run_and_receipt(self):
        def cli(*args):
            result = subprocess.run([OPTIONS.core, "--mode", "cli", "--url",
                                     "http://127.0.0.1:" + str(self.port), "--token-file",
                                     str(self.root / "token"), *args],
                                    universal_newlines=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)

        self.assertEqual(cli("--command", "health")["implementation"], "sputnik")
        source = self.root / (self.project + ".sputnikbook")
        source.mkdir()
        (source / "project.json").write_text(json.dumps(document()))
        (source / "assets").mkdir()
        (source / "assets" / "note.txt").write_text("клиент Sputnik")
        uploaded = cli("--command", "upload", "--project", self.project, "--directory", str(source),
                       "--command-id", "cli-upload")
        args = ("--command", "run", "--project", self.project, "--revision", uploaded["revision"],
                "--command-id", "cli-run")
        run = cli(*args)
        self.assertEqual(cli(*args), run)
        self.assertEqual(cli("--command", "receipt", "--project", self.project,
                             "--command-id", "cli-run")["response"], run)
        result = cli("--command", "wait", "--run-id", run["run_id"])
        self.assertEqual(result["state"], "succeeded", result)
        self.assertTrue((self.root / "token.commands" / "cli-run.json").exists())

    def test_cli_snapshots_dependency_inputs_and_rejects_symlink_parents(self):
        source = self.directory / (self.project + ".sputnikbook")
        source.mkdir()
        (source / "project.json").write_text(json.dumps(document()))
        for name in (".venv", "venv", "vendor/bundle", "vendor/cache", ".bundle"):
            (source / name).mkdir(parents=True)
        for name in (".venv/ignored", "venv/ignored", "vendor/bundle/ignored", "vendor/cache/probe.gem", ".bundle/config"):
            (source / name).write_text("fixture")
        installed = source / "packages/installed/1.0"
        installed.mkdir(parents=True)
        (installed / "modules.index").write_text("sputnik.package.index.v1\n")
        (installed / "manifest.json").write_text("{}")
        (installed / "native-library").write_text("do not upload host binaries")
        local_source = source / "packages/source"
        local_source.mkdir()
        (local_source / "library.s").write_text("package library\n")
        output = self.directory / (self.project + ".prepared.json")
        def prepare():
            return subprocess.run([OPTIONS.core, "--mode", "cli", "--command", "prepare", "--project", self.project,
                "--directory", str(source), "--request-file", str(output), "--token-file", str(self.root / "token")], text=True, capture_output=True, timeout=20)
        prepared = prepare()
        self.assertEqual(prepared.returncode, 0, prepared.stdout + prepared.stderr)
        self.assertEqual(set(json.loads(output.read_text())["files"]), {"vendor/cache/probe.gem", ".bundle/config", "packages/source/library.s"})
        outside = self.directory / (self.project + "-outside")
        (outside / "cache").mkdir(parents=True)
        (outside / "cache/foreign.gem").write_text("must not be uploaded")
        (outside / "config").write_text("must not be uploaded")
        shutil.rmtree(str(source / "vendor"))
        (source / "vendor").symlink_to(outside, target_is_directory=True)
        rejected = prepare()
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("symlink", rejected.stdout + rejected.stderr)
        (source / "vendor").unlink()
        shutil.rmtree(str(source / ".bundle"))
        (source / ".bundle").symlink_to(outside, target_is_directory=True)
        rejected = prepare()
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("symlink", rejected.stdout + rejected.stderr)

    def test_prepared_gui_snapshot_is_immutable_and_can_be_checked_out(self):
        def cli(*args):
            result = subprocess.run([OPTIONS.core, "--mode", "cli", "--json-errors", "--url",
                                     "http://127.0.0.1:" + str(self.port), "--token-file",
                                     str(self.root / "token")] + list(args), universal_newlines=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            reply = json.loads(result.stdout)
            self.assertNotIn("remote_error", reply, reply)
            return reply

        source = self.directory / (self.project + ".sputnikbook")
        (source / "modules").mkdir(parents=True)
        (source / "assets" / "nested").mkdir(parents=True)
        raw = json.dumps(document("answer()\n", modules=True, board=True), ensure_ascii=False)
        (source / "project.json").write_text(raw)
        (source / "modules" / "helpers.s").write_text("package helpers\ndef answer(): 42\nexport answer\n")
        (source / "assets" / "nested" / "data.bin").write_bytes(b"\x00\xff")
        snapshot = self.directory / (self.project + ".snapshot.json")
        unsaved = "package helpers\ndef answer(): 43\nexport answer\n"
        snapshot.write_text(json.dumps({"document": raw, "modules": {"modules/helpers.s": unsaved}}))
        prepared = self.directory / (self.project + ".request.json")
        command = uuid.uuid4().hex
        cli("--command", "prepare", "--project", self.project, "--command-id", command,
            "--directory", str(source), "--snapshot-file", str(snapshot), "--request-file", str(prepared))
        self.assertEqual(self.request("GET", "/v1/projects/" + self.project)[0], 404)
        (source / "assets" / "nested" / "data.bin").write_bytes(b"newer local resource")
        reply = cli("--command", "upload_prepared", "--project", self.project, "--request-file", str(prepared))
        self.assertEqual(cli("--command", "upload_prepared", "--project", self.project,
                             "--request-file", str(prepared)), reply)
        self.assertEqual(cli("--command", "receipt", "--project", self.project, "--command-id", command)["response"], reply)
        run, _ = self.start(reply["revision"])
        self.assertEqual(self.wait_run(run)["result"]["cells"][0]["result"], "43")
        registry = cli("--command", "registry", "--project", self.project)
        compact = registry["runs"][0]
        self.assertEqual(compact["id"], run["run_id"])
        self.assertTrue(compact["has_presentation"])
        self.assertNotIn("result", compact)
        self.assertNotIn("live", compact)
        self.assertNotIn("presentation_path", compact)
        destination = self.directory / (self.project + "-checkout.sputnikbook")
        cli("--command", "checkout", "--project", self.project, "--revision", reply["revision"], "--directory", str(destination))
        self.assertEqual((destination / "project.json").read_text(), raw)
        self.assertEqual((destination / "modules" / "helpers.s").read_text(), unsaved)
        self.assertEqual((destination / "assets" / "nested" / "data.bin").read_bytes(), b"\x00\xff")
        artifact = self.directory / (run["run_id"] + ".bin")
        cli("--command", "presentation", "--run-id", run["run_id"], "--output", str(artifact))
        self.assertIn(b"sputnik.notebook.presentation", artifact.read_bytes()[:80])

    def test_live_presentation_can_be_restored_by_another_client(self):
        revision, _ = self.upload(document('import task\nnotebook.progress("load", 1, 2, "Loading", false)\ntask.sleep(1500)\n42\n'))
        run, _ = self.start(revision)
        def live():
            status, blob = self.request("GET", "/v1/runs/" + run["run_id"] + "/live", binary=True)
            return blob if status == 200 else None
        blob = eventually(live)
        self.assertIn(b"sputnik.notebook.presentation", blob[:80])
        self.assertIn(b"Loading", blob)
        self.assertEqual(self.wait_run(run)["state"], "succeeded")

    def test_disconnected_client_and_restarted_gateway(self):
        revision, _ = self.upload(document("import task\ntask.sleep(1500)\n42\n"))
        run, body = self.start(revision)
        self.wait_run(run, "running")
        self.gateway.terminate()
        self.gateway.wait(timeout=5)
        time.sleep(1.6)  # No HTTP process or connected client exists here.
        type(self).gateway = self.start_gateway()
        status, again = self.request("POST", "/v1/projects/" + self.project + "/runs", body)
        self.assertEqual(status, 200)
        self.assertEqual(again, run)
        result = self.wait_run(run)
        self.assertEqual(result["state"], "succeeded", result)
        self.assertEqual(result["runtime_id"], run["runtime_id"])
        self.assertEqual(result["result"]["cells"][0]["result"], "42")
        registry = self.request("GET", "/v1/projects/" + self.project + "/runs")[1]
        self.assertEqual(registry["runtimes"][0]["state"], "idle")

    def test_lost_response_does_not_duplicate_run(self):
        revision, _ = self.upload(document("import task\ntask.sleep(500)\n42\n"))
        body = {"command_id": uuid.uuid4().hex, "revision": revision, "sheet_id": "main", "cell_id": "1"}
        data = json.dumps(body).encode()
        connection = socket.create_connection(("127.0.0.1", self.port))
        header = ("POST /v1/projects/{}/runs HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {}\r\nContent-Length: {}\r\n\r\n").format(
            self.project, self.token, len(data)).encode()
        connection.sendall(header + data)
        connection.close()  # Do not receive an acknowledgement.
        def accepted_runs():
            status, value = self.request("GET", "/v1/projects/" + self.project + "/runs")
            self.assertEqual(status, 200, value)
            self.assertIn("runs", value)
            return value["runs"]
        run = eventually(accepted_runs)
        status, repeated = self.request("POST", "/v1/projects/" + self.project + "/runs", body)
        self.assertEqual(status, 200, repeated)
        self.assertEqual(repeated["run_id"], run[0]["id"])
        receipt = self.request("GET", "/v1/projects/" + self.project + "/commands/" + body["command_id"])[1]
        self.assertEqual(receipt["response"]["run_id"], repeated["run_id"])
        self.assertEqual(self.request("POST", "/v1/projects/" + self.project + "/runs",
                                     dict(reversed(list(body.items()))))[1]["run_id"], repeated["run_id"])
        self.assertEqual(len(self.request("GET", "/v1/projects/" + self.project + "/runs")[1]["runs"]), 1)
        self.assertEqual(self.wait_run(repeated)["state"], "succeeded")
        changed = dict(body, cell_id="999")
        self.assertEqual(self.request("POST", "/v1/projects/" + self.project + "/runs", changed)[0], 409)

    def test_edit_during_run_and_reuse_live_runtime(self):
        revision, _ = self.upload(document("import task\ntask.sleep(700)\n42\n"))
        run, _ = self.start(revision)
        self.wait_run(run, "running")
        newer, _ = self.upload(document("84\n"), base=revision)
        old = self.wait_run(run)
        self.assertEqual(old["revision"], revision)
        self.assertEqual(old["result"]["cells"][0]["result"], "42")
        next_run, _ = self.start(newer)
        new = self.wait_run(next_run)
        self.assertEqual(new["state"], "succeeded", new)
        self.assertEqual(new["result"]["cells"][0]["result"], "84")
        self.assertEqual(next_run["runtime_id"], run["runtime_id"])
        status, conflict = self.request("PUT", "/v1/projects/" + self.project,
                                       {"command_id": uuid.uuid4().hex, "base_revision": revision,
                                        "document": json.dumps(document("0\n")), "files": {}})
        self.assertEqual(status, 409, conflict)

    def test_stop_force_stop_and_stale_epoch(self):
        revision, _ = self.upload(document("import task\ntask.sleep(60000)\n42\n"))
        run, _ = self.start(revision)
        self.wait_run(run, "running")
        route = "/v1/runs/" + run["run_id"] + "/stop"
        self.assertEqual(self.request("POST", route, {"command_id": uuid.uuid4().hex,
                                                       "runtime_epoch": "stale"})[0], 409)
        status, _ = self.request("POST", route, {"command_id": uuid.uuid4().hex,
                                                "runtime_epoch": run["runtime_epoch"]})
        self.assertEqual(status, 200)
        self.assertEqual(self.wait_run(run)["state"], "cancelled")
        next_run, _ = self.start(revision)
        self.wait_run(next_run, "running")
        status, _ = self.request("POST", "/v1/runs/" + next_run["run_id"] + "/stop",
                                 {"command_id": uuid.uuid4().hex, "runtime_epoch": next_run["runtime_epoch"], "force": True})
        self.assertEqual(status, 200)
        self.assertEqual(self.wait_run(next_run)["state"], "force-stopped")
        self.assertEqual(self.request("POST", "/v1/projects/" + self.project + "/runs",
                                     {"command_id": uuid.uuid4().hex, "revision": revision, "sheet_id": "main", "cell_id": "1"})[0], 409)
        self.assertEqual(self.request("POST", "/v1/projects/" + self.project + "/restart",
                                     {"command_id": uuid.uuid4().hex, "sheet_id": "main",
                                      "runtime_epoch": next_run["runtime_epoch"]})[0], 200)
        newer, _ = self.upload(document("42\n"), base=revision)
        restarted, _ = self.start(newer)
        self.assertNotEqual(restarted["runtime_epoch"], run["runtime_epoch"])
        self.assertEqual(self.wait_run(restarted)["state"], "succeeded")

    def test_deleting_project_stops_owner_and_preserves_history(self):
        revision, _ = self.upload(document("import task\ntask.sleep(60000)\n42\n"))
        run, _ = self.start(revision)
        self.wait_run(run, "running")
        self.assertEqual(self.request("DELETE", "/v1/projects/" + self.project,
                                     {"command_id": uuid.uuid4().hex})[0], 200)
        self.assertEqual(self.wait_run(run)["state"], "force-stopped")
        eventually(lambda: self.request("GET", "/v1/projects/" + self.project)[1]["state"] == "deleted")
        runs = self.request("GET", "/v1/projects/" + self.project + "/runs")[1]
        self.assertEqual(runs["runs"][0]["revision"], revision)
        self.assertTrue(all(r["state"] in ("terminated", "interrupted") for r in runs["runtimes"]), runs)
        events = self.request("GET", "/v1/projects/" + self.project + "/events?after=0")[1]
        self.assertGreater(events["next_seq"], 0)
        self.assertEqual(self.request("GET", "/v1/projects/" + self.project + "/events?after=" + str(events["next_seq"]))[1]["events"], [])

    def cell_document(self, source=None):
        doc = document(board=True)
        doc.update(version=4, dependencies=[])
        def cell(identity, name, value, mode="watch"):
            return dict(id=identity, kind="code", mode=mode,
                        source=name + ' = notebook.cell_input("gain")\n' + name + ' * 2\n',
                        cell_ui=dict(inputs=[dict(id="gain", title="Gain", type="integer", default_json=value, minimum=0, maximum=100),
                                             dict(id="exact", title="Exact", type="integer", default_json="9223372036854775806")],
                                     pre=[dict(id="form", kind="parameter_form", title="Parameters", fields=[dict(input="gain"), dict(input="exact")])],
                                     post=[dict(id="metric", kind="metric", title="Result")]))
        doc["sheets"][0]["cells"] = [cell("1", "a", "2"), cell("2", "b", "5"),
            dict(id="3", kind="code", mode="watch", source="a + b\n"), cell("4", "m", "2", "manual")]
        doc["sheets"][0]["cells"][1]["source"] = 'b = notebook.cell_input("gain")\nb * 3\n'
        if source is not None:
            doc["sheets"][0]["cells"][0]["source"] = source
        return doc

    def input_state(self):
        status, value = self.request("GET", "/v1/projects/" + self.project + "/cell-inputs")
        self.assertEqual(status, 200, value)
        return value

    def input_edit(self, revision, cell, values, version=None, command=None):
        body = dict(command_id=command or uuid.uuid4().hex, revision=revision,
                    base_version=version if version is not None else self.input_state()["version"], cell_id=cell, values=values)
        status, response = self.request("PUT", "/v1/projects/" + self.project + "/cell-inputs", body)
        return status, response, body

    def test_cell_inputs_atomic_watch_manual_scope_and_receipts(self):
        doc = self.cell_document()
        revision, _ = self.upload(doc)
        status, first, _ = self.input_edit(revision, "1", {"gain": "3"})
        self.assertEqual(status, 200, first)
        self.assertNotIn("run_id", first)
        self.assertEqual(self.request("GET", "/v1/projects/" + self.project + "/registry")[1]["runtimes"], [])
        run, _ = self.start(revision, action="run_all")
        result = self.wait_run(run)
        self.assertEqual([c["result"] for c in result["result"]["cells"]], ["6", "15", "8", "4"])
        status, applied, body = self.input_edit(revision, "1", {"gain": "7", "exact": "9223372036854775807"})
        self.assertEqual(status, 200, applied)
        result = self.wait_run(applied)
        self.assertEqual(result["state"], "succeeded", result)
        self.assertEqual([c["result"] for c in result["result"]["cells"]], ["14", "15", "12", "4"])
        self.assertEqual(self.input_state()["values"]["1:exact"], "9223372036854775807")
        self.assertEqual(self.request("PUT", "/v1/projects/" + self.project + "/cell-inputs", body), (200, applied))
        count = len(self.request("GET", "/v1/projects/" + self.project + "/registry")[1]["runs"])
        status, quiet, _ = self.input_edit(revision, "1", {"gain": "7"})
        self.assertEqual(status, 200, quiet)
        self.assertNotIn("run_id", quiet)
        before = self.input_state()
        status, error, _ = self.input_edit(revision, "1", {"gain": "8", "exact": "9223372036854775808"})
        self.assertEqual(status, 422, error)
        self.assertEqual(self.input_state(), before)
        self.assertEqual(len(self.request("GET", "/v1/projects/" + self.project + "/registry")[1]["runs"]), count)
        self.assertEqual(self.input_edit(revision, "1", {"gain": "8"}, version=first["version"])[0], 409)
        self.assertEqual(self.input_edit("obsolete", "1", {"gain": "8"})[0], 409)
        status, manual, _ = self.input_edit(revision, "4", {"gain": "9"})
        self.assertEqual(status, 200, manual)
        result = self.wait_run(manual)
        self.assertEqual(result["state"], "succeeded", result)
        self.assertTrue(result["result"]["cells"][3]["dirty"])
        code_run = dict(command_id=uuid.uuid4().hex, revision=revision, sheet_id="main", cell_id="4", action="run")
        status, explicit = self.request("POST", "/v1/projects/" + self.project + "/runs", code_run)
        self.assertEqual(status, 200, explicit)
        self.assertEqual(self.wait_run(explicit)["result"]["cells"][3]["result"], "18")
        # Configuration edits are inert and do not overwrite accepted values or defaults.
        doc["sheets"][0]["cells"][0]["cell_ui"]["post"].append(dict(id="table", kind="table", title="Data Table"))
        newer, _ = self.upload(doc, base=revision)
        self.assertEqual(self.input_state()["values"]["1:gain"], "7")
        server = self.request("GET", "/v1/projects/" + self.project)[1]
        self.assertEqual(json.loads(server["document"])["sheets"][0]["cells"][0]["cell_ui"]["inputs"][0]["default_json"], "2")
        run, _ = self.start(newer)
        self.assertEqual(self.wait_run(run)["result"]["cells"][0]["result"], "14")

    def test_cell_inputs_busy_runtime_and_frozen_run_snapshot(self):
        doc = self.cell_document('import task\na = notebook.cell_input("gain")\nnotebook.progress("wait", 1, 2, "Waiting", false)\ntask.sleep(1200)\na\n')
        revision, _ = self.upload(doc)
        run, _ = self.start(revision)
        self.wait_run(run, "running")
        before = self.input_state()
        self.assertEqual(self.input_edit(revision, "1", {"gain": "7"})[0], 409)
        self.assertEqual(self.input_state(), before)
        self.assertEqual(self.wait_run(run)["result"]["cells"][0]["result"], "2")
        stored = sqlite3.connect(str(self.root / "metadata.sqlite")).execute("SELECT document FROM run_inputs WHERE run=?", [run["run_id"]]).fetchone()[0]
        served = self.wait_run(run)["execution_document"]
        self.assertEqual(served, stored)
        self.assertEqual(json.loads(stored)["sheets"][0]["cells"][0]["cell_ui"]["inputs"][0]["default_json"], "2")

    def test_cell_inputs_persist_and_revalidate_changed_definitions(self):
        doc = self.cell_document()
        revision, _ = self.upload(doc)
        status, state, _ = self.input_edit(revision, "1", {"gain": "7"})
        self.assertEqual(status, 200, state)
        type(self).agent.terminate()
        type(self).agent.wait(timeout=15)
        type(self).agent = type(self).start_agent()
        self.assertEqual(self.input_state(), {"version": state["version"], "values": state["values"]})
        doc["sheets"][0]["cells"][0]["cell_ui"]["inputs"][0].update(maximum=5)
        newer, _ = self.upload(doc, base=revision)
        self.assertEqual(self.input_state()["values"]["1:gain"], "2")
        self.assertEqual(self.input_state()["values"]["2:gain"], "5")
        self.assertNotEqual(self.input_state()["version"], state["version"])
        run, _ = self.start(newer)
        self.assertEqual(self.wait_run(run)["result"]["cells"][0]["result"], "4")

    def test_unsafe_upload_and_unsupported_inputs(self):
        body = {"command_id": uuid.uuid4().hex, "base_revision": None,
                "document": json.dumps(document()), "files": {"../escape.s": "eA=="}}
        self.assertEqual(self.request("PUT", "/v1/projects/" + self.project, body)[0], 400)
        doc = document(board=True)
        doc["inputs"] = [{"id": "gain", "title": "Gain", "type": "number", "default": 1}]
        revision, _ = self.upload(doc)
        self.assertEqual(self.request("POST", "/v1/projects/" + self.project + "/runs",
                                     {"command_id": uuid.uuid4().hex, "revision": revision, "sheet_id": "main", "cell_id": "1"})[0], 422)

    def test_owner_removal_stops_run_and_prevents_id_reuse(self):
        doc = document("import task\ntask.sleep(60000)\n42\n")
        revision, _ = self.upload(doc)
        run, _ = self.start(revision)
        self.wait_run(run, "running")
        newer_doc = document("84\n")
        newer_doc["sheets"][0]["cells"][0]["id"] = "2"
        newer, _ = self.upload(newer_doc, base=revision)
        self.assertEqual(self.wait_run(run)["state"], "cancelled")
        self.assertEqual(self.request("PUT", "/v1/projects/" + self.project,
                                     {"command_id": uuid.uuid4().hex, "base_revision": newer,
                                      "document": json.dumps(doc), "files": {}})[0], 409)

    def test_stop_during_preparation(self):
        revision, _ = self.upload(document("import task\ntask.sleep(60000)\n42\n"))
        run, _ = self.start(revision)
        status, reply = self.request("POST", "/v1/runs/" + run["run_id"] + "/stop",
                                     {"command_id": uuid.uuid4().hex, "runtime_epoch": run["runtime_epoch"]})
        self.assertEqual(status, 200, reply)
        self.assertEqual(self.wait_run(run)["state"], "cancelled")

    def test_child_failure_is_not_reported_as_success(self):
        revision, _ = self.upload(document("import task\nchild = task.spawn:\n  task.sleep(50)\n  1 / 0\n42\n"))
        run, _ = self.start(revision)
        result = self.wait_run(run)
        self.assertEqual(result["state"], "failed", result)
        self.assertTrue(result["result"]["unobserved_task_failures"])

    def test_runtime_has_a_private_working_directory(self):
        revision, _ = self.upload(document())
        run, _ = self.start(revision)
        result = self.wait_run(run)
        self.assertEqual(result["state"], "succeeded", result)
        registry = self.request("GET", "/v1/projects/" + self.project + "/runs")[1]
        pid = registry["runtimes"][0]["worker_pid"]
        if sys.platform.startswith("linux"):
            actual = str((Path('/proc') / str(pid) / 'cwd').resolve())
        else:
            actual = subprocess.check_output(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn']).decode()
        self.assertIn(run["runtime_id"] + "/work", actual)

    def test_restart_is_durable_before_destroying_heap(self):
        revision, _ = self.upload(document())
        run, _ = self.start(revision)
        self.assertEqual(self.wait_run(run)["state"], "succeeded")
        body = {"command_id": uuid.uuid4().hex, "sheet_id": "main", "runtime_epoch": run["runtime_epoch"]}
        route = "/v1/projects/" + self.project + "/restart"
        with sqlite3.connect(str(self.root / "metadata.sqlite")) as blocker:
            blocker.execute("BEGIN IMMEDIATE")
            status, reply = self.request("POST", route, body)
            self.assertEqual(status, 500, reply)
            blocker.rollback()
        registry = self.request("GET", "/v1/projects/" + self.project + "/runs")[1]
        self.assertEqual(registry["runtimes"][0]["state"], "idle")
        self.assertIsNotNone(registry["runtimes"][0]["worker_pid"])
        self.assertEqual(self.request("POST", route, body)[0], 200)
        newer, _ = self.start(revision)
        self.assertEqual(self.wait_run(newer)["state"], "succeeded")
        self.assertNotEqual(newer["runtime_epoch"], run["runtime_epoch"])
        self.assertEqual(self.request("POST", route, body)[0], 200)
        current = self.request("GET", "/v1/projects/" + self.project + "/runs")[1]["runtimes"][-1]
        self.assertEqual(current["epoch"], newer["runtime_epoch"])
        self.assertEqual(current["state"], "idle")

    def test_restart_then_delete_waits_for_all_runtime_owners(self):
        revision, _ = self.upload(document())
        for _ in range(3):
            run, _ = self.start(revision)
            self.assertEqual(self.wait_run(run)["state"], "succeeded")
            self.assertEqual(self.request("POST", "/v1/projects/" + self.project + "/restart",
                                         {"command_id": uuid.uuid4().hex, "sheet_id": "main",
                                          "runtime_epoch": run["runtime_epoch"]})[0], 200)
        self.assertEqual(self.request("DELETE", "/v1/projects/" + self.project,
                                     {"command_id": uuid.uuid4().hex})[0], 200)
        eventually(lambda: self.request("GET", "/v1/projects/" + self.project)[1]["state"] == "deleted")
        records = self.request("GET", "/v1/projects/" + self.project + "/runs")[1]["runtimes"]
        self.assertEqual(len(records), 3)
        self.assertTrue(all(r["state"] in ("terminated", "interrupted") and r["worker_pid"] is None
                            for r in records), records)

    def test_z_agent_failure_is_interrupted_without_replay(self):
        revision, _ = self.upload(document("import task\ntask.sleep(60000)\n42\n"))
        route = "/v1/projects/" + self.project + "/worker-settings/main"
        settings = self.request("GET", route)[1]
        self.assertEqual(self.request("PUT", route, dict(command_id=uuid.uuid4().hex,
            grants=["process.spawn=/usr/bin/printf"], base_version=settings["version"], runtime_epoch=None))[0], 200)
        run, body = self.start(revision)
        self.wait_run(run, "running")
        self.agent.kill()
        self.agent.wait(timeout=5)
        type(self).agent = self.start_agent()
        self.assertEqual(self.request("GET", route)[1]["grants"], ["process.spawn=/usr/bin/printf"], "grants survive an agent restart")
        interrupted = self.wait_run(run)
        self.assertEqual(interrupted["state"], "interrupted")
        self.assertIn("not replayed", interrupted["error"])
        self.assertEqual(self.request("GET", "/v1/projects/" + self.project + "/runs")[1]["runtimes"][0]["state"], "interrupted")
        self.assertEqual(self.request("POST", "/v1/projects/" + self.project + "/runs", body)[1]["run_id"], run["run_id"])
        self.assertEqual(len(self.request("GET", "/v1/projects/" + self.project + "/runs")[1]["runs"]), 1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", required=True)
    parser.add_argument("--core", required=True)
    parser.add_argument("--python", default=shutil.which("python3.14") or sys.executable)
    parser.add_argument("--ruby", default=shutil.which("ruby") or "ruby")
    parser.add_argument("--bridges", action="store_true", help="also load installed sibling pycall/rbcall in the managed worker")
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--failfast", action="store_true")
    parser.add_argument("--test", help="run one unittest selector")
    OPTIONS = parser.parse_args()
    unittest.main(argv=[sys.argv[0]] + ([OPTIONS.test] if OPTIONS.test else []), verbosity=2, failfast=OPTIONS.failfast)
