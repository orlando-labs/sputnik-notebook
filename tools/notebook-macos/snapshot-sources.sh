#!/bin/bash
set -euo pipefail

# Internal release provenance, not part of the downloadable application.
# Copy tracked and non-ignored untracked source bytes without touching Git.
root=$(cd "$1" && pwd -P)
destination=$2
manifest=$3
mkdir -p "$(dirname "$manifest")"
list=$(mktemp)
trap 'rm -f -- "$list"' EXIT
git -C "$root" ls-files -z --cached --others --exclude-standard > "$list"
: > "$manifest"
while IFS= read -r -d '' relative; do
    source="$root/$relative"
    [[ -f "$source" || -L "$source" ]] || continue
    if [[ "$destination" != - ]]; then
        mkdir -p "$destination/$(dirname "$relative")"
        cp -pP "$source" "$destination/$relative"
    fi
    if [[ -L "$source" ]]; then
        digest=$(readlink "$source" | shasum -a 256 | awk '{print $1}')
        kind=symlink
    else
        digest=$(shasum -a 256 "$source" | awk '{print $1}')
        kind=file
    fi
    mode=$(stat -f '%Lp' "$source")
    printf '%s %s %s %s\n' "$digest" "$mode" "$kind" "$relative" >> "$manifest"
done < "$list"
