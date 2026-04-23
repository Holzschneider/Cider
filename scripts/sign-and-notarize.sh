#!/bin/bash
# Re-signs a built Cider.app with a Developer ID identity, submits to
# Apple's notary service, and staples the ticket. Run AFTER build-app.sh.
#
# Usage:
#   ./scripts/sign-and-notarize.sh \
#       --identity "Developer ID Application: Your Name (TEAMID)" \
#       --keychain-profile "AC_PASSWORD" \
#       [--input ./build/Cider.app] \
#       [--output ./build/Cider-notarized.zip]
#
# Prereqs (one-time):
#   1. Apple Developer Program membership ($99/yr).
#   2. A "Developer ID Application" certificate installed in your keychain.
#   3. An app-specific password stored via:
#          xcrun notarytool store-credentials AC_PASSWORD \
#              --apple-id "you@example.com" \
#              --team-id "TEAMID" \
#              --password "xxxx-xxxx-xxxx-xxxx"
#
# This script is stubbed but intentionally NOT executed from CI yet —
# Phase 11 stops here so the first notarization pass is a human-driven
# ritual. Once it succeeds, wire it into a release workflow.

set -euo pipefail

INPUT="./build/Cider.app"
OUTPUT="./build/Cider-notarized.zip"
IDENTITY=""
KEYCHAIN_PROFILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity)          IDENTITY="$2"; shift 2 ;;
        --keychain-profile)  KEYCHAIN_PROFILE="$2"; shift 2 ;;
        --input)             INPUT="$2"; shift 2 ;;
        --output)            OUTPUT="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

[[ -n "$IDENTITY"         ]] || { echo "--identity required" >&2; exit 1; }
[[ -n "$KEYCHAIN_PROFILE" ]] || { echo "--keychain-profile required" >&2; exit 1; }
[[ -d "$INPUT"            ]] || { echo "input .app not found at $INPUT" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$ROOT/Resources/Cider.entitlements"

echo "→ re-signing $INPUT with $IDENTITY"
codesign --force --deep --sign "$IDENTITY" \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "$INPUT/Contents/MacOS/cider"

codesign --force --deep --sign "$IDENTITY" \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    "$INPUT"

codesign --verify --deep --strict --verbose=2 "$INPUT" >&2

echo "→ zipping for notarization submission"
rm -f "$OUTPUT"
ditto -c -k --keepParent "$INPUT" "$OUTPUT"

echo "→ xcrun notarytool submit (this usually takes 5–30 min)"
xcrun notarytool submit "$OUTPUT" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo "→ xcrun stapler staple $INPUT"
xcrun stapler staple "$INPUT"

echo "→ spctl --assess --type execute (double-check Gatekeeper accepts it)"
spctl --assess --type execute --verbose=4 "$INPUT" || true

echo "→ done. Notarized bundle at $INPUT, zip at $OUTPUT"
