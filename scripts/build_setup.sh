#!/bin/bash
set -euo pipefail
root_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$root_dir"
version=$(<VERSION)
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must contain a major.minor.patch version." >&2
    exit 1
fi
export CLANG_MODULE_CACHE_PATH="$root_dir/build/clang-module-cache"
make build/rastertoql580n
app="$root_dir/build/QL-580N macOS Driver Setup.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/payload/scripts" \
    "$app/Contents/Resources/payload/build" "$app/Contents/Resources/payload/ppd" \
    "$app/Contents/Resources/payload/assets"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos27.0 \
    -framework AppKit -framework Network installer/PrinterDiscovery.swift installer/App.swift \
    -o "$app/Contents/MacOS/QL580NSetup"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.ql580n.setup</string>
<key>CFBundleName</key><string>QL-580N macOS Driver Setup</string>
<key>CFBundleDisplayName</key><string>QL-580N macOS Driver Setup</string>
<key>CFBundleExecutable</key><string>QL580NSetup</string>
<key>CFBundleIconFile</key><string>QL580NIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Find and verify your Brother QL-580N label printer on the local network.</string>
<key>NSBonjourServices</key><array><string>_pdl-datastream._tcp</string><string>_printer._tcp</string><string>_ipp._tcp</string></array>
</dict></plist>
PLIST
cp scripts/install.sh "$app/Contents/Resources/payload/scripts/"
cp scripts/uninstall.sh "$app/Contents/Resources/payload/scripts/"
cp build/rastertoql580n "$app/Contents/Resources/payload/build/"
cp ppd/Brother-QL-580N-Native.ppd "$app/Contents/Resources/payload/ppd/"
cp assets/ql580n-native.icns "$app/Contents/Resources/payload/assets/"
cp assets/ql580n-native.icns "$app/Contents/Resources/QL580NIcon.icns"
cp LICENSE "$app/Contents/Resources/"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "$app"
