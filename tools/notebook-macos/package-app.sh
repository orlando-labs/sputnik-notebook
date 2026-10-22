#!/bin/bash
set -euo pipefail

# Build artifact assembly only. Never modifies an installed app or a document.
binary=$1
app=$2
openssl_lib=$3
worker=$4
remote=$5
compiler=$6
runtime_root=${7:-../sputnik-lang}
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Frameworks" "$contents/Resources"
# Replace Mach-O files by rename, not in-place truncation. An already-running
# development window must retain its old mapped executable/libraries.
copy_macho() {
    local staged
    staged=$(mktemp "$2.next.XXXXXX")
    cp -L "$1" "$staged"
    chmod 755 "$staged"
    mv -f "$staged" "$2"
}
copy_macho "$binary" "$contents/MacOS/SputnikNotebook"
copy_macho "$worker" "$contents/MacOS/sputnik-notebook-worker"
copy_macho "$remote" "$contents/MacOS/sputnik-notebook-remote"
copy_macho "$compiler" "$contents/MacOS/sputnik"
# The helper shares the app's bundled libraries, not Homebrew search paths.
xcrun install_name_tool -add_rpath @executable_path/../Frameworks "$contents/MacOS/sputnik-notebook-worker"
xcrun install_name_tool -add_rpath @executable_path/../Frameworks "$contents/MacOS/sputnik-notebook-remote"
xcrun install_name_tool -add_rpath @executable_path/../Frameworks "$contents/MacOS/sputnik"
cp tools/notebook-macos/Info.plist "$contents/Info.plist"
cp tools/notebook-macos/Assets/AppIcon.icns "$contents/Resources/AppIcon.icns"

# Source/native packages compile against this compiler's extension ABI even
# after the application is moved away from the development checkout.
python3 - "$runtime_root" "$contents/Resources/sputnik-sdk" <<'PY'
import pathlib, shutil, sys
source, destination = map(pathlib.Path, sys.argv[1:])
for folder in ("runtime", "bytecode", "frontend", "profile", "optimizer", "frozen", "spec", "package", "notebook", "buildsys", "third_party/tomlplusplus"):
    for path in (source / folder).rglob("*"):
        if path.is_file() and path.suffix in (".h", ".hpp", ".inc", ".def"):
            target = destination / path.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
for name in ("tomlplusplus", "libyaml"):
    license = source / "third_party" / name / "LICENSE"
    if license.is_file():
        target = destination.parent / "licenses" / (name + ".txt")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(license, target)
PY

# Follow actual linkage, including optional runtime crypto backends. Leaving a
# Homebrew dependency of a bundled library unresolved makes the app work only
# on the build machine. System frameworks and Swift's OS libraries stay shared.
sources=("$binary" "$worker" "$remote" "$compiler")
outputs=("$contents/MacOS/SputnikNotebook" "$contents/MacOS/sputnik-notebook-worker" "$contents/MacOS/sputnik-notebook-remote" "$contents/MacOS/sputnik")
index=0
while (( index < ${#sources[@]} )); do
    source_file=${sources[$index]}
    file=${outputs[$index]}
    while IFS= read -r dependency; do
        case "$dependency" in
            /System/Library/*|/usr/lib/*) continue ;;
            /*) resolved=$dependency ;;
            @rpath/*|@loader_path/*)
                resolved="$(dirname "$source_file")/${dependency##*/}"
                if ! test -f "$resolved"; then resolved="$openssl_lib/${dependency##*/}"; fi ;;
            *) echo "Cannot bundle dependency: $dependency" >&2; exit 1 ;;
        esac
        test -f "$resolved" || { echo "Missing dependency: $dependency" >&2; exit 1; }
        name=${dependency##*/}
        destination="$contents/Frameworks/$name"
        found=false
        for (( previous=1; previous<${#outputs[@]}; previous++ )); do
            if [[ "${outputs[$previous]}" == "$destination" ]]; then
                cmp -s "${sources[$previous]}" "$resolved" || {
                    echo "Conflicting dependency names: $name" >&2; exit 1;
                }
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            copy_macho "$resolved" "$destination"
            chmod u+w "$destination"
            xcrun install_name_tool -id "@rpath/$name" "$destination"
            sources+=("$resolved")
            outputs+=("$destination")
            # Keep license notices with optional Homebrew dependencies too.
            for notice in LICENSE.txt COPYING COPYING.LESSERv3; do
                license="$(dirname "$resolved")/../$notice"
                if test -f "$license"; then
                    cp "$license" "$contents/Resources/$name-$notice"
                fi
            done
        fi
        xcrun install_name_tool -change "$dependency" "@rpath/$name" "$file"
    done < <(otool -L "$source_file" | sed -E '1d; s/^[[:space:]]*//; s/ \(compatibility version.*$//')
    index=$((index + 1))
done
minimum_os=$(
    for file in "${outputs[@]}"; do
        xcrun vtool -show-build "$file"
    done | awk '$1 == "minos" { split($2, v, "."); key=v[1]*1000000+v[2]*1000+v[3]; if(key>largest){largest=key; version=$2} } END { if(version != "") print version; else print "14.0" }'
)
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $minimum_os" "$contents/Info.plist"
cp /etc/ssl/cert.pem "$contents/Resources/ca-certificates.crt"
if test -f "$openssl_lib/../LICENSE.txt"; then
    cp "$openssl_lib/../LICENSE.txt" "$contents/Resources/OpenSSL-LICENSE.txt"
fi
# Ad-hoc development signature, NOT Developer ID signing/notarization.
for (( index=1; index<${#outputs[@]}; index++ )); do
    codesign --force --sign - "${outputs[$index]}"
done
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built $app (minimum macOS $minimum_os, including bundled dependencies)"
