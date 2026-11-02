# Notebook web — resource limits and temporary previews

28 October 2026, macOS arm64, current working tree. Existing unrelated changes
were preserved. No production service was changed. Linux was not executed.

Implemented:

- Resource limits dialog for the eight native book overrides, separate inherited
  defaults and saved effective values, exact integer/byte conversions, Cancel,
  reset and ordinary draft/Save/CAS persistence. Editing/reading does not run code.
- Sanitized policy/time summaries in execution polling and an authorized,
  on-demand project storage endpoint. Private Core/user identities, global archive
  usage and disk details are omitted. Exhaustion prevents UI starts while keeping
  Stop/Pause/results available; Core remains the enforcement authority.
- Explicit disposable preview copies with saved-copy source/text editing, Run All,
  Stop/Force Stop, rich results and receipt recovery. Preview commands never replay
  automatically; tokens stay in memory, abandoned copies expire by Core lease,
  and a disconnected copy requires a fresh opening.
- Public persistence and per-run/cumulative 60-second ceilings remain enforced
  even when a profile requests durable storage or 600 seconds, and with book
  replacement enabled. User/Core aggregate budgets survive new copies.

The preview is authenticated against the template's execution ACL. Anonymous
public template/principal selection remains a separate deployment slice. The
next editor feature slice is still Stage 4f.2 in the implementation plan.

## Verification

All final runs passed:

| Backend | Assets | Browser scenarios |
| --- | --- | --- |
| VM | Production | [80/80, complete suite](browser-vm-production-full.log) |
| VM | Vite development | [5/5 resource/preview scenarios](browser-vm-development.log) |
| Full native | Production | [5/5 resource/preview scenarios](browser-native-production.log) |
| Full native | Vite development | [5/5 resource/preview scenarios](browser-native-development.log) |

The new browser scenarios cover inert policy drafts and save/reload, inherited
defaults, exact MiB conversion, real cumulative quota termination and persisted
exhaustion, storage rejection without acceptance, copy isolation/clean reopening,
lost accepted Run response recovery with one POST, the public hard ceiling,
Stop/Force Stop, cross-account reads, viewer restrictions and CSRF.

- [12 Core policy integrations](core-policy.log), including both launch modes,
  profile replacement, retention/storage, aggregate budgets, accounting failures,
  leases and restart cleanup.
- [48 existing real-worker remote integrations](core-remote.log).
- [Direct web preview adapter in VM](preview-vm.log), including sanitized
  resource fields, native book settings, saved-copy and Run receipts.
- [Resource conversion/Int64 unit checks](resource-unit.log) and existing
  [portable text checks](rich-text-unit.log).
- [Vue/TypeScript and production build](frontend-build.log).
- Actual main-entry startup in [VM](main-vm.log) and [full native](main-native.log).
- [Native build summaries](native-summary.json): Core and main/fixture backend
  have complete native body coverage, no VM fallback and no runtime bridge.
- [Final source/output fingerprints](source-sha256.json). Whitespace checks passed.

An initial full-suite run was interrupted after rebuilding frontend assets during
the run invalidated its cached manifest. The final complete run above used an
unchanged production build and has no outstanding failures. The native/Core
builds used for the final runs include the final policy changes.

The desktop and mobile screenshots were visually inspected in both themes;
browser checks also assert no horizontal dialog overflow at 375 px. The dialogs
scroll vertically when their content exceeds the viewport.

| View | Light | Dark / mobile |
| --- | --- | --- |
| Resource settings | [Desktop](resources-light.png) | [Dark](resources-dark.png), [375 px](resources-mobile.png) |
| Temporary preview | [Desktop](preview-light.png) | [Dark](preview-dark.png), [375 px](preview-mobile.png) |

Reproduce from the repository root:

```sh
make -j4 remote-core
node apps/notebook-web/tools/resource_policy_test.mjs
node apps/notebook-web/tools/preview_test.mjs
python3 tests/notebook_policy_tests.py --worker "$PWD/build/sputnik-notebook-worker" --core "$PWD/build/sputnik-notebook-remote"
python3 tests/notebook_remote_tests.py --worker "$PWD/build/sputnik-notebook-worker" --core "$PWD/build/sputnik-notebook-remote"
npm --prefix apps/notebook-web/frontend run build
```

From `apps/notebook-web/frontend`, use the existing Playwright configuration and
installed Chromium. `ORBIT_E2E_MODE=development` selects Vite;
`ORBIT_E2E_NATIVE=1` selects the fixture native backend. Build main/fixture with
the commands in the app README before native tests. Run the full suite with
`npm run test:browser` or only the new scenarios with
`npm run test:browser -- test/resources.spec.ts`. Keep production assets unchanged
for the lifetime of each test server.
