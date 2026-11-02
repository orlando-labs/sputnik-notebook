# Notebook server cleanup

Cleanup started on 2026-11-01 and completed on 2026-11-02 at the user's request.
Scope: Notebook artifacts on GPU servers 22015 and 22176, plus the Notebook
build/publication artifacts on builder 22136. Unrelated services and registry
package builds were preserved.

All observed Notebook processes belong to the working Docker containers,
verified using `/proc/<pid>/cgroup`. There were no bare-host Notebook processes
on any of the three servers. The final read-only audits report no remaining
removable Notebook paths, containers or images. The audit protects the literal
and resolved source paths of every running container's mounts before deleting
files, and checks the core's ID, PID, mounts, token hash and health afterward.

Removed artifacts include old host binaries, launchers and wrappers, source
trees, build contexts, transfer archives, temporary probes, logs, retired
releases, unmounted SDK stores, deployment backups, stopped predecessor
containers and their anonymous volumes, old core images and Notebook build
cache. Rollback backups and host recovery launchers recorded in the original
deployment reports are no longer retained. Docker's `unless-stopped` restart
policy remains in force; no running container was restarted during cleanup.

The working image remains
`sha256:40591db1f39677f5fce9260534e2deed7b89c88d597c36a72772a9fbe01482f4`
on both GPU servers and in the internal registry. The builder's local copies
were removed. `registry-manifest-after.json` confirms the published config
digest still matches this image.

Preserved host data and runtime mounts:

| Server | Paths |
|---|---|
| 22015 | `/home/slowpilot/sputnik-remote-core/state`; `/home/slowpilot/sputnik-releases/20261031-current-c17d12b/container-packages`; the same release's `container-cache` |
| 22015 ROCm | `/opt/rocm-6.4.3`; `/home/slowpilot/sputnik-remote-core/deps/rocblas-gfx906/opt/rocm-6.3.4/lib/rocblas/library` |
| 22176 | `/home/slowpilot/sputnik-remote-core/state`; `/ssd1Tb/sputnik-remote-core-releases/20261031-packages-1.0.0/container-packages`; the same release's `container-cache` |

Ancestors of these directories and the working containers' existing Docker
volumes are also preserved. The ROCm mounts are runtime dependencies.

Evidence:

- `*-cleanup.log`: successful deletion receipts and unchanged container checks.
- `*-final-audit.log`: final no-host-process checks and no cleanup candidates.
- `22015-image-cache-cleanup.log`: the remaining eight exact cache references
  shared with the runtime image were removed using `--all`; total build cache
  is now zero and the working image/container/PID remain unchanged.
- `22136-cache-after.log`: no matching Notebook build-cache records remain.
  Unrelated registry build cache was preserved; no global Docker prune was used.
- `22136-empty-parent-cleanup.log`: empty publication parent removed.
- `22015-gpu-after.log` and `22176-gpu-after.log`: native Torch forward/backward
  checks after host cleanup pass on all three MI50s and both selected NVIDIA
  devices (RTX 3090 and RTX 4090). `gpu-check.s` is the fixture. Its temporary
  container file was removed after execution.
- `validation.json`: machine-readable results and evidence hashes.

The initial final-cache cleanup attempt was blocked by an automatic approval
review usage limit. After the user's continuation, review succeeded and those
remaining actions completed. No cleanup action remains blocked.
