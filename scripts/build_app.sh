#!/usr/bin/env bash
# build_app.sh — Build DemoStrudel.app and package it in dist/
# Usage: bash scripts/build_app.sh  (from repo root)
# Produces: dist/DemoStrudel.app  (signed with Developer ID or ad-hoc fallback)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="DemoStrudel"
BINARY_NAME="DemoStrudelApp"
BUNDLE_ID="net.vct.demostrudel"
VERSION="0.1.0"
MIN_MACOS="14.0"

BUILD_DIR=".build/release"
APP_DIR="dist/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
ENTITLEMENTS="${REPO_ROOT}/scripts/entitlements.plist"

# Developer ID for real signing (override with CODESIGN_IDENTITY env var or set to "" to force ad-hoc)
DEVELOPER_ID="Developer ID Application: Moonshot.la LLC (963B3Q33V9)"

# SPM names the resource bundle <PackageName>_<TargetName>.bundle
SPM_BUNDLE="${BUILD_DIR}/DemoStrudel_DemoStrudelApp.bundle"

# ---------------------------------------------------------------------------
echo "==> 1. Swift build (release)"
# ---------------------------------------------------------------------------
swift build -c release

# ---------------------------------------------------------------------------
echo "==> 2. Setting up dist/ structure"
# ---------------------------------------------------------------------------
rm -rf dist/
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# ---------------------------------------------------------------------------
echo "==> 3. Copying binary"
# ---------------------------------------------------------------------------
cp "${BUILD_DIR}/${BINARY_NAME}" "${MACOS_DIR}/${BINARY_NAME}"

# ---------------------------------------------------------------------------
echo "==> 4. Writing Info.plist"
# ---------------------------------------------------------------------------
cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Demo Strudel</string>
    <key>CFBundleExecutable</key>
    <string>${BINARY_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 vct.net. Demo use only.</string>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------------------
echo "==> 5. Copying SPM resource bundle (contains Samples/ + StrudelWeb/)"
# ---------------------------------------------------------------------------
if [ -d "$SPM_BUNDLE" ]; then
    BUNDLE_DEST="${RESOURCES_DIR}/$(basename "$SPM_BUNDLE")"
    cp -R "$SPM_BUNDLE" "$BUNDLE_DEST"
    echo "    Copied: $(basename "$SPM_BUNDLE") → Contents/Resources/"
else
    echo "    ERROR: SPM bundle not found at $SPM_BUNDLE"
    echo "           The app would crash at launch without it. Aborting."
    exit 1
fi

# ---------------------------------------------------------------------------
echo "==> 6. Code signing"
# ---------------------------------------------------------------------------

# Allow override via environment variable
SIGN_ID="${CODESIGN_IDENTITY:-}"

if [ -z "$SIGN_ID" ]; then
    # Auto-detect: check if Developer ID is available in keychain
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "963B3Q33V9"; then
        SIGN_ID="$DEVELOPER_ID"
    else
        SIGN_ID="-"  # ad-hoc fallback
    fi
fi

if [ "$SIGN_ID" = "-" ]; then
    echo "    Using ad-hoc signing (no Developer ID found)"
    codesign --force --deep -s - "$APP_DIR"
    echo "    Signed (ad-hoc): ${APP_DIR}"
    SIGNED_TYPE="ad-hoc"
else
    echo "    Using Developer ID: ${SIGN_ID}"
    # Hardened runtime required for Developer ID distribution.
    # WKWebView's JavaScript engine requires the JIT entitlement under hardened runtime.
    # The SPM resource bundle is data-only (no Info.plist / no code) — it cannot
    # and need not be signed separately; it gets sealed as a resource of the .app.
    # Signing the .app signs the main executable with the entitlements.
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --entitlements "$ENTITLEMENTS" \
        -s "$SIGN_ID" \
        "$APP_DIR"
    echo "    Signed (Developer ID + hardened runtime + JIT): ${APP_DIR}"
    SIGNED_TYPE="Developer ID"
fi

# ---------------------------------------------------------------------------
echo "==> 7. Verifying signature"
# ---------------------------------------------------------------------------
echo ""
echo "    --- codesign --verify --deep --strict ---"
if codesign --verify --deep --strict --verbose=2 "$APP_DIR" 2>&1; then
    echo "    codesign verify: OK"
else
    echo "    WARNING: codesign verify returned non-zero"
fi

echo ""
echo "    --- spctl --assess ---"
if spctl --assess --type execute --verbose "$APP_DIR" 2>&1; then
    echo "    spctl assess: OK (Gatekeeper would accept)"
else
    echo "    NOTE: spctl assess failed — expected without notarization."
    echo "          First open: right-click → Open (Gatekeeper bypass)."
fi

# ---------------------------------------------------------------------------
echo ""
echo "==> 8. Summary"
# ---------------------------------------------------------------------------
echo ""
echo "    App bundle  : ${APP_DIR}"
echo "    App size    : $(du -sh "$APP_DIR" | cut -f1)"
echo "    Binary      : $(ls -lh "${MACOS_DIR}/${BINARY_NAME}" | awk '{print $5}')"
echo "    Signed with : ${SIGNED_TYPE}"
echo ""
echo "==> Done."
echo ""
echo "    To share (Gatekeeper): recipient right-clicks → Open on first launch."
echo "    Note: without notarization Gatekeeper shows a warning — that is expected."
echo "    Run scripts/make_dmg.sh to create dist/DemoStrudel.dmg"
