#!/bin/bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$root_dir"
make setup

version=$(<VERSION)
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must contain a major.minor.patch version." >&2
    exit 1
fi
if [[ ! -x build/rastertoql580n ]]; then
    echo "Missing prebuilt native filter. Run make before packaging." >&2
    exit 1
fi
if ! command -v zip >/dev/null 2>&1; then
    echo "The zip command is required for packaging." >&2
    exit 1
fi

members=(build/rastertoql580n)
while IFS= read -r file || [[ -n "$file" ]]; do
    [[ -z "$file" || "$file" == \#* ]] && continue
    if [[ "$file" == /* || "$file" == *..* || ! -f "$file" ]]; then
        echo "Invalid or missing package manifest entry: $file" >&2
        exit 1
    fi
    members+=("$file")
done < scripts/package_manifest.txt

mkdir -p dist
source_archive="$root_dir/dist/QL-580N-macOS-Driver-v${version}-Source.zip"
setup_archive="$root_dir/dist/QL-580N-macOS-Driver-v${version}-Setup.zip"
temporary_source="$root_dir/dist/.QL-580N-macOS-Driver-Source.$$.zip"
temporary_setup="$root_dir/dist/.QL-580N-macOS-Driver-Setup.$$.zip"
setup_dir="$root_dir/dist/QL-580N-macOS-Driver-v${version}-Setup"
trap 'rm -f "$temporary_source" "$temporary_setup"; rm -rf "$setup_dir"' EXIT
zip -q -X "$temporary_source" "${members[@]}"
mv -f "$temporary_source" "$source_archive"
echo "$source_archive"

rm -rf "$setup_dir"
mkdir -p "$setup_dir"
cp -R "$root_dir/build/QL-580N macOS Driver Setup.app" "$setup_dir/"
mkdir -p "$setup_dir/docs"
cp "$root_dir/docs/DEVELOPING.md" "$root_dir/docs/TESTED_MEDIA.md" "$setup_dir/docs/"
cp "$root_dir/README.md" "$root_dir/RELEASE_NOTES.md" \
    "$root_dir/LICENSE" "$setup_dir/"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$setup_dir" "$temporary_setup"
mv -f "$temporary_setup" "$setup_archive"
echo "$setup_archive"
(
    cd dist
    checksum_file="$(basename "$setup_archive").sha256"
    shasum -a 256 "$(basename "$setup_archive")" > "$checksum_file"
)
echo "$setup_archive.sha256"
