# Relative source imports — 2026-10-27

Implemented static string imports (`import "../backend/models" as models`,
`from "../backend/models.s" import Account`) relative to each importing file.
Canonical files share one module and initialization across paths and symlinks.
The default alias is the filename stem. Ordinary local imports in loaded source
modules retain their own directory; declaration mismatches do not shadow other
packages (such as orm/sqlite3.s versus the sqlite3 package).

Passed:

- Parser, package store, build, binder, HIR and VM suites.
- Dedicated CLI VM/full-native regression: 11/11 native bodies, no fallback.
  Covers module/export aliases, shared class identity and single initialization,
  parent/sibling traversal from a different cwd, all source extensions, escaped
  paths, nameless sources, macros, external template providers, mutable-source
  and module-header cache invalidation, conflicting providers, missing files,
  missing exports, cycles, invalid/interpolated paths and build inputs.
- Existing path dependency/graph lock/macro/template/installed import regression.
- VS Code, Vim and notebook syntax tests; string paths use existing lexical rules.
- Notebook-web model test moved to test/model_test.s: VM and full-native
  1342/1342, persistence, transactions and migration integrity.
- Offline Orbit application fixture moved to test/app_fixture.s: full-native
  2585/2585. Four browser scenarios pass in VM and in native (8 total).
- Normal main.s VM startup with GitHub provider and lazy core Client, without
  external requests. No real GitHub authorization or remote deployment occurred.
- Source specs, runtime grammar, cheat sheets and website copies are synchronized.

No source inventories, test-specific manifest, copied application sources or
new Python dependencies were introduced. No commits or package publication.
