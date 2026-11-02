# Notebook web — Stage 4f.2

28 October 2026, macOS arm64, current working tree. Existing unrelated work was
preserved. No production service was changed. Linux was not executed.

## Behavior

- Text cells and board prose resolve `{{name}}` from the immutable saved run's
  declared module-cell bindings. Text sees preceding providers; boards use their
  controller; Published Text binds one explicit source cell. Later/uninitialized
  providers shadow earlier values. Missing values are unavailable; code/draft,
  failed predecessor, history, environment or worker changes mark values stale.
- The native codec projects only requested provider/name pairs, never a general
  locals dictionary. Empty strings and Int64 values remain exact. A value is
  bounded to 4096 Unicode scalars; names/provider records to 256 and projected
  text to 1 MiB. An incomplete projection is discarded completely with a notice.
  Repeated placeholders reuse processed provider/name pairs. Unicode whitespace
  around names is trimmed without evaluating expressions.
- Variable… inserts authored placeholders through the normal local Undo/draft
  path. Newly declared names require Save and an explicit Run. The resolver
  indexes provider order once per snapshot rather than rescanning the sheet for
  every text block. Published values are never saved back into authored text.
- Board Text authors native `richtext`/`markdown` modes. The pinned
  `markdown-it@15.0.3` parser uses HTML/linkify/typographer disabled and nesting
  capped at 16; [parser options](https://markdown-it.github.io/markdown-it/interfaces/MarkdownItOptions.html).
  Its tokens become a closed Vue node vocabulary, with no HTML insertion.
  Headings, emphasis, lists, quotes, tables, code and explicit links render.
  Images show alt text without fetching. Links accept http(s), mail and fragments.
  Parsing and Sputnik fence styling precede literal interpolation; values cannot
  create Markdown/HTML structure or change a URL.
- Portable formatting is retained across mode changes and remapped on Markdown
  source edits. Existing table ownership protections still apply. Designer
  preview remains inert. Cancel/draft/Save/CAS/receipt behavior and unknown
  authored metadata use the existing notebook contract.
- Code cells, Sputnik modules and temporary previews share a lexical overlay and
  line gutter over a textarea. The native palette covers Unicode identifiers,
  callable hashes/comments, numeric forms, tagged/interpolated strings, template
  controls, macro splices and contextual keywords. Coloring does not rewrite
  source or selection. Native browser Undo, Tab insertion and IME remain usable;
  gutter/overlay scroll together without increasing the textarea's height.
- Native execution diagnostics retain up to 100 messages per cell, each at 4096
  scalars, and scalar line/column ranges. The editor converts those to UTF-16,
  underlines current source and selects the range on click. Edits/revisions/
  workers retain previous messages without drawing them over new code. Diagnostic
  navigation never uses a server filesystem path. Module files have highlighting;
  these diagnostic ranges belong to their controller's saved source cells.
- Preview bounds preserve the full authored source: 256 Ki UTF-16 units / 4000
  source lines, 20000 syntax/Markdown work tokens and 4096 substitutions. Rendered
  substitution output has a separate 256 Ki UTF-16 budget. Oversized previews
  visibly fall back to source. No UI preview dispatches code.
- Existing ACL/revocation, reconnect/history and the public preview's 60-second
  cumulative budget remain authoritative. Temporary preview shares code styling
  and text bindings while leaving the template unchanged.

## Verification

| Backend | Assets | Result |
| --- | --- | --- |
| VM | Production | [89/89, complete browser suite](browser-vm-production.log) |
| VM | Vite development | [9 passed](browser-vm-development.log) |
| Full native | Production | [9 passed](browser-native-production.log) |
| Full native | Vite development | [9 passed](browser-native-development.log) |

The nine new scenarios cover scope/order/shadowing, exact/empty/literal values,
immutable old-run projection after new names are saved, stale states, Markdown
structure and non-fetching media/HTML, authoring/picker/metadata, native Unicode
diagnostics and navigation, code Undo/IME/Tab/scroll, module save/reload, viewer
revocation, explicit projection/highlighting limits and temporary preview.

- [48 real-worker remote integrations](core-remote.log).
- [12 policy integrations](core-policy.log), including both override modes,
  public ceilings, aggregate accounting, lease/restart cleanup and retention.
- [Text/syntax/diagnostic/Markdown unit checks](text_features-unit.log), including
  Unicode scalar conversion, split-style placeholders, typed values, invalid
  links, malformed lexical fragments and dense input/work limits.
- Existing [rich text](rich_text-unit.log), [board editor](board_editor-unit.log),
  [board renderer](boards-unit.log), [display](displays-unit.log),
  [input](inputs-unit.log) and [telemetry](telemetry-unit.log) unit checks.
- [Vue/TypeScript and production build](frontend-build.log).
- Real main-entry startup in [VM](main-vm.log) and [full native](main-native.log).
- [Native build summaries](native-summary.json): Core and main/fixture backend
  use complete native body coverage with no VM fallback or runtime bridge.
- [Source and output fingerprints](source-sha256.json). Whitespace checks passed.

The first complete run exhausted Core's intentional eight-worker allowance:
these new fixtures retained idle heaps after their assertions. The final tests
explicitly release their own workers in `afterEach`, keeping authored documents
and results. The original [initial log](browser-vm-production-initial.log) is
retained; final results are in the table above. This changes test cleanup, not
the product worker policy.

Screenshots were visually inspected in light/dark themes and at 375 px; browser
assertions also check 320 px layout and the mobile variable picker bounds.

| View | Light | Dark |
| --- | --- | --- |
| Markdown / published text, desktop | [1280 px](markdown-light-1280.png) | [1280 px](markdown-dark-1280.png) |
| Markdown / published text, mobile | [375 px](markdown-light-375.png) | [375 px](markdown-dark-375.png) |
| Sputnik diagnostics | [Light](sputnik-diagnostics-light.png) | [Dark](sputnik-diagnostics-dark.png) |

[Variable picker at 375 px](text-variable-picker-mobile.png).

Reproduction:

```sh
# Repository root
make -j4 remote-core
node apps/notebook-web/tools/text_features_test.mjs
python3 tests/notebook_remote_tests.py --worker "$PWD/build/sputnik-notebook-worker" --core "$PWD/build/sputnik-notebook-remote"
python3 tests/notebook_policy_tests.py --worker "$PWD/build/sputnik-notebook-worker" --core "$PWD/build/sputnik-notebook-remote"
npm --prefix apps/notebook-web/frontend run build

# apps/notebook-web/frontend
npm run test:browser
ORBIT_E2E_NATIVE=1 npm run test:browser -- test/text-features.spec.ts
ORBIT_E2E_MODE=development npm run test:browser -- test/text-features.spec.ts
ORBIT_E2E_NATIVE=1 ORBIT_E2E_MODE=development npm run test:browser -- test/text-features.spec.ts
```

Use an installed Chromium for Playwright and build main/fixture native binaries
with the commands in the app README. Keep production assets unchanged while a
test server is alive. The next feature slice is Stage 4f.3, remaining editor
operations/conflict conveniences/draft recovery.
