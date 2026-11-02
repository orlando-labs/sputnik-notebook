#!/bin/bash
set -euo pipefail
release=/home/slowpilot/sputnik-releases/20261031-current-c17d12b
previous=/home/slowpilot/sputnik-releases/20261030-auto-5d291d7
test ! -e "$release/src"
exec >"$release/build.log" 2>&1
trap 'rc=$?; if test "$rc" -ne 0; then echo "BUILD_FAILED exit=$rc line=$LINENO"; fi' EXIT
mkdir "$release/src"
for name in sputnik-notebook sqlite3 orm orbit torch; do
  cp -a --reflink=auto "$previous/src/$name" "$release/src/$name"
done
mkdir "$release/src/sputnik-lang"
tar -xzf "$release/language-source.tar.gz" -C "$release/src/sputnik-lang"
cp -p "$previous/cxx" "$release/cxx"
cp -a "$previous/test-bin" "$release/test-bin"
python3 - "$release" "$previous" <<'INNER'
from pathlib import Path
import sys,hashlib
r,p=map(Path,sys.argv[1:])
assert hashlib.sha256((r/'language-source.tar.gz').read_bytes()).hexdigest()=='2ae52041473e24ef27faf57e4b7b2a9cc009dbac3503244ea2acc6814d834439'
(r/'env.sh').write_text((p/'env.sh').read_text().replace(str(p),str(r)))
INNER
cd "$release/src/sputnik-lang"
. "$release/env.sh"
export PATH="$release/test-bin:$PATH"
options=(CXX="$release/cxx" PCRE2_INCLUDE_DIR=/home/slowpilot/sputnik-remote-core/deps/pcre2-10.47/include PCRE2_LIB_DIR=/home/slowpilot/sputnik-remote-core/deps/pcre2-10.47/lib)
make -j6 "${options[@]}" build/sputnik build/isputnik build/stdlib_task_tests build/blocking_ffi_tests build/vm_tests build/sputnik_ext_tests build/binder_tests build/emitter_tests build/hir_tests build/package_selection_tests build/language_version_tests
for suite in stdlib_task_tests blocking_ffi_tests vm_tests sputnik_ext_tests binder_tests emitter_tests hir_tests package_selection_tests language_version_tests; do
  echo "RUN $suite"
  "build/$suite" >"$release/$suite.log" 2>&1
done
make -j6 "${options[@]}" test-native-blocking >"$release/native-blocking.log" 2>&1
make -j6 "${options[@]}" test-language-version >"$release/language-version.log" 2>&1
echo LANGUAGE_TESTS_COMPLETE
make -j6 -C ../sputnik-notebook "${options[@]}" remote-core
cp ../sputnik-notebook/build/sputnik-notebook-worker "$release/sputnik-notebook-worker"
cp ../sputnik-notebook/build/sputnik-notebook-remote "$release/sputnik-notebook-remote"
echo CORE_BUILD_COMPLETE
cd ../sputnik-notebook
python3 tests/notebook_remote_tests.py --worker "$release/sputnik-notebook-worker" --core "$release/sputnik-notebook-remote" >"$release/remote-api-tests.log" 2>&1
python3 - "$release" "$previous" <<'INNER'
from pathlib import Path
import sys,hashlib,json
r,p=map(Path,sys.argv[1:])
report={'release':str(r),'base_release':str(p),'language_commit':'c17d12b2e25c2dd2cb0b9e41835b0a8e33925573','checks':{'language':'passed','vm_and_full_native_ffi':'passed','remote_api':'passed'},'sha256':{}}
for name in ['language-source.tar.gz','sputnik-notebook-worker','sputnik-notebook-remote','src/sputnik-lang/build/sputnik','src/sputnik-lang/build/isputnik']:
 report['sha256'][name]=hashlib.sha256((r/name).read_bytes()).hexdigest()
(r/'release.json').write_text(json.dumps(report,indent=2)+'\n')
INNER
echo BUILD_AND_TESTS_COMPLETE
