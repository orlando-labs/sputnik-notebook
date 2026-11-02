#!/bin/bash
set -euo pipefail
app_root=/home/slowpilot/sputnik-remote-core
transfer=$app_root/transfer
release=/ssd1Tb/sputnik-remote-core-releases/20261029-membership
previous=/ssd1Tb/sputnik-remote-core-releases/20261028-regexp-77650e1
pcre_prefix=$app_root/deps/pcre2-10.47
test "$(readlink -f "$app_root/current")" = "$previous"
mkdir "$release"
mkdir "$release/src"
exec >"$release/build.log" 2>&1
trap 'rc=$?; if test "$rc" -ne 0; then printf "BUILD_FAILED exit=%s line=%s\n" "$rc" "$LINENO"; fi' EXIT
python3 - "$transfer" <<'PY'
from pathlib import Path
import hashlib,json,sys
t=Path(sys.argv[1]); manifest=json.loads((t/'sputnik-membership-transfer.json').read_text())
assert manifest['language_commit']=='7f2665b8d1538bf6b4667920cafe752d676d8782'
assert hashlib.sha256((t/'sputnik-membership-source.tar.gz').read_bytes()).hexdigest()==manifest['archive_sha256']
print('Verified committed language source archive',manifest['language_commit'],flush=True)
PY
mkdir "$release/src/sputnik-lang"
tar -xzf "$transfer/sputnik-membership-source.tar.gz" -C "$release/src/sputnik-lang"
for name in sputnik-notebook sqlite3 orm orbit; do
  mkdir "$release/src/$name"
  rsync -a --exclude='.git' --exclude='build' --exclude='build-*' --exclude='.build' --exclude='node_modules' "$previous/src/$name/" "$release/src/$name/"
done
openssl_lib=$app_root/deps/openssl/lib
if test -d "$app_root/deps/openssl/lib64"; then openssl_lib=$app_root/deps/openssl/lib64; fi
cat >"$release/cxx" <<EOF
#!/bin/sh
exec $app_root/cxx "\$@" -Wl,-rpath,$openssl_lib -Wl,-rpath,$pcre_prefix/lib
EOF
chmod 755 "$release/cxx"
cat >"$release/env.sh" <<EOF
export SPUTNIK_NATIVE_CXX=$release/cxx
export SPUTNIK_NATIVE_RT_JOBS=6
export SPUTNIK_NATIVE_RT_CACHE=$release/native-rt-cache
export SPUTNIK_NATIVE_EXT_CACHE=$release/native-ext-cache
export PKG_CONFIG_PATH=$pcre_prefix/lib/pkgconfig:\${PKG_CONFIG_PATH:-}
export LD_LIBRARY_PATH=$pcre_prefix/lib:$openssl_lib:\${LD_LIBRARY_PATH:-}
EOF
. "$release/env.sh"
build_options=(CXX="$release/cxx" OPENSSL_PREFIX="$app_root/deps/openssl" OPENSSL_LIB_DIR="$openssl_lib" PCRE2_INCLUDE_DIR="$pcre_prefix/include" PCRE2_LIB_DIR="$pcre_prefix/lib")
make -j6 -C "$release/src/sputnik-lang" "${build_options[@]}" build/sputnik build/sputniktest build/binder_tests build/hir_tests build/emitter_tests build/vm_tests build/notebook_compiler_tests build/notebook_vm_integration_tests
make -j6 -C "$release/src/sputnik-notebook" "${build_options[@]}" remote-core
cp "$release/src/sputnik-notebook/build/sputnik-notebook-worker" "$release/sputnik-notebook-worker"
cp "$release/src/sputnik-notebook/build/sputnik-notebook-remote" "$release/sputnik-notebook-remote"
python3 - "$release" "$transfer" "$previous" <<'PY'
from pathlib import Path
import json,sys,hashlib
r,t,p=map(Path,sys.argv[1:]); report=json.loads((t/'sputnik-membership-transfer.json').read_text())
old=json.loads((p/'release.json').read_text())
report.update(release=str(r),base_release=p.name,notebook_commit=old['notebook_commit'],pcre2_version=old['pcre2_version'],sha256={})
for name in ['sputnik-notebook-worker','sputnik-notebook-remote','src/sputnik-lang/build/sputnik']:
 report['sha256'][name]=hashlib.sha256((r/name).read_bytes()).hexdigest()
(r/'release.json').write_text(json.dumps(report,indent=2)+'\n')
PY
printf 'BUILD_COMPLETE\n'
exec >"$release/tests.log" 2>&1
trap 'rc=$?; if test "$rc" -ne 0; then printf "TESTS_FAILED exit=%s line=%s\n" "$rc" "$LINENO"; fi' EXIT
mkdir "$release/test-bin"
ln -s /usr/bin/python3.12 "$release/test-bin/python3"
export PATH="$release/test-bin:$PATH"
cd "$release/src/sputnik-lang"
for name in binder_tests hir_tests emitter_tests vm_tests notebook_compiler_tests notebook_vm_integration_tests; do
  printf 'RUN %s\n' "$name"
  "build/$name"
done
build/sputniktest run corpus/run/membership
python3 tests/native_membership_test.py build/sputnik
cd "$release/src/sputnik-notebook"
python3 - "$transfer" <<'PY'
from pathlib import Path
import sys
p=Path('tests/notebook_remote_tests.py'); s=p.read_text()
if 'def test_membership_methods_and_nested_patterns' not in s:
 pos=s.index('    def test_'); s=s[:pos]+(Path(sys.argv[1])/'sputnik-membership-notebook-test.txt').read_text()+s[pos:]; p.write_text(s)
PY
python3 tests/notebook_remote_tests.py --worker "$release/sputnik-notebook-worker" --core "$release/sputnik-notebook-remote"
printf 'TESTS_COMPLETE\n'
