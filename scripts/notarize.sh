#!/usr/bin/env bash
# notarize.sh — Notarize and staple dist/DemoStrudel.dmg
#
# One-time prerequisites:
#   1. Generate an app-specific password at https://appleid.apple.com
#      (Sign-In & Security → App-Specific Passwords)
#   2. Store it in the keychain (use the app-specific password, NOT your Apple ID password):
#        xcrun notarytool store-credentials "demostrudel-notary" \
#            --apple-id adad@vct.net \
#            --team-id 963B3Q33V9
#
# Usage: bash scripts/notarize.sh   (after scripts/make_dmg.sh)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DMG_PATH="dist/DemoStrudel.dmg"
KEYCHAIN_PROFILE="${NOTARY_PROFILE:-demostrudel-notary}"

if [ ! -f "$DMG_PATH" ]; then
    echo "ERROR: ${DMG_PATH} not found. Run scripts/make_dmg.sh first."
    exit 1
fi

echo "==> 1. Submitting to Apple notary service (may take a few minutes)..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo ""
echo "==> 2. Stapling ticket to DMG..."
xcrun stapler staple "$DMG_PATH"

echo ""
echo "==> 3. Validating staple..."
xcrun stapler validate "$DMG_PATH"

echo ""
echo "==> 4. Gatekeeper check..."
spctl -a -t open --context context:primary-signature -v "$DMG_PATH" || true

echo ""
echo "==> Done. ${DMG_PATH} is notarized and stapled."
echo "    Recipients can open it with a double-click — no Gatekeeper bypass needed."
