#!/bin/bash
set -euo pipefail
base=/home/slowpilot/sputnik-remote-core
transfer=$base/transfer
host=$(hostname)
if test "$host" = dev-ai-amd; then
  release=/home/slowpilot/sputnik-releases/20261029-vm-7d4168d
  cxx=/usr/bin/g++
  openssl_prefix=/usr
  openssl_lib=/usr/lib64
else
  release=/ssd1Tb/sputnik-remote-core-releases/20261029-vm-7d4168d
  cxx=$base/cxx
  openssl_prefix=$base/deps/openssl
  openssl_lib=$openssl_prefix/lib
fi
pcre=$base/deps/pcre2-10.47
mkdir "$release"
mkdir "$release/src"
exec >"$release/build.log" 2>&1
trap 'rc=$?; if test "$rc" -ne 0; then printf "BUILD_FAILED exit=%s line=%s\n" "$rc" "$LINENO"; fi' EXIT
python3 - "$transfer" <<'PY'
from pathlib import Path
import hashlib,json,sys
t=Path(sys.argv[1]);m=json.loads((t/'sputnik-vm-workspace-source.json').read_text())
assert hashlib.sha256((t/'sputnik-vm-workspace-source.tar.gz').read_bytes()).hexdigest()==m['archive_sha256']
print('Verified workspace snapshot',m['baseline_commit'],m['source_identity'],flush=True)
PY
mkdir "$release/src/sputnik-lang"
tar -xzf "$transfer/sputnik-vm-workspace-source.tar.gz" -C "$release/src/sputnik-lang"
tar -xzf "$transfer/sputnik-notebook-stable-sources.tar.gz" -C "$release/src"
cat >"$release/cxx" <<EOF
#!/bin/sh
exec $cxx "\$@" -O1 -Wl,-rpath,$openssl_lib -Wl,-rpath,$pcre/lib
EOF
chmod 755 "$release/cxx"
cat >"$release/env.sh" <<EOF
export SPUTNIK_NATIVE_CXX=$release/cxx
export SPUTNIK_NATIVE_RT_JOBS=6
export SPUTNIK_NATIVE_RT_CACHE=$release/native-rt-cache
export SPUTNIK_NATIVE_EXT_CACHE=$release/native-ext-cache
export PKG_CONFIG_PATH=$pcre/lib/pkgconfig:\${PKG_CONFIG_PATH:-}
export LD_LIBRARY_PATH=$pcre/lib:$openssl_lib:\${LD_LIBRARY_PATH:-}
EOF
. "$release/env.sh"
options=(CXX="$release/cxx" OPENSSL_PREFIX="$openssl_prefix" OPENSSL_LIB_DIR="$openssl_lib" PCRE2_INCLUDE_DIR="$pcre/include" PCRE2_LIB_DIR="$pcre/lib")
make -j6 -C "$release/src/sputnik-lang" "${options[@]}" build/sputnik build/isputnik build/sputniktest build/binder_tests build/vm_tests build/notebook_compiler_tests build/notebook_vm_integration_tests
make -j6 -C "$release/src/sputnik-notebook" "${options[@]}" remote-core
cp "$release/src/sputnik-notebook/build/sputnik-notebook-worker" "$release/sputnik-notebook-worker"
cp "$release/src/sputnik-notebook/build/sputnik-notebook-remote" "$release/sputnik-notebook-remote"
python3 - "$release" "$transfer" <<'PY'
from pathlib import Path
import hashlib,json,sys
r,t=map(Path,sys.argv[1:]);m=json.loads((t/'sputnik-vm-workspace-source.json').read_text());m.pop('files')
m.update(release=str(r),language_commit=m['baseline_commit'],notebook_commit='a877de60beec13db3e97b0862f41d82c4d5a070d',pcre2_version='10.47',sha256={})
for name in ['sputnik-notebook-worker','sputnik-notebook-remote','src/sputnik-lang/build/sputnik','src/sputnik-lang/build/isputnik']:
 m['sha256'][name]=hashlib.sha256((r/name).read_bytes()).hexdigest()
(r/'release.json').write_text(json.dumps(m,indent=2)+'\n')
PY
printf 'BUILD_COMPLETE\n'
exec >"$release/tests.log" 2>&1
trap 'rc=$?; if test "$rc" -ne 0; then printf "TESTS_FAILED exit=%s line=%s\n" "$rc" "$LINENO"; fi' EXIT
mkdir "$release/test-bin"
ln -s /usr/bin/python3.12 "$release/test-bin/python3"
export PATH="$release/test-bin:$PATH"
cd "$release/src/sputnik-lang"
for name in binder_tests vm_tests notebook_compiler_tests notebook_vm_integration_tests; do
 printf 'RUN %s\n' "$name"; "build/$name"
done
build/sputniktest run corpus/run/membership
python3 tests/native_membership_test.py build/sputnik
cd "$release/src/sputnik-notebook"
python3 - "$transfer" <<'PY'
from pathlib import Path
import re,sys
p=Path('tests/notebook_remote_tests.py');s=p.read_text()
if 'def test_membership_methods_and_nested_patterns' not in s:
 pos=s.index('    def test_');s=s[:pos]+(Path(sys.argv[1])/'sputnik-membership-notebook-test.txt').read_text()+s[pos:]
# The newer package store advertises its selected variant in the inventory.
old='self.assertTrue((self.root / "projects" / self.project / "packages/notebook-probe/1.0.0/modules.index").exists())'
new='package_root = self.root / "projects" / self.project / "packages/notebook-probe/1.0.0"\n        if packages[0].get("variant"):\n            package_root /= packages[0]["variant"]\n        self.assertTrue((package_root / "modules.index").exists())'
s=s.replace(old,new)
replacement=(Path(sys.argv[1])/'sputnik-remote-package-test.txt').read_text()
s=re.sub(r'(?ms)^    def test_dependency_packages_install_remove_receipts_and_worker_imports\(self\):.*?(?=^    def |\Z)',lambda _:replacement,s)
p.write_text(s)
PY
python3 tests/notebook_remote_tests.py --worker "$release/sputnik-notebook-worker" --core "$release/sputnik-notebook-remote"
printf 'TESTS_COMPLETE\n'
