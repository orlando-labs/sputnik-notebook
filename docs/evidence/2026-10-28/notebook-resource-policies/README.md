# Resource-policy verification — 2026-10-28

Scope: the current dirty workspace, including the earlier Core extraction and five
tech-preview fixes. No production service was contacted or deployed. Platform:
macOS arm64; Linux was not executed. `manifest.json` records source/output hashes.

Passed:

- 48 existing real-worker remote integrations.
- 10 policy integrations: policy-file startup/inheritance; aggregate user quota;
  SQLite read-only binding under a writer lock; 100-run retention and bounded
  registry; history cursors across GC; age/revision retention; input/output caps;
  durable deletion recovery; receipts that cannot replay after expiry/restart;
  parallel sum budgets; fail-closed accounting; lease/restart cleanup; user budgets
  across new sessions; blocked dependency installation and worker grants.
- Direct Core VM/full-native: budget/lease enforcement without a gateway or
  adapter scheduler, plus worker-host/readiness and cwd launcher coverage.
- Swift model and remote UI/work integration, rebuilt app and packaged smoke.
- Web preview adapter in VM/full-native: real catalog ACL, isolated editable
  copies, preserved template, clean reopen, visitor billing and owner binding.
- Web entry/models, frontend typecheck/production build.
- 20 browser scenarios: 18 passed in `browser-scenarios-initial.log`; two assertions
  still expected historical entries in registry and were corrected to use the
  separate history endpoint. Both reruns pass in `browser-history-corrected.log`.
  There are no outstanding failures among those scenarios.

Representative reproduction commands from the repository root:

```sh
make -j4 test-notebook-core test-notebook-remote test-notebook-policy notebook-macos
make -j4 test-notebook-remote-ui test-notebook-remote-work
make build/notebook_macos_model_tests
build/notebook_macos_model_tests
node apps/notebook-web/tools/preview_test.mjs
node apps/notebook-web/tools/preview_test.mjs --native
node apps/notebook-web/tools/main_test.mjs
node apps/notebook-web/tools/models_test.mjs
npm --prefix apps/notebook-web/frontend run build
python3 tests/notebook_macos_ui_smoke.py 'build/Sputnik Notebook.app/Contents/MacOS/SputnikNotebook'
```

Browser tests, from `apps/notebook-web/frontend`:

```sh
PLAYWRIGHT_BROWSERS_PATH=/tmp/notebook-policy-browsers npx playwright install chromium --only-shell
PLAYWRIGHT_BROWSERS_PATH=/tmp/notebook-policy-browsers npm run test:browser -- test/execution.spec.ts test/board-actions.spec.ts test/boards.spec.ts
```

The headless browser was downloaded only into `/tmp`. The CLI/native compiler
warnings about this checkout's macOS deployment target are the pre-existing
packaging constraint from the audit. The packaged app correctly advertises 26.0.

Behavior, configuration and material limits are documented in
[notebook-resource-policies.md](../../../engineering/notebook-resource-policies.md).
