#!/usr/bin/env python3
"""Portable core cwd launcher keeps shell metacharacters literal in VM/native."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

notebook = Path(__file__).resolve().parents[1]
sdk = Path(sys.argv[1] if len(sys.argv) > 1 else notebook.parent / 'sputnik-lang/build/sputnik').resolve()
with tempfile.TemporaryDirectory(prefix='sputnik-core-command-', dir='/tmp') as temporary:
    root = Path(temporary)
    directory = root / "space ; $(touch SHOULD_NOT_EXIST) ' quoted"
    directory.mkdir()
    literal = 'literal $(touch ALSO_NOT_CREATED); "quotes"'
    source = root / 'check.s'
    source.write_text('''package test.remote_command
from notebook.remote.common import command_at
export main

def main():
  directory = %s
  literal = %s
  result = command_at(directory, "/bin/sh", ["-c", "printf '%%s\\n%%s\\n' \\\"$PWD\\\" \\\"$1\\\"", "child", literal], {"LAUNCHER_TEST": "literal"}).capture(timeout: 10.0)
  raise ValueError("cwd or argv changed") unless result.stdout.to_str == directory + "\\n" + literal + "\\n"
  environment = command_at(directory, "/bin/sh", ["-c", "printf %%s \\\"$LAUNCHER_TEST\\\""], {"LAUNCHER_TEST": literal}).capture(timeout: 10.0)
  raise ValueError("environment changed") unless environment.stdout.to_str == literal
  failed = command_at(directory + "/missing", "/usr/bin/printf", ["must not run"]).capture(timeout: 10.0, check: false)
  raise ValueError("missing cwd ran command") if failed.success? or failed.stdout.to_str.contains?("must not run")
  print("PASS literal cwd, argv, env and missing directory")
  0
''' % (json.dumps(str(directory)), json.dumps(literal)))
    manifest = root / 'sputnik.build.json'
    manifest.write_text(json.dumps(dict(schema='sputnik.build.v1', name='test.remote_command', root='test.remote_command', modules=[
        dict(name='test.remote_command', path=str(source)),
        dict(name='notebook.remote.common', path=str(notebook / 'tools/notebook-remote/common.s'))])))
    def run(*arguments):
        result = subprocess.run(list(map(str, arguments)), capture_output=True, text=True, timeout=180)
        assert result.returncode == 0, result.stdout + result.stderr
        return result.stdout
    assert 'PASS literal cwd' in run(sdk, 'run', manifest, '--grant', 'process.spawn')
    report = json.loads(run(sdk, 'build', manifest, '--target', 'native', '--require-full-native', '--grant', 'process.spawn', '--out-dir', root / 'build'))
    assert report['native_graph_full_coverage'], report
    assert 'PASS literal cwd' in run(root / 'build/test.remote_command')
    assert not list(root.rglob('SHOULD_NOT_EXIST'))
    assert not list(root.rglob('ALSO_NOT_CREATED'))
print('notebook_remote_command_test: VM and full native passed')
