#!/bin/bash
set -euo pipefail
r=/ssd1Tb/sputnik-remote-core-releases/20261031-packages-1.0.0
exec >"$r/build.log" 2>&1
trap 'rc=$?; if test "$rc" -ne 0; then echo "CUDA_BUILD_FAILED exit=$rc line=$LINENO"; fi' EXIT
cd "$r"
tar -xf inputs.tar
mkdir -p src/sputnik-lang src/torch
tar --warning=no-unknown-keyword -xzf sputnik-language-current-20261031.tar.gz -C src/sputnik-lang
tar --warning=no-unknown-keyword -xzf sputnik-torch-current-20261031.tar.gz -C src/torch
mkdir -p src/torch/build/deps
tar --warning=no-unknown-keyword -xzf sputnik-gloo-74cc005.tar.gz -C src/torch/build/deps
previous=/home/slowpilot/sputnik-remote-core/current
cp "$previous/cxx" cxx
sed "s|$(readlink -f "$previous")|$r|g" "$previous/env.sh" > env.sh
source env.sh
export CXX="$r/cxx"
export SPUTNIK_PKG_HOME="$r/packages"
mkdir -p "$SPUTNIK_PKG_HOME"
make -j6 -C src/sputnik-lang build/sputnik
cd src/torch
exec tools/package --backend cuda --native prebuilt --modules source --bundle runtime --package-ref slowpilot/torch --version 0.1.4 --cuda-devices '1;2' --torch-prefix /ssd1Tb/slowpilot-sputnik-cuda-20261022/deps/cu130/libtorch --sputnik-root "$r/src/sputnik-lang" --out-dir "$r/registry-cuda-014"
