#!/usr/bin/env python3
"""Native SwiftUI/model tests against an isolated real Sputnik remote core."""
import argparse
import shutil
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace

import notebook_remote_tests as fixture


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--test", required=True)
    parser.add_argument("--core", required=True)
    parser.add_argument("--worker", required=True)
    parser.add_argument("--keep", action="store_true")
    options = parser.parse_args()
    fixture.OPTIONS = SimpleNamespace(core=options.core, worker=options.worker, keep=options.keep, bridges=False, python=shutil.which("python3.14") or sys.executable, ruby=shutil.which("ruby") or "ruby")
    host = fixture.RemoteTests
    host.setUpClass()
    try:
        root = host.directory / "client"
        root.mkdir()
        wrapper = root / "lost-reply-client"
        wrapper.write_text("#!" + sys.executable + "\n" +
                           "import json, pathlib, subprocess, sys\n" +
                           "args=sys.argv[1:]\n" +
                           "result=subprocess.run([" + repr(options.core) + "]+args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)\n" +
                           "marker=pathlib.Path(" + repr(str(root / "reply-dropped")) + ")\n" +
                           "if '--command' in args and args[args.index('--command')+1]=='run' and result.returncode==0 and not marker.exists():\n" +
                           " value=json.loads(result.stdout.decode())\n" +
                           " if 'run_id' in value:\n  marker.touch()\n  sys.exit(74)\n" +
                           "sys.stdout.buffer.write(result.stdout)\nsys.stderr.buffer.write(result.stderr)\nsys.exit(result.returncode)\n")
        wrapper.chmod(0o700)
        result = subprocess.run([options.test, "--root", str(root), "--core", options.core,
                                 "--worker", options.worker, "--url", "http://127.0.0.1:" + str(host.port),
                                 "--token", str(host.root / "token"), "--fault-core", str(wrapper)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=180)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        if options.keep:
            print("remote UI artifacts: " + str(root))
        return result.returncode
    finally:
        host.tearDownClass()


if __name__ == "__main__":
    sys.exit(main())
