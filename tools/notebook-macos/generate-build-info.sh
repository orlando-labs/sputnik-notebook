#!/bin/bash
set -euo pipefail

runtime_root=$1
compiler=$2
info_plist=$3
output_dir=$4
channel=${5:-development}
build_id=${6:-}
notebook_root=$(cd "$(dirname "$0")/../.." && pwd -P)

fail() { echo "Notebook build identity: $*" >&2; exit 1; }
case "$channel" in development|release|nightly|daily) ;; *) fail "unsupported build channel: $channel" ;; esac
[[ -z "$build_id" || "$build_id" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || fail "invalid build ID"

component() {
    awk -v key="SPUTNIK_VERSION_$1" '$1 == "#define" && $2 == key { print $3 }' "$runtime_root/runtime/version.h"
}
sputnik_version="$(component MAJOR).$(component MINOR).$(component PATCH)"
[[ "$sputnik_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid runtime/version.h"
[[ "$("$compiler" --version)" == "sputnik $sputnik_version" ]] || fail "compiler and runtime headers have different Sputnik versions; rebuild the compiler"
compiler_sha256=$(shasum -a 256 "$compiler" | awk '{print $1}')
notebook_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")
notebook_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")
[[ "$notebook_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid Notebook version"
[[ "$notebook_build" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "invalid Notebook bundle build number"

# Source archives can provide their original full commit through CI. Without
# Git, source cleanliness is unknown, never implicitly reported as clean.
source_identity() {
    local root override top source_changes
    root=$(cd "$1" && pwd -P)
    override=$2
    revision=null
    dirty=null
    top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)
    if [[ "$top" == "$root" ]]; then
        revision=$(git -C "$root" rev-parse --verify HEAD)
        [[ -z "$override" || "$override" == "$revision" ]] || fail "source revision override disagrees with Git in $root"
        dirty=false
        source_changes=$(git -C "$root" status --porcelain --untracked-files=normal)
        if [[ -n "$source_changes" ]]; then dirty=true; fi
    elif [[ -n "$override" ]]; then
        revision=$override
    fi
    if [[ "$revision" != null ]]; then
        [[ "$revision" =~ ^[0-9a-f]{40}$ || "$revision" =~ ^[0-9a-f]{64}$ ]] || fail "source revision must be a full Git commit"
        revision="\"$revision\""
    fi
}
source_identity "$notebook_root" "${NOTEBOOK_SOURCE_REVISION:-}"
notebook_revision=$revision
notebook_dirty=$dirty
source_identity "$runtime_root" "${SPUTNIK_SOURCE_REVISION:-}"
sputnik_revision=$revision
sputnik_dirty=$dirty
if [[ "$channel" == nightly || "$channel" == daily ]]; then
    [[ "$sputnik_revision" != null ]] || fail "$channel builds require the Sputnik commit (Git checkout or SPUTNIK_SOURCE_REVISION)"
fi

mkdir -p "$output_dir"
staged=$(mktemp -d "$output_dir/.build-info.XXXXXX")
trap 'rm -rf -- "$staged"' EXIT
cat > "$staged/build-info.json" <<EOF
{
  "schema": "sputnik.notebook.build.v1",
  "channel": "$channel",
  "buildID": "$build_id",
  "notebook": {
    "version": "$notebook_version",
    "build": "$notebook_build",
    "revision": $notebook_revision,
    "dirty": $notebook_dirty
  },
  "sputnik": {
    "version": "$sputnik_version",
    "revision": $sputnik_revision,
    "dirty": $sputnik_dirty,
    "compilerSHA256": "$compiler_sha256"
  }
}
EOF
{
    printf '%s\n' '// Generated at build time; do not edit.' 'enum NotebookBuildMetadata {' '    static let json = #"""'
    cat "$staged/build-info.json"
    printf '%s\n' '"""#' '}'
} > "$staged/NotebookBuildMetadata.swift"

# Inspect Git on every make invocation, but preserve timestamps when the
# identity is unchanged so ordinary incremental builds do not relink the UI.
for name in build-info.json NotebookBuildMetadata.swift; do
    if ! cmp -s "$staged/$name" "$output_dir/$name"; then
        mv -f "$staged/$name" "$output_dir/$name"
    fi
done
