# Notebook core update, 2026-11-01

The canonical Dockerfile built the current sibling working sources on 22015.
The approved archive SHA-256 and resulting image ID are in `validation.json`.
The build includes full-native compilation, the remote API integration suite
and service lifecycle tests; see `build.log`. Expected failure-path exceptions
in that log are followed by passing lifecycle checks.

`candidate-22015` checked a separate container before production replacement.
Its temporary notebook installed `torch` using a shared-store reference and
executed both `import torch` and short submodule imports. Forward values and
gradients were checked on all three MI50 GPUs. No Python was installed or used.

`deploy-22015` froze HTTP admission, checked every project's runs, dependency
jobs, environments and automatic work, then retired idle workers. The complete
stopped state was backed up, including the persisted token, and the previous
container was retained with automatic restart disabled. The new container uses
the original state path, package/cache mounts, GPU devices and pool limits.
Before/after project and run snapshots matched and the token hash was unchanged.
The existing ncae Torch installation was reattached to the verified shared cache
at the same version, variant and archive digest, creating the short import
binding. Its document revision and worker grants were unchanged. Production
passed the same real notebook GPU check. See `candidate.log` and `deploy.log`.

The production container is healthy with zero restarts. Native execution in
the user's ncae sheet still requires the user's explicit worker grants; its
existing empty grants were preserved. The maintenance GPU notebook had its own
explicit grants and was retired after the check.

The user explicitly approved transfer of the tested image to the documented
internal Docker builder 22136. The loaded image ID matched the tested build,
and publication completed using the builder's existing registry login:

- Tag: `docker.orlando-labs.com/sputnik-remote-core:20261101-1.0.0`.
- Manifest: `sha256:b0a49b4a342113107adae5be91dd5a909fdcd815f8264efde4778cac5eef556c`.
- Image: `sha256:40591db1f39677f5fce9260534e2deed7b89c88d597c36a72772a9fbe01482f4`.

An authenticated pull by manifest digest on the builder passed. The published
manifest's config digest matches the production image ID. See `push.log`,
`published-manifest.json`, `published-image.txt` and `registry-verify-builder.log`.
The launcher default now uses the new published tag.

Registry reads also require authentication. The attempted pull on 22015 was
rejected because no registry login is configured there; no credentials were
read or copied between hosts. The deployed image is already present on 22015,
and the deployed container uses the verified immutable image ID.
Normal container starts/restarts need no registry request. A future fresh pull
on that host will require its own registry login. The original failed push
is retained in `push-22015-no-auth.log` and the failed pull in
`registry-verify-22015-no-auth.log`.

At the user's subsequent request, server cleanup completed on 2026-11-02:
deployment backups, the stopped predecessor containers, host recovery launchers,
old images and build/transfer artifacts were removed. The working container,
state, token and mounted package/cache/ROCm data were preserved. Docker's
`unless-stopped` restart policy remains enabled. GPU checks passed after cleanup;
see [../core-server-cleanup/](../core-server-cleanup/).
