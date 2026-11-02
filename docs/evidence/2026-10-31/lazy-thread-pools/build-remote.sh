#!/bin/bash
set -euo pipefail
release=/home/slowpilot/sputnik-releases/20261031-lazy-thread-pools
previous=/home/slowpilot/sputnik-releases/20261030-auto-5d291d7
test ! -e "$release/src"
exec >"$release/build.log" 2>&1
trap 'rc=$?; if test "$rc" -ne 0; then echo "BUILD_FAILED exit=$rc line=$LINENO"; fi' EXIT
cp -a --reflink=auto "$previous/src" "$release/src"
cp -p "$previous/cxx" "$release/cxx"
cp -a "$previous/test-bin" "$release/test-bin"
python3 - "$release" "$previous" <<'INNER'
from pathlib import Path
import sys,hashlib
r,p=map(Path,sys.argv[1:])
assert hashlib.sha256((r/'thread-pools.patch').read_bytes()).hexdigest()=='6954924a4634e710c8abbc177c88cf6c2b443fd3a19c1321d55331473c0466e3'
(r/'env.sh').write_text((p/'env.sh').read_text().replace(str(p),str(r)))
INNER
cd "$release/src/sputnik-lang"
patch --dry-run -p1 < "$release/thread-pools.patch"
patch -p1 < "$release/thread-pools.patch"
. "$release/env.sh"
export PATH="$release/test-bin:$PATH"
options=(CXX="$release/cxx" PCRE2_INCLUDE_DIR=/home/slowpilot/sputnik-remote-core/deps/pcre2-10.47/include PCRE2_LIB_DIR=/home/slowpilot/sputnik-remote-core/deps/pcre2-10.47/lib)
make -j6 "${options[@]}" build/sputnik build/stdlib_task_tests build/blocking_ffi_tests build/vm_tests build/sputnik_ext_tests
for suite in stdlib_task_tests blocking_ffi_tests vm_tests sputnik_ext_tests; do
  echo "RUN $suite"
  "build/$suite" >"$release/$suite.log" 2>&1
done
make -j6 "${options[@]}" test-native-blocking >"$release/native-blocking.log" 2>&1
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
report={'release':str(r),'base_release':str(p),'checks':{'language':'passed','vm_and_full_native_ffi':'passed','remote_api':'passed'},'sha256':{}}
for name in ['thread-pools.patch','sputnik-notebook-worker','sputnik-notebook-remote','src/sputnik-lang/build/sputnik']:
 report['sha256'][name]=hashlib.sha256((r/name).read_bytes()).hexdigest()
(r/'release.json').write_text(json.dumps(report,indent=2)+'\n')
INNER
echo BUILD_AND_TESTS_COMPLETE
