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
make -C src/sputnik-lang -j8 build/sputnik build/parser_tests build/vm_tests build/isputnik_tests
make -C src/sputnik-notebook -j8 remote-core
cp src/sputnik-lang/build/sputnik ./sputnik
cp src/sputnik-notebook/build/sputnik-notebook-worker ./sputnik-notebook-worker
cp src/sputnik-notebook/build/sputnik-notebook-remote ./sputnik-notebook-remote
/bin/bash "$release_dir/validate_remote.sh"
