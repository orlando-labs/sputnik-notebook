# Demand-created pools, package reissue and GPU Docker deployment

The core image was subsequently replaced with the Python-free build documented
in [the correction report](../no-python/README.md). Its current digest and fresh
GPU/deployment checks supersede the original core-image reference below.

Completed on 2026-10-31. Both remote cores use Sputnik 1.0.0 from language commit
`c17d12b2e25c2dd2cb0b9e41835b0a8e33925573`. Host CLI and interactive binaries
were updated as well as the compiler/VM inside the image.

## Runtime and deployment

The task and FFI pools create threads on demand within their configured maximum.
`SPUTNIK_TASK_MAX_THREADS` controls task workers; `SPUTNIK_FFI_MAX_THREADS`
controls blocking FFI workers. A full FFI pool raises `ResourceBusyError`, and
idle FFI workers retire after 30 seconds. Both deployments currently use limits
56 and 32 respectively.

`--mode serve` supervises the execution agent and HTTP gateway. `--host` selects
the HTTP listen address. The [container guide](../../../engineering/remote-core-container.md)
contains a one-command launcher, GPU selection and persistent volume setup.

Both `lab.orlando-labs.com:22015` (ROCm, three gfx906 GPUs) and `:22176` (CUDA,
RTX 3090 and RTX 4090) now run `sputnik-remote-core` in Docker. The HTTP gateway
remains on host `127.0.0.1:18765`. Original absolute state paths, authentication
tokens, project heads and run history were preserved. State backups and the
previous launcher were saved before stopping the bare processes. Staging used
copies of the original state before either working service was changed.

The image and registry image are published internally; immutable digests appear
in [published-images.json](published-images.json). The runtime includes
`libdrm-amdgpu1`; ROCm mounts the host userspace and sets its library search path.
CUDA exposes only the two supported RTX devices.

## Checks

- Language VM, tasks, FFI, native extension and full-native blocking suites passed.
- Four `serve` lifecycle tests and all 50 remote API integration tests passed in
  the Docker build. The final runtime dependency layer preserves those binaries.
- ROCm and CUDA containers passed public package installation, real GPU
  forward/backward checks, HTTP execution and restart/token/history checks.
- Working notebook Run requests subsequently verified forward and gradients on
  all three AMD GPUs and both RTX GPUs. Test projects were deleted and workers
  exited; results are in the two `*-api-gpu.json` files.
- Mac CPU/MPS checks ran with automatic MPS fallback disabled, including a fresh
  public registry installation. See [macos-public-mps.log](macos-public-mps.log).

Generic package conformance used isolated stores, VM and supported full-native
fixtures, bytecode/mixed delivery and exact lock hashes. Python/Ruby bridge
callbacks were updated to explicit function references for Sputnik 1.0.0; all
four variants of each bridge passed on Mac and Linux. Local provider descriptors
declare language compatibility and remain outside the published archives.

## Registry

All 52 previous platform/delivery combinations were reissued: generic packages
are 0.1.1, Orbit and Orbit ORM are 1.0.0-rc.2, and Torch is 0.1.4. Torch includes
Mac MPS runtime, Mac thin source, Linux ROCm 6.4.3 and Linux CUDA 13 runtime
variants. Exact public hashes are in [public-verified-52.json](public-verified-52.json).

After replacement verification, 13 old releases / 55 artifacts were removed,
including 4,336,003,456 bytes of unreferenced blobs. Accounts, aliases, owners and
audit history were retained. The native backup of all old artifacts and a
pre-retirement SQLite snapshot remain available. The catalog now exposes 12
releases with 52 artifacts; all 13 retired version URLs return 404. See
[retirement-result.json](retirement-result.json) and
[public-after-retirement.json](public-after-retirement.json).

## Idle measurements

The final measurements follow real notebook GPU execution and worker cleanup.
PSS accounts for shared resident pages; virtual address space includes reserved
stacks and is not equivalent to physical memory.

| 22015 | Previous agent + gateway | Docker service, including supervisor and init |
| --- | ---: | ---: |
| OS threads | 97 | 11 |
| PSS | 45.4 MiB | 35.8 MiB |
| Virtual address space | 7.02 GiB | 0.50 GiB |

22176 is also healthy with 11 idle threads and 34.2 MiB PSS. Raw process values,
pool limits and image IDs appear in the two `*-container-resources.json` files.
