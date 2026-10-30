# Bare function values and registry Torch 0.1.3

Verification and deployment ran on 29–30 October 2026. Machine-readable final
publication and installation state is recorded in `status.json`.

## Language

Sputnik HEAD `5d291d72f95eb30846e05f3b50d5d2c77000b384` invokes function-valued
identifiers as bare nullary calls. `&f` retains a reference, including locals,
parameters, captures and imports. Explicit calls do not perform a second call.
Classes and ordinary non-function values remain values. Captured cells that
change from integers to functions invalidate the integer fast path correctly.
Namespace class chains and parameter shadowing retain their lexical meaning.
The language specification and cheat sheets accompany the implementation.

Local corpus: 234/234. Bare-call VM and full-native conformance passed. Notebook
core VM/native checks and all 50 local remote API tests passed with absolute
worker paths. Both Linux deployments passed 48/48 remote API tests and the
production bare-call/receipt-replay smoke check. Existing metadata rows and
credentials were preserved; SQLite quick checks and executable hashes passed.

## Torch builds

Torch payload commit `f78a02837abcbf8dd9e56b6406b05148caa0c95f` adds a scoped registry
ROCm package and explicit callback references. The package set retains all three
variants in 0.1.2 and adds the ROCm variant:

| Variant | Verification |
| --- | --- |
| `macos-aarch64-prebuilt-source-runtime` | CPU/MPS VM and full-native; CPU fallback disabled |
| `macos-aarch64-source-source-none` | Clean source build with exact C++ providers; CPU/MPS VM and full-native |
| `linux-x86_64-gnu-cu130-prebuilt-source-runtime` | RTX 3090 and RTX 4090 VM/full-native and checkpoints; LibTorch 2.14.0+cu130 |
| `linux-x86_64-gnu-rocm643-prebuilt-source-runtime` | Three gfx906 GPUs, VM/full-native; LibTorch 2.14.0, ROCm 6.4.3, matching RCCL |

The ROCm archive bundles LibTorch and matching RCCL, uses relative library
resolution, and requires the host ROCm driver/runtime and gfx906 Tensile data.
All native/source/runtime payload members in the publisher-host repack match
the GPU-tested archive; only generated build provenance/checksum members differ.
See `22015/registry-payload-equivalence.json`.

The Sputnik package resolver recognizes ROCm targets and probes HIP without
Python, headers or a compiler. A hidden-device check rejects a ROCm-only variant
when no usable GPU is visible. Registry clean-install checks deliberately disable
the compiler while installing prebuilt packages and execute native consumers
without `LD_LIBRARY_PATH` and with `PATH=/nonexistent`. Registry installation and imports use automatic host selection; remote ROCm
verification uploads no lock and sets no backend/bundle/variant installation
overrides. Optional locks retain exact version/variant/hash/origin pins.

## Registry

The updated validator uses the exact language HEAD and full-native registry
commit `23b9a778b45802eb5986237bd363a9ed155b2d88`. All 772 integration checks
passed, along with VM/native storage checks and package CLI/native-parallel
checks. The executable has 1,985 native code bodies and zero VM fallback bodies.
The deployment image is pinned by immutable Docker image ID; package publication
uses the public Sputnik registry.

Anonymous package reads are enabled. No publisher credential was sent to the
ROCm server. The unused temporary read token was revoked before deployment.
Registry deployment takes a verified native SQLite/CAS backup and preserves
account, namespace, package, release, artifact and token counts.

## Independent existing failures

The NVIDIA host corpus has one previously reproduced glibc limitation in the
`system_control` spawn-working-directory fixture (233/234 there; AMD 234/234).
The unrelated Torch DataLoader cancellation/join failure was reproduced with
previous VM/package versions. Neither is counted as a passing suite here.

## Automatic host selection

Commit `5d291d7` makes install and import backend/bundle policies automatic.
Host-compatible GPU variants are preferred, CPU remains an explicit override,
and optional exact locks remain authoritative. Unit, package store, HTTP/native
registry CLI and real unlocked macOS CPU/MPS checks passed. The store regression
covers imports and declared dependencies, including the remote notebook overlay,
without an installed shared fallback or lock. Torch test commit `13a6b94` checks
automatic registry installation into a fresh remote AMD project without any
backend/bundle/variant install override and without uploading a lock.

## NVIDIA state reset

The user deleted the remote core working directory on SSH 22176 and explicitly
authorized starting with empty state; old projects need not be restored. The
service binaries and global registry-installed CUDA package survived on SSD.
The state is reinitialized with a new private token at
`/home/slowpilot/sputnik-remote-core/state/token` (0600), retaining gateway port
18765. The global registry package home lives on the SSD, with the normal
`~/.sputnik/packages` path retained as a symlink. Runtime dependencies removed
with the directory are rebuilt before restarting the service.

Final state: both servers run SDK `5d291d7`. Fresh AMD and NVIDIA remote
projects installed Torch 0.1.3 from the registry automatically, without uploading
a lock or supplying backend/bundle/variant installation selectors. GPU
forward/backward checks and receipt replay passed; both projects were deleted.
The restored NVIDIA core has a new token and no restored historical projects.
Final process hashes, PCRE library paths, SQLite health and idle state passed.
