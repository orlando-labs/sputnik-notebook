#!/bin/bash
set -euo pipefail
release=/home/slowpilot/sputnik-releases/20261029-head-3eb0f05
. "$release/env.sh"
export LIBTORCH_PREFIX=/usr/local/lib64/python3.12/site-packages/torch
export LD_LIBRARY_PATH="$LIBTORCH_PREFIX/lib:${LD_LIBRARY_PATH:-}"
export SPUTNIK_ROOT="$release/src/sputnik-lang"
export ROCBLAS_TENSILE_LIBPATH=/home/slowpilot/sputnik-remote-core/deps/rocblas-gfx906/opt/rocm-6.3.4/lib/rocblas/library
cd "$release/src/torch"
exec >"$release/torch-tests.log" 2>&1
trap 'rc=$?; if test "$rc" -ne 0; then printf "TORCH_TESTS_FAILED exit=%s line=%s\n" "$rc" "$LINENO"; fi' EXIT
./tools/test-rocm --torch-prefix "$LIBTORCH_PREFIX" --sputnik-root "$SPUTNIK_ROOT" --devices '0 1 2' --native-library "$release/src/torch/build/rocm-package-native/libtorch_notebook.so"
HIP_VISIBLE_DEVICES=0 ./tools/package --backend rocm --native prebuilt --modules source --bundle none --torch-prefix "$LIBTORCH_PREFIX" --sputnik-root "$SPUTNIK_ROOT" --version 0.1.3-rocm-local --out-dir "$release/torch-package"
printf 'TORCH_TESTS_COMPLETE\n'
