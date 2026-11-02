# Notebook web welcome screen — 2026-10-27

The existing Orbit/Vue scaffold now follows the Swift welcome screen in
`tools/notebook-macos/NotebookWelcomeView.swift` and the default light/dark
colors in `NotebookPalette.swift`.

- Same 72 px notebook mark with a 21 px radius, 30 px rounded heading,
  13 px subtitle, compact actions, 680 px library and 12 px library corners.
- Authenticated library with expandable metadata, search, refresh and Last
  Opened / Date Created / Name sorting. Browser preferences and actual opening
  timestamps are scoped to the account; storage failure does not block usage.
- New Notebook uses a native modal dialog with focus management, Escape/Cancel,
  validation, pending state and recoverable API errors. Open Notebook expands
  the library and focuses search.
- Project placeholder with the actual project ID, owner ID, creation/update
  dates and permitted title editing. Sharing remains owner-only; viewers have
  read-only metadata and editors can rename without managing access.
- Responsive layouts verified at 320, 375 and 1280 px, long project names,
  system light/dark appearance and reduced motion. Inline SVG icons replace
  the scaffold's unrelated glyphs and favicon.

The backend API, database and catalog semantics are unchanged. Creating a
project still creates metadata only. Notebook files, folder import, the editor
and execution remain outside this slice.

## Validation

`npm run build --prefix frontend` passed (`vue-tsc --noEmit` and Vite; 17
modules). Whitespace checks passed for all nine changed source/config/doc files,
and `git diff --check` passed for existing tracked changes.

The ten browser scenarios passed in all four supported fixture configurations:

| Backend | Assets | Result | Log |
| --- | --- | --- | --- |
| VM | Production | 10 passed | [log](browser-vm-production.log) |
| VM | Development + HMR | 10 passed | [log](browser-vm-development.log) |
| Existing native fixture | Production | 10 passed | [log](browser-native-production.log) |
| Existing native fixture | Development + HMR | 10 passed | [log](browser-native-development.log) |

Coverage includes SSR/assets, CSRF/session/logout, creation/rename/reload,
private catalog/ACL/revocation, failed OAuth, library state/search/sort/refresh,
account isolation, dialog keyboard/error recovery, UI grant/update/revoke,
responsive light/dark pages and unavailable browser storage.

Executed from `apps/notebook-web` using an existing Chromium executable via
`PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` (a new optional test-runner setting):

```sh
npm run test:browser --prefix frontend
ORBIT_E2E_MODE=development npm run test:browser --prefix frontend
ORBIT_E2E_NATIVE=1 npm run test:browser --prefix frontend
ORBIT_E2E_NATIVE=1 ORBIT_E2E_MODE=development npm run test:browser --prefix frontend
```

All sign-in flows used the local offline GitHub fixture and disposable test
SQLite databases. No real GitHub account or persistent user database was used.

## Screenshots

Captured against a separate clean local fixture with three example projects;
reviewed the light desktop library/project, dark mobile library/project and
the creation dialog. Browser checks also capture 200-character title layouts
under `apps/notebook-web/build/welcome-*.png`.

- [Welcome, light](welcome-light.png), [dark](welcome-dark.png),
  [dark mobile](welcome-dark-mobile.png).
- [Guest](guest-light.png), [empty library](empty-library-light.png),
  [New Notebook dialog](new-notebook-light.png).
- [Project metadata, light](project-light.png),
  [project metadata, dark mobile](project-dark-mobile.png).
