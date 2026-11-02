# Removal of the new Python tooling dependency

`tests/notebook_package_catalog_test.py` was removed. Its real HTTP package
catalog fixture and package archives are now implemented by
`tests/notebook_package_catalog_test.s`, using the same Sputnik SDK as the
consumer. The Swift dependency editor uses this fixture too.

Remote integration, command launcher and `--mode serve` lifecycle checks now
run in Sputnik. The native test executable is built with `--require-full-native`.
Coverage includes catalog authentication/compatibility, package installation,
snapshots, execution, cancellation, grants, input/watch batches, board actions,
periodic work, durable restart failures and agent interruption. Lifecycle checks
cover cleanup, persistent token/history, duplicate ownership and child failures.
Child cores explicitly receive an unavailable Python executable in these tests.

`tools/container-context`, `tools/notebook-remote/run-container` and macOS SDK
assembly in `tools/notebook-macos/package-app.sh` use shell. The SDK and runtime
Docker stages do not install Python or Ruby. Foreign notebook interpreters remain
optional features, separate from the base image. Existing unrelated legacy tests
remain in the repository; the required core build/test/container path does not
invoke them.

Verified locally:

- Sputnik VM and full-native remote integration and command launcher checks.
- Sputnik VM and full-native service lifecycle checks.
- Real Swift dependency editor against the Sputnik catalog fixture.
- macOS application assembly and `codesign --verify --deep --strict`.
- Shell syntax and patch whitespace checks.

Logs in this directory record the checks. Deliberate child termination and bind
failure tests print expected exceptions before their PASS result.

## Published and deployed

The corrected image is published at both
`docker.orlando-labs.com/sputnik-remote-core:20261031-1.0.0-no-python` and
`docker.orlando-labs.com/sputnik-remote-core:20261031-1.0.0`:

- Manifest: `sha256:db154a325179e6e231578dbba20d2fe40bd43746236f095e726fc9569cd30535`.
- Image: `sha256:98f862174b559490b410294835c3566ff40a40460c4c6bb743b71b7e6ccc042d`.

Linux command, remote integration and service lifecycle tests all passed, with
zero native VM fallback. The final test layer reuses the unchanged core build
`sha256:dbce239082147533d28347c545d9162669a57891388815f34625c63ebacc8320`;
`Dockerfile.tests-from-build` and `tests.sha256` record the final test overlay.
The main Dockerfile builds the same stages directly from source.

Both `lab.orlando-labs.com:22015` and `:22176` now run this image. Replacement
required an idle-state audit, backup, health check, byte-for-byte state snapshot
comparison and unchanged token hash. Real notebook GPU execution verified
forward values and gradients on all three AMD GPUs and both RTX GPUs. Checks
confirmed no Python executable or installed Python/libpython package in either
working container. Temporary test projects were retired; the transfer server
was removed. See `deploy-22015.log`, `deploy-22176.log` and `verify-*.log`.

The first replacement attempt rolled back safely after a helper-script error;
the corrected helper then passed both deployments. Backups remain under
`/home/slowpilot/sputnik-remote-core/backups/before-no-python-*` on each host.
