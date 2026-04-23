#!/bin/bash
# Wraps the SPM-built `cider` Mach-O into a properly-shaped Cider.app.
# Usage: ./scripts/build-app.sh [release|debug] [output/path/Cider.app]
#
# Defaults to release + ./build/Cider.app. Ad-hoc signs with the bundled
# entitlements; for distribution, run scripts/sign-and-notarize.sh next.

set -euo pipefail

CONFIG="${1:-release}"
OUTPUT="${2:-./build/Cider.app}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "$CONFIG" in
    release|debug) ;;
    *) echo "build-app.sh: config must be 'release' or 'debug', got '$CONFIG'" >&2; exit 1 ;;
esac

echo "→ swift build -c $CONFIG"
swift build --package-path "$ROOT" -c "$CONFIG" >&2

BIN="$ROOT/.build/$CONFIG/cider"
[ -x "$BIN" ] || { echo "build-app.sh: built binary missing at $BIN" >&2; exit 1; }

echo "→ assembling $OUTPUT"
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources"
cp "$BIN" "$OUTPUT/Contents/MacOS/cider"

# A minimal Info.plist that's hardened-runtime-friendly and gives wine
# the entitlements it needs once we sign with Developer ID.
cat > "$OUTPUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>cider</string>
    <key>CFBundleIdentifier</key><string>com.cider.app</string>
    <key>CFBundleName</key><string>Cider</string>
    <key>CFBundleDisplayName</key><string>Cider</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleSignature</key><string>????</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign with the entitlements. For distribution, scripts/sign-and-notarize.sh
# re-signs with a Developer ID identity and submits to notarytool.
ENTITLEMENTS="$ROOT/Resources/Cider.entitlements"
echo "→ codesign --sign - (ad-hoc) with entitlements"
codesign --force --sign - \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "$OUTPUT/Contents/MacOS/cider"

codesign --force --sign - \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "$OUTPUT"

codesign --verify --verbose=2 "$OUTPUT" >&2

echo "→ done: $OUTPUT"
