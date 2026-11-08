#!/bin/bash
set -euo pipefail

# Prepare steps 1–3 only: a frozen, audited ad-hoc app. No DMG or upload.
root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(dirname "$root")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root/tools/notebook-macos/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$root/tools/notebook-macos/Info.plist")
architecture=$(uname -m)
[[ "$architecture" == arm64 ]] || { echo "This release target requires Apple Silicon" >&2; exit 1; }
release="$root/build/releases/$version-$build-macos-$architecture"
[[ ! -e "$release" ]] || { echo "Release directory already exists: $release" >&2; exit 1; }
mkdir -p "$release"/{artifacts,provenance,logs,sources,work}
repositories=(sputnik-notebook sputnik-lang orbit orm sqlite3 plot)
for repository in "${repositories[@]}"; do
    source="$workspace/$repository"
    git -C "$source" rev-parse HEAD > "$release/provenance/$repository.commit"
    git -C "$source" status --porcelain --untracked-files=normal > "$release/provenance/$repository.status"
    git -C "$source" diff --binary --no-ext-diff HEAD > "$release/provenance/$repository.patch"
    bash "$root/tools/notebook-macos/snapshot-sources.sh" "$source" "$release/sources/$repository" "$release/provenance/$repository.sources"
done
build_id="$(date -u +%Y-%m-%d).$build-adhoc"
echo "Building Notebook $version ($build), $architecture, $build_id"
make -s -C "$root" -j2 notebook-macos \
    BUILD_DIR="$release/work" NOTEBOOK_BUILD_CHANNEL=release NOTEBOOK_BUILD_ID="$build_id" \
    > "$release/logs/build.log" 2>&1
for repository in "${repositories[@]}"; do
    bash "$root/tools/notebook-macos/snapshot-sources.sh" "$workspace/$repository" - "$release/provenance/$repository.after"
    cmp "$release/provenance/$repository.sources" "$release/provenance/$repository.after" || {
        echo "Sources changed during the release build: $repository" >&2; exit 1;
    }
    rm "$release/provenance/$repository.after"
done
ditto "$release/work/Sputnik Notebook.app" "$release/artifacts/Sputnik Notebook.app"
compiler="$workspace/sputnik-lang/build/sputnik"
"$compiler" run "$root/tools/notebook-macos/audit-release.s" \
    --grant fs.read --grant fs.write --grant fs.metadata --grant process.spawn \
    -- --release "$release" > "$release/logs/audit.log" 2>&1
chmod 644 "$release/artifacts/release.json"
notes="$root/docs/releases/$version-$build-macos.md"
if [[ -f "$notes" ]]; then
    cp "$notes" "$release/artifacts/Release Notes.md"
fi
echo "Prepared and audited: $release/artifacts"
