# Remote core in Docker

The image includes Sputnik 1.0.0, the native worker and the remote core. `--mode
serve` supervises the execution agent and HTTP gateway, forwards termination and
stops the other child if either fails. `--host` controls the HTTP listen address;
its default is `127.0.0.1`, and the image uses `0.0.0.0` inside the container.

The build, native integration tests, launcher and base image do not require
Python. Package catalog fixtures run in Sputnik; container preparation and
launching use shell. Python and Ruby are optional notebook interpreters and are
not installed in this image. Add an interpreter only to a custom image that
needs to execute notebook cells in that language.

Start the service in one command, using persistent directories owned by your user:

```sh
tools/notebook-remote/run-container --state ./state --packages ./packages --cache ./cache
```

The default image is `docker.orlando-labs.com/sputnik-remote-core:20261101-1.0.0`.
Its published manifest digest is
`sha256:b0a49b4a342113107adae5be91dd5a909fdcd815f8264efde4778cac5eef556c`.
Authenticate with `docker login docker.orlando-labs.com` before a fresh pull.
The host port defaults to `127.0.0.1:18765`. Retrieve the bearer token from
`state/token`; it survives image replacement and restarts. Set `--bind` to change
the host interface. Use a trusted network, SSH tunnel or TLS reverse proxy for
remote access.

ROCm uses the host's installed ROCm userspace, kernel devices and numeric GPU
groups. For gfx906, supply the matching Tensile library when needed:

```sh
tools/notebook-remote/run-container --backend rocm --state ./state --packages ./packages --cache ./cache --tensile /path/to/rocblas/library
```

CUDA requires the NVIDIA container runtime on the host. GPU UUIDs keep device
selection stable; choose GPUs supported by the package's CUDA version:

```sh
tools/notebook-remote/run-container --backend cuda --gpu-devices GPU-UUID1,GPU-UUID2 --state ./state --packages ./packages --cache ./cache
```

Install the desired public Torch variant into the persistent package store:

```sh
docker exec sputnik-remote-core sputnik pkg install slowpilot/torch --version 0.1.4 --backend cuda --bundle runtime --allow-native --allow-native-large
```

Use `--backend rocm` on AMD. Native packages from releases before Sputnik 1.0.0
must be rebuilt; use a separate package directory when upgrading an old service.

`SPUTNIK_TASK_MAX_THREADS` and `SPUTNIK_FFI_MAX_THREADS` bound demand-created
runtime workers. The launcher exposes `--task-threads` and `--ffi-threads` (32 by
default for FFI). An exhausted FFI pool raises `ResourceBusyError`. Idle FFI
threads retire after 30 seconds. These limits apply to Sputnik's pools; native
libraries such as LibTorch can manage additional threads.

For migration, stop new requests, verify that runs, dependency jobs and managed
environment installations are idle, back up SQLite and preserve `state/token`.
Pass `--root /original/absolute/state/path` and bind the existing state directory
there: stored revision paths are absolute. Keep the previous launcher and image
available until authenticated execution and GPU checks pass.

Build and publish from current sibling checkouts:

```sh
tools/container-context
mkdir -p .build/docker-context
tar -xzf .build/container-context.tar.gz -C .build/docker-context
docker build -f .build/docker-context/sputnik-notebook/Dockerfile -t docker.orlando-labs.com/sputnik-remote-core:20261101-1.0.0 .build/docker-context
docker push docker.orlando-labs.com/sputnik-remote-core:20261101-1.0.0
```

The build runs service lifecycle and full remote API integration tests before
producing the runtime image. Docker's health check uses the persisted token
without putting it in process arguments. Use `docker logs`, `docker inspect`
and `docker restart sputnik-remote-core` to operate the service.

Verified deployments of the 20261101 image:

| SSH port | GPU backend | Verified devices | Evidence |
|---|---|---|---|
| 22015 | ROCm | 3 × MI50 | [Deployment](../evidence/2026-11-01/core-deploy/) |
| 22176 | CUDA | RTX 3090 and RTX 4090 | [Deployment](../evidence/2026-11-01/core-deploy-22176/) |

Both deployments preserve persistent state and tokens and pass short Torch
imports plus forward/backward on every selected GPU. The GTX 1080 Ti on 22176
is outside the declared targets of the installed CUDA 13 Torch build; the
previous two-GPU UUID selection remains in place.

At the user's request, server cleanup completed on 2026-11-02. Stopped rollback
containers, backups, old images, host launchers, build trees and transfer files
were removed from both GPU servers; Notebook build/publication artifacts were
also removed from builder 22136. Only working core images/containers and their
mounted data/runtime dependencies remain. No bare-host Notebook processes were
found. Docker's `unless-stopped` policy provides automatic restarts. See the
[cleanup evidence](../evidence/2026-11-01/core-server-cleanup/) for retained paths
and successful GPU checks after cleanup.
