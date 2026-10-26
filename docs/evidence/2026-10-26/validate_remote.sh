#!/bin/bash
set -euo pipefail
release_dir=$(cd "$(dirname "$0")" && pwd)
cd "$release_dir"
mkdir -p tmp native-rt-cache native-ext-cache
export TMPDIR="$release_dir/tmp"
export SPUTNIK_NATIVE_RT_CACHE="$release_dir/native-rt-cache"
export SPUTNIK_NATIVE_EXT_CACHE="$release_dir/native-ext-cache"
export CXX=/home/slowpilot/sputnik-remote-core/cxx
export REMOTE_NATIVE_CXX="$CXX"
export SPUTNIK_NATIVE_CXX="$CXX"
export OPENSSL_PREFIX=/home/slowpilot/sputnik-remote-core/deps/openssl
export LD_LIBRARY_PATH="$OPENSSL_PREFIX/lib:${LD_LIBRARY_PATH:-}"
(
 cd src/sputnik-lang
 build/parser_tests
 build/vm_tests
 build/isputnik_tests
 /usr/bin/python3.11 tests/external_templates_test.py build/sputnik
 /usr/bin/python3.11 tests/string_template_loops_test.py build/sputnik
) > language-tests.log 2>&1
(
 cd src/sputnik-notebook
 /usr/bin/python3.11 tests/notebook_remote_tests.py --worker "$release_dir/sputnik-notebook-worker" --core "$release_dir/sputnik-notebook-remote"
) > remote-tests.log 2>&1
(
 cd src/orbit
 ../sputnik-lang/build/sputnik run test/external_templates_selftest.build.yaml
 ../sputnik-lang/build/sputnik build test/external_templates_selftest.build.yaml --target native --require-full-native --out-dir "$release_dir/orbit-native" --cache-dir "$release_dir/orbit-cache" > "$release_dir/orbit-native-build.json"
 "$release_dir/orbit-native/app.external_templates"
) > orbit-template-tests.log 2>&1
/usr/bin/python3.11 - <<'PYBUILD'
from pathlib import Path
import hashlib,json,datetime
r=Path.cwd()
native=json.loads((r/'orbit-native-build.json').read_text())
assert native['native_graph_full_coverage'] and native['native_graph_vm_independent']
assert not native['native_bytecode_fallback'] and not native['native_graph_runtime_bridge']
manifest=json.loads((r/'release.json').read_text())
manifest['built_at']=datetime.datetime.now(datetime.timezone.utc).isoformat()
manifest['binaries']={name:hashlib.sha256((r/name).read_bytes()).hexdigest() for name in ['sputnik','sputnik-notebook-worker','sputnik-notebook-remote']}
manifest['checks']={'language_tests':'passed','remote_integration':'passed'}
manifest['additional_checks']={'orbit_html_sql_cmd_vm_and_full_native':'passed','test_python':'3.11'}
(r/'build-result.json').write_text(json.dumps(manifest,indent=2)+'\n')
PYBUILD
printf 'BUILD_AND_TESTS_PASSED\n'
