# Preparing a macOS release

`make prepare-notebook-macos-release` prepares an isolated ad-hoc app and release
evidence. It does not create a DMG, upload artifacts or change an installed app.
The version and numeric build number come from `tools/notebook-macos/Info.plist`.
The output directory refuses an overwrite; a new build number identifies a new
preparation.

The preparer records Git revisions, source status, patches, snapshots including
non-ignored untracked files, and per-file content/mode hashes for Notebook,
Sputnik, Orbit, ORM, SQLite3 and Plot. A dedicated output tree builds the app with
the release channel and an explicit build ID. Source hashes are checked again
after the build so concurrent source edits cannot silently alter the release.
Snapshots and build logs are internal evidence, outside the `artifacts` directory.

The bundle carries `build-info.json`, `distribution-info.json`, source essentials,
extension ABI headers, non-system dylibs and third-party notices. The audit checks
that all Mach-O components are arm64, no loader path points to a developer's
checkout or Homebrew, all non-system dependencies resolve within Frameworks, and
the bundle's minimum macOS covers every component's deployment target. It verifies
all component signatures and the complete bundle, and records the separate
Gatekeeper assessment. Ad-hoc signature validity never implies notarization.

The resulting `artifacts/release.json` records the frozen build identity, source
fingerprints, component hashes, license file inventory and signing state. Keep
the relocation test evidence with the build logs. If the app bundles LGPL
libraries, preserve the corresponding source archives and build recipes for the
download page. See the [GNU licenses FAQ](https://www.gnu.org/licenses/gpl-faq.en.html).
The source SDK supports extension builds; standalone native program generation
requires the separate full Sputnik runtime sources and is not a bundled SDK
feature. Source-built extensions also require the platform's compilation tools.
