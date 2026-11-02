# Notebook core on 22176 with NVIDIA GPUs

The published `docker.orlando-labs.com/sputnik-remote-core:20261101-1.0.0` image
was transferred from the existing builder copy on 22136 to 22176 using
`docker save`, gzip, SSH and `docker load`. No source rebuild or credential
transfer was needed. The loaded image ID matches the published manifest's
configuration digest:

- Image: `sha256:40591db1f39677f5fce9260534e2deed7b89c88d597c36a72772a9fbe01482f4`.
- Manifest: `sha256:b0a49b4a342113107adae5be91dd5a909fdcd815f8264efde4778cac5eef556c`.
- Build/publication evidence: [../core-deploy/](../core-deploy/).

The NVIDIA runtime exposes the same two UUIDs as the previous core: RTX 3090
and RTX 4090. Both were checked with `nvidia-smi` inside the temporary candidate
and the production container. The host's GTX 1080 Ti is outside the declared
targets of the existing CUDA 13 Torch artifact, so the existing two-GPU
selection was preserved.

Both containers executed a real notebook using `import torch` and short
submodule imports. The probe attached the verified shared `slowpilot/torch`
0.1.4 CUDA runtime build, checked its archive identity and symlink reference,
then verified forward values and gradients on each GPU. The probe's grants
were explicit and scoped to its temporary notebook, which was retired afterward.
Python was neither installed nor required. See `candidate.log` and `deploy.log`.

Before replacement, HTTP admission was frozen and all books were checked for
active runs, dependency/environment work and automatic services. Idle workers
were retired. The complete stopped 4.7 GiB state was backed up on the SSD,
including the token. The old container was initially kept stopped with restart disabled.
The original absolute state path, package/cache mounts and pool limits were
preserved. Before/after snapshots of project heads, historical run states,
main-sheet grants and environment settings compare byte for byte. The token
hash also matched. Existing ncae dependencies and grants remain empty.

The production container is healthy with zero restarts and uses the immutable
loaded image ID. Registry credentials are not configured
on 22176; a future fresh registry pull needs a separate `docker login`, while
normal starts and restarts use the already loaded image.

The shell launch ran in a clean noninteractive Bash environment to avoid the
host's RVM `cd` hook under `set -u`; user dotfiles and RVM were not modified.
Final identifiers, GPU requests, mounts and API health are in `final-verify.log`;
machine-readable results are in `validation.json`.

At the user's subsequent request, server cleanup completed on 2026-11-02:
deployment backups, the stopped predecessor containers, host recovery launchers,
old images and build/transfer artifacts were removed. The working container,
state, token and mounted package/cache data were preserved. Docker's
`unless-stopped` restart policy remains enabled. Both selected NVIDIA GPUs passed
forward/backward checks after cleanup; see
[../core-server-cleanup/](../core-server-cleanup/).
