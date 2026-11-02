# Sputnik HEAD and ROCm dependent rebuild — 2026-10-29

Language HEAD `3eb0f05da50ba307d5f719e0b194de6317304b29` and the final
Torch commit in `status.json` are installed. Language and Torch working trees
are clean. Push of these new commits is pending separate authorization after
an automatic approval-review rejection; deployment/source transfer was
explicitly authorized and completed.

Both servers run `20261029-head-3eb0f05` with the existing deployed notebook
source baseline `a877de6`, rebuilt against the new language. Package fixtures
were migrated to shared YAML manifests for verification. All 47 API tests
passed on each Linux host. Local extracted notebook-core/worker checks and
all 49 local remote API tests passed too; existing notebook extraction work
was left in its working tree.

Port 22176 was switched with a SQLite writer-lock idle check, retained state,
token and launch script in the reported backup, and preserved all existing
project/revision/run/receipt/runtime rows. No active work was interrupted.
Its production membership cell returned 42; receipt replay and deletion passed.

Port 22015 now has Sputnik/isputnik/remote CLI wrappers in ~/.local/bin and
running agent/gateway processes. Its first-start launcher waits for the agent
token before starting the gateway. RPATH puts private PCRE2 10.47 before the
system library; final maps and a targeted Unicode/regexp worker test passed.

The AMD host has ROCm 6.4.3, LibTorch 2.14.0 and three gfx906 devices. C++
provider probes and actual Sputnik VM/full-native checks passed on every GPU.
The native graphs have full coverage, zero VM fallback and are VM independent;
interpreter-free execution did not load libpython or libtorch_python.

Official signed AMD ROCm 6.3.4 rocBLAS kernel data supplies gfx906 Tensile
files absent from the system 6.4.3 package. It lives in a separate user prefix
and ROCBLAS_TENSILE_LIBPATH is in the release/worker profile. The system ROCm
libraries remain installed; provenance and hashes are in 22015/verification.log,
origin.txt and gfx906-sha256.txt.

The local Torch package passed compiler-disabled installation/VM execution and
a full-native installed consumer. A production remote worker installed it via
the API, ran GPU matrices/gradients and SGD, preserved receipt RunId on replay,
and deleted the smoke project. It was also installed in the user's normal
package home. A runnable example is recorded in status.json.

Each server directory contains its release manifest, tests, deploy result,
production smoke and independent final health. No token or state backup was
copied into this evidence directory.
