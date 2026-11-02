# Core image release — 2 November 2026

Source commits:

- VM: `ccb0d744bf4fbe77cc0e78fe3fedaa190f8220fb`.
- Notebook/Core: `bc5413054349265719149e92d99755ffd4f26b64`.

These commits include the existing VM, Notebook and extracted Core changes,
including all five remote-action fixes and their regression coverage. Later
concurrent web deployment edits are outside this image's source snapshot.
The two repositories were archived from these commits; the other sibling SDK
packages were copied by `tools/container-context`. `source-manifest.json`
identifies every source file used by the build.

## Rollout status

| Host SSH port | New image | State preservation | Production GPU check | Current status |
|---|---|---|---|---|
| 22176 | Exact published image ID | Passed, including token | Passed on RTX 3090 + RTX 4090 | Healthy, restart count 0, original GPU UUIDs |
| 22015 | Exact published image ID | Passed, including token | Candidate passed on 3 × MI50; production repeat blocked in AMD kernel driver | Authorized host reboot requested; awaiting SSH return |

At 19:44 UTC (22:44 Moscow) the 22015 SSH endpoint still timed out during
banner exchange. Its availability and post-reboot GPU operation are not yet
verified. The user was asked to inspect a console/BMC while SSH retries continue.

## Published image

- Tag: `docker.orlando-labs.com/sputnik-remote-core:20261102-1.0.0`.
- Registry manifest: `sha256:8dbdbe80240a57ac71a2db46a8b36d308dad8b499b92df190f8a096f8392030e`.
- Image ID on builder and targets: `sha256:e21143e3e635f26ce166dcacc2b1ce1f6ebd923f6f40774c82037841f00b2c1f`.
- Uncompressed image size: 524,527,045 bytes.
- Source archive SHA-256: `ba6a93fe5140d9c58b9f3221b281ddbcb251f00093991dd059e2248b86147d9f`.
- Source manifest SHA-256: `28e7528aa6e56c9c0ea84e399851052c7abdf116a2304910ebb7297b13d9aa20`.

`build-image` ran on builder 22136. `build.log` records a full-native Core
(1,441/1,441 code bodies), VM/native command-launcher tests, all 11 remote API
groups (including targeted restart and shared desktop history) and service
lifecycle tests. `push.log`, `published-manifest.json`, `image-identity.txt` and
`image-PORT.log` record publication and target identities. The image was streamed
from the builder with `docker image save | gzip` into `docker image load` on
each target; registry credentials were not copied to the GPU hosts.

## Deployment procedure

`deploy-container` reuses the running container's numeric user/group, state root,
package store, cache, thread-pool limits and GPU selection. `run-container` is
the launcher from the committed source. `container-check.s` uses native Sputnik
and authenticated Core HTTP/Unix-socket APIs; no Python is required.

Before touching production, a candidate uses separate state/cache and loopback
port 18766. It verifies the new `targeted_restart` and `desktop_history`
capabilities, the existing verified Torch 0.1.4 variant through the shared package
store, short imports and forward/backward on every selected GPU. Each device
computes `sum([1,2,3]^2) = 14` and gradients `[2,4,6]`. Candidate containers are
removed after testing.

For production, the script freezes gateway admission, rejects active runs,
dependency/environment operations and enabled schedules, then explicitly retires
idle workers without replay. It stops the old container, copies the complete
state directory, retains the stopped old container/image, and starts the new
image at the original absolute root. Startup failures restore the prior image
and state. After the public gateway becomes healthy, later verification failures
retain live data so that newly accepted work cannot be discarded by rollback.

Before/after snapshots compare every project's head and state, the complete
paginated run history (including metadata), and per-sheet grants/environment
settings/version. The token hash must also match. Full private state backups and
container configuration remain on each host; bearer tokens are not stored here.
Production then repeats the native Torch check and verifies Python is absent.

The `preflight-PORT.log`, `candidate-PORT.log`, `deploy-PORT.log` and
`verify-PORT.log` files provide the corresponding execution evidence.

The first 22176 deployment passed GPU and preservation checks, but its final
configuration showed a trailing empty Docker GPU device ID from the template's
extra newline. The helper now filters blank lines before joining UUIDs. The same
image was deployed again with the exact two UUIDs and the complete checks were
repeated. The `*-22176-first.log` files retain the initial result; the unsuffixed
files describe the final container.

## ROCm recovery

The isolated ROCm candidate passed on all three MI50 devices. The first
production repeat then timed out: its worker remained inside the kernel
`amdgpu_amdkfd_gpuvm_alloc_memory_of_gpu` allocation path, with a pending SIGKILL.
Core remained healthy and the before/after data comparison passed. Kernel stack
and device diagnostics are retained in `rocm-*.log`.

The GPU recovery attempt was initially blocked by automatic approval review,
then explicitly authorized by the user. `recover-rocm` freezes admission and
uses `rocm-recovery-guard.s` to reject user work, enabled schedules or dependency
operations. A host-wide file-descriptor scan also rejects any GPU opener other
than the known cancelled probe PID. Only that probe owned the devices.
The script uses the kernel's documented
[`amdgpu_gpu_recover`](https://docs.kernel.org/gpu/amdgpu/debugfs.html#amdgpu-gpu-recover)
interface; reading it resets a GPU and discards its running work. Recovery
succeeded for `0000:04:00.0`, but `0000:83:00.0` failed with an ATOM BIOS timeout
and return code `-22`. The blocked probe remained in the kernel. Gateway
admission was resumed automatically after the recovery attempt.

The user then explicitly authorized a normal host reboot. `reboot-rocm` verified
the new image, `unless-stopped` policy, full backup, unchanged token and
before/after project/history/settings snapshots, froze admission and rechecked
that no user work was active before requesting `systemctl reboot`.

Rollback artifacts remain at:

- 22176: `/ssd1Tb/sputnik-remote-core-releases/20261102-remote-actions/backups/before-core-20261102T191001Z`
  (old image) and `before-core-20261102T191505Z` (exact UUID correction).
- 22015: `/home/slowpilot/sputnik-core-deployments/20261102-remote-actions/backups/before-core-20261102T191325Z`.

The corresponding `sputnik-core-before-TIMESTAMP` containers are retained.
This release does not remove the current rollback artifacts.

## Relationship to earlier checks

The [remote action verification](../remote-action-fixes/) covers native macOS
model/UI behavior, the six new desktop regression groups, existing remote
UI/work/history regressions and the signed development app build. Those earlier
logs retain their original source hashes. This release adds committed source
identity, Linux image tests and actual CUDA/ROCm deployment evidence.
