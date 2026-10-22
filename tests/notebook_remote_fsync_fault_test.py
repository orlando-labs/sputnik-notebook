#!/usr/bin/env python3
"""Linux regression: a real directory fsync EIO must precede metadata commit.

Uses strace syscall injection against an isolated native agent, never the
deployed service. Python is test orchestration only.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid

from notebook_remote_tests import document, eventually, rpc


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", required=True)
    parser.add_argument("--worker", required=True)
    parser.add_argument("--keep", action="store_true")
    options = parser.parse_args()
    if not sys.platform.startswith("linux") or not shutil.which("strace"):
        parser.error("Linux and strace with syscall injection are required")
    directory = Path(tempfile.mkdtemp(prefix="spr-fsync-", dir="/tmp"))
    root = directory / "state"
    processes, logs = [], []

    def start(inject=False):
        command = [options.core, "--mode", "agent", "--root", str(root), "--worker", options.worker]
        if inject:
            # A PUT with one nested file performs four atomic-write fsyncs,
            # then syncs the leaf and its deepest directory. Existing state
            # startup performs fewer than six fsyncs on its separate thread.
            command = ["strace", "-ff", "-yy", "-e", "trace=fsync",
                       "-e", "inject=fsync:error=EIO:when=6",
                       "-o", str(directory / "fsync.trace")] + command
        log = (directory / (uuid.uuid4().hex + ".log")).open("wb")
        logs.append(log)
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log,
                                   stderr=log, start_new_session=True)
        processes.append(process)
        eventually(lambda: process.poll() is None and rpc(root, "health")["status"] == 200)
        return process

    def stop(process):
        # Every child belongs to this test's explicitly created session.
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=15)
        eventually(lambda: not (root / "agent.sock").exists() or
                   not process_exists(root))

    def process_exists(state):
        try:
            return rpc(state, "health")["status"] == 200
        except OSError:
            return False

    try:
        project = "sync_fault_" + uuid.uuid4().hex
        first = start()
        original = rpc(root, "project.put", {"project_id": project, "command_id": uuid.uuid4().hex,
                       "base_revision": None, "document": json.dumps(document()), "files": {}})
        assert original["status"] == 200, original
        revision = original["data"]["revision"]
        stop(first)

        traced = start(inject=True)
        command = uuid.uuid4().hex
        update = {"project_id": project, "command_id": command, "base_revision": revision,
                  "document": json.dumps(document("43\n")),
                  "files": {"assets/deep/payload.bin": "AAECAw=="}}
        failed = rpc(root, "project.put", update)
        assert failed["status"] == 500 and "fs.sync" in failed["error"], failed
        assert rpc(root, "project.get", {"project_id": project})["data"]["head"] == revision
        assert rpc(root, "receipt.get", {"project_id": project, "command_id": command})["status"] == 404
        stop(traced)
        trace = "\n".join(path.read_text() for path in directory.glob("fsync.trace.*"))
        injected = [line for line in trace.splitlines() if "INJECTED" in line]
        assert len(injected) == 1 and "/assets/deep>" in injected[0], injected

        recovered = start()
        assert rpc(root, "project.get", {"project_id": project})["data"]["head"] == revision
        assert rpc(root, "receipt.get", {"project_id": project, "command_id": command})["status"] == 404
        retried = rpc(root, "project.put", update)
        assert retried["status"] == 200, retried
        assert rpc(root, "project.put", update) == retried
        receipt = rpc(root, "receipt.get", {"project_id": project, "command_id": command})
        assert receipt["status"] == 200, receipt
        stop(recovered)
        print("PASS directory fsync EIO preserves head and receipt; retry survives agent restart")
        return 0
    finally:
        for process in processes:
            if process.poll() is None:
                stop(process)
        for log in logs:
            log.close()
        if options.keep:
            print("fsync fault test state: " + str(directory))
        else:
            shutil.rmtree(str(directory))


if __name__ == "__main__":
    sys.exit(main())
