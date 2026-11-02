# VM/regexp dependent rebuild — 2026-10-28

Language baseline: `77650e1e73bae5505d819e1d95f037be7592e19d`.
The local build also includes the existing workspace overlays recorded in
`local-build.json`. Existing notebook-core extraction and notebook-web work
remain in their original working tree.

Rebuilt: `isputnik`, notebook-core archive, worker, remote executable, macOS
application and bundled compiler/SDK, notebook-web native backend, and registry.
Registry's explicit runtime link now includes PCRE2. The macOS package follows
PCRE2 dynamic linkage and carries its header and notices.

Local checks: notebook-core VM/full-native API; worker/IPC/cancellation/run-tasks;
45 remote API integrations plus the added regexp test; all isputnik suites and
system CLI; syntax and isolated-worker app smoke; notebook-web VM/native entry
and native model/migration checks; 772 registry integration assertions.

The remote release uses the committed language and existing deployed notebook
revision `a877de6`. Both binaries were rebuilt with PCRE2 10.47 in a private
prefix. VM/full-native regexp and condition tests passed; all 46 Linux remote
API integration tests passed before deployment.

Production now runs `20261028-regexp-77650e1`. The switch checked for active
work under a SQLite writer lock and retained metadata, token and the previous
launch script in `backups/before-regexp-20261028T083834Z`. No active work or idle
runtime was interrupted. A production regexp/Unicode/`$_` cell returned `42`;
receipt replay returned the same run. The smoke project was deleted by API.

- `release.json`: committed source baseline, dependency and executable hashes.
- `tests.log`: Linux verification including 46 remote API tests.
- `deploy-result.json`: backup, preserved state and process identities.
- `production-smoke.json`: real API/worker regexp and receipt verification.
- `final-health.json`: independent health and actual loaded PCRE2 paths.
- `local-build.json`: local artifacts and validation.

