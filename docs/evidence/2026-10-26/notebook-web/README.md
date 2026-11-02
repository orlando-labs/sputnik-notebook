# Notebook web scaffold — 2026-10-26

Account/Identity, Project ownership and editor/viewer memberships on ORM/SQLite;
GitHub OAuth + cookie sessions; external SSR layout and Vue/Vite catalog/sharing.

Passed:

- SDK parser, binder, HIR and VM suites. Regression coverage for expressions
  after a multiline block, physical-line limits for bare calls, multiline
  parenthesized calls and qualified native type aliases beside a local Client.
- Dedicated language fixture in VM and strict full-native: 9/9 bodies.
- Models in VM and strict full-native: 1342/1342 bodies. Stable GitHub UID,
  same-login separation, concurrent first login, owner/editor/viewer policies,
  grant/update/revoke, disabled account, constraints, rollback, persistence
  across process reopening and rejecting modified applied migrations.
- Real main.s entry in VM and full-native: 2612/2612 bodies. GitHub provider and
  lazy core Client coexist; startup needs no running agent or external requests.
- Browser matrix: 4 scenarios × VM/native × production/development = 16 passed.
  Includes SSR/bootstrap/assets, Vue UI creation/rename/reload/logout, two-account
  ACL and revocation, UID precision, malformed/denied OAuth, CSRF, unknown-field
  rejection and Vite HMR connection. Native fixture: 2585/2585 bodies.
- vue-tsc + production Vite build; git diff --check; Node tool syntax checks.

All native reports require full coverage, zero fallback and VM independence.
OAuth consent and HTTP exchanges used the local Sputnik GitHub fixture. No real
GitHub authorization, remote deployment or package publication was performed.

Project creation currently writes catalog metadata only; notebook document
provisioning/import and editor/Run/reconnect are the next slice. Electron local
books do not depend on these server records. No GC was added, enabled or changed.
