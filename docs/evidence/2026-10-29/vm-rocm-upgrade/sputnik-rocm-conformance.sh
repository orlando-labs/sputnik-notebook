#!/bin/bash
set -euo pipefail
release=/home/slowpilot/sputnik-releases/20261029-head-3eb0f05
for attempt in $(seq 1 180); do
  if test -f "$release/tests.log" && grep -q '^TESTS_COMPLETE$' "$release/tests.log"; then break; fi
  if test -f "$release/tests.log" && grep -q '^TESTS_FAILED' "$release/tests.log"; then exit 1; fi
  sleep 5
done
grep -q '^TESTS_COMPLETE$' "$release/tests.log"
. "$release/env.sh"
export LIBTORCH_PREFIX=/usr/local/lib64/python3.12/site-packages/torch
export LD_LIBRARY_PATH="$LIBTORCH_PREFIX/lib:${LD_LIBRARY_PATH:-}"
export SPUTNIK_ROOT="$release/src/sputnik-lang"
cd "$release/src/torch"
exec >"$release/torch-tests.log" 2>&1
trap 'rc=$?; if test "$rc" -ne 0; then printf "TORCH_TESTS_FAILED exit=%s line=%s\n" "$rc" "$LINENO"; fi' EXIT
./tools/test-rocm --torch-prefix "$LIBTORCH_PREFIX" --sputnik-root "$SPUTNIK_ROOT" --devices '0 1 2'
HIP_VISIBLE_DEVICES=0 ./tools/package --backend rocm --native prebuilt --modules source --bundle none --torch-prefix "$LIBTORCH_PREFIX" --sputnik-root "$SPUTNIK_ROOT" --version 0.1.3-rocm-local --out-dir "$release/torch-package"
printf 'TORCH_TESTS_COMPLETE\n'
