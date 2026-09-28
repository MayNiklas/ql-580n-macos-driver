#!/bin/bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")" && pwd)
cd "$root_dir"
if [[ $# -eq 0 ]]; then
    echo "Enter the QL-580N's IPv4 address or DNS hostname."
    read -r -p "Printer address: " printer_host
    if [[ -z "$printer_host" ]]; then
        echo "No printer address entered."
        exit 1
    fi
    read -r -p "Display name [QL-580N macOS Driver]: " printer_name
    printer_name=${printer_name:-QL-580N macOS Driver}
    arguments=(--host "$printer_host" --name "$printer_name")
else
    arguments=("$@")
fi
/bin/bash "$root_dir/scripts/install.sh" "${arguments[@]}" --dry-run
if [[ ! -x "$root_dir/build/rastertoql580n" ]]; then
    make
fi
# Stage outside Downloads so the administrator process can read the files
# without separate access to the user's protected Downloads directory.
staging=$(mktemp -d /private/tmp/ql580n-install.XXXXXX)
cleanup() {
    rm -f "$staging/scripts/install.sh" "$staging/build/rastertoql580n" \
        "$staging/ppd/Brother-QL-580N-Native.ppd" "$staging/assets/ql580n-native.icns"
    rmdir "$staging/scripts" "$staging/build" "$staging/ppd" "$staging/assets" "$staging"
}
trap cleanup EXIT
mkdir "$staging/scripts" "$staging/build" "$staging/ppd" "$staging/assets"
cp "$root_dir/scripts/install.sh" "$staging/scripts/"
cp "$root_dir/build/rastertoql580n" "$staging/build/"
cp "$root_dir/ppd/Brother-QL-580N-Native.ppd" "$staging/ppd/"
cp "$root_dir/assets/ql580n-native.icns" "$staging/assets/"
sudo /bin/bash "$staging/scripts/install.sh" "${arguments[@]}"
