# Notebook web on current SDK b3ed894

30 October 2026. Follow-up to the SDK qualification in Stages 4g.2.4, 4h.1 and
4h.2. This report uses the default workspace SDK, without the old SPUTNIK override.

## Integration change

SDK b3ed894 fixes callable export references and native UUID dispatch. The web
application still exposed one missing migration in ORM: ModelType.set_record_factory!
assigned a bare factory identifier, invoking the one-argument callback immediately.
It now retains &factory. Two ORM self-test checks verify that registration is
inert and that creating a record invokes the factory once with the supplied values.
The full self-test returns 32; the pool self-test returns 17.

An isolated database probe reproduced the failure after successful migrations
and located it at orm.s:378, rather than the misleading database cleanup frame.
After the fix, pool creation, migrations, binding all notebook models and closing
the database pass. See [before](database-probe.log), [after](database-probe-fixed.log)
and the [ORM patch](orm-factory.patch).

SDK sources were not modified. Existing unrelated workspace edits were preserved.
Builds use independent VM caches for fixture/main; smoke caches already include
the compiler binary hash. The old shared application build cache was preserved
under a backup name after an initial bytecode-cache read failure. No cache or
compiler override is required in the normal web runner.

## Verification

| Backend | Assets | Result | Log |
| --- | --- | --- | --- |
| VM | Production | 40 passed | [log](browser-vm-production.log) |
| VM | Vite development | 40 passed | [log](browser-vm-development.log) |
| Full native | Production | 40 passed | [log](browser-native-production.log) |
| Full native | Vite development | 40 passed | [log](browser-native-development.log) |

All **160 browser checks passed**. Each configuration runs the same 40 real browser scenarios: account/session/ACL,
library/desktop/phone themes, exact run snapshots/comparison/restore/retention,
Python environments and worker settings, media selection/date/preset controls,
storage admission, cumulative computation and the public 60-second ceiling.
Environment preparation is explicitly enabled only in the local test operator
policy. Tests use the existing local GitHub provider fixture and real Core/worker.

- [Native summary](native-summary.json) records Core 1365/1365 and both web entries 3219/3219,
  with full native coverage and zero VM fallback for Core, the web fixture and the actual backend/main entry.
- [Actual native backend/main startup](real-main.json) passed production SSR/bootstrap,
  anonymous session (200), private API rejection (401) and CSP, using the original
  Host and trusted one-hop HTTPS proxy headers. This was local transport with no
  external OAuth request and no Core connection; it is not a deployment test.
- [Core tests](core-tests.log) passed worker-host and exact shared-selection
  acceptance, including forged source/key/row rejection.
- [ORM self-test](orm-selftest.log) returns 32; [pool self-test](orm-pool.log) returns 17.
- The [unchanged atomicity recheck](orm-atomic-final.log) passes. Two preliminary
  attempts ([first](orm-atomic.log), [second](orm-atomic-recheck.log)) failed the
  cancellation rollback/lease assertion during concurrent native builds. A
  [diagnostic run](orm-atomic-probe.log) reported caught=true, rows=0, leased=0 and
  passed; the [old SDK baseline](orm-atomic-baseline.log) also passed. The cause of
  that intermittent assertion was not established. No delay, retry loop or weakened
  assertion was added to the test; the temporary diagnostic source was removed.
- git diff --check, relative links and source/binary hashes were checked.

The earlier reports remain historical records of verification on SDK 3eb0f05.
This follow-up supersedes their web startup qualification for the recorded current
SDK plus the ORM factory-reference fix. It does not establish production deployment
or whole-SDK conformance. Real GitHub consent, Safari/mobile operating systems and
the cross-platform parity/deployment audit remain separate work.

## Reproduce

Build the current SDK with make build/sputnik from sputnik-lang, then make
remote-core from sputnik-notebook. Build the two web entries with the normal
--target native --require-full-native grants from the app README; set a distinct
SPUTNIK_VM_CACHE per concurrent build. For example use build/current-sdk-fixture-cache
and build/current-sdk-main-cache under apps/notebook-web. Frontend sources/assets
are unchanged by this follow-up.

From apps/notebook-web/frontend run npm run test:browser -- test/workspace.spec.ts
test/run-history.spec.ts test/environments.spec.ts test/selection-controls.spec.ts
test/resources.spec.ts. Leave SPUTNIK unset. Set NOTEBOOK_WEB_TEST_ENVIRONMENTS=1
and PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH to installed Chromium. Repeat with
ORBIT_E2E_NATIVE=1 and/or ORBIT_E2E_MODE=development. Verification used Chromium
152.0.7977.82.

ORM checks run from the sibling orm checkout with the current compiler:
test/selftest.build.yaml, test/pool_selftest.build.yaml and
test/atomicity_selftest.build.yaml, using ordinary local SQLite/FFI/file grants.

[Compiler/dependency identities](identities.json) ·
[Source and binary hashes](source-sha256.json) ·
[Implementation plan](../../../engineering/notebook-web-implementation.md)
