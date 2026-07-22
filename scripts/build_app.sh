#!/usr/bin/env bash
# build_app.sh — Build DemoStrudel.app and package it in dist/
# Usage: bash scripts/build_app.sh  (from repo root)
# Produces: dist/DemoStrudel.app  (ad-hoc signed, ready for Gatekeeper bypass)
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
echo "==> 5. Copying SPM resource bundle (contains Samples/)"
# ---------------------------------------------------------------------------
if [ -d "$SPM_BUNDLE" ]; then
    BUNDLE_DEST="${RESOURCES_DIR}/$(basename "$SPM_BUNDLE")"
    cp -R "$SPM_BUNDLE" "$BUNDLE_DEST"
    echo "    Copied: $(basename "$SPM_BUNDLE") → Contents/Resources/"
else
    echo "    WARNING: SPM bundle not found at $SPM_BUNDLE"
    echo "    Falling back to copying Samples from source tree..."
    cp -R "Sources/DemoStrudelApp/Samples" "$RESOURCES_DIR/"
fi

# ---------------------------------------------------------------------------
echo "==> 6. Ad-hoc code signing"
# ---------------------------------------------------------------------------
codesign --force --deep -s - "$APP_DIR"
echo "    Signed (ad-hoc): ${APP_DIR}"

# ---------------------------------------------------------------------------
echo "==> 7. Summary"
# ---------------------------------------------------------------------------
echo ""
echo "    App bundle : ${APP_DIR}"
echo "    App size   : $(du -sh "$APP_DIR" | cut -f1)"
echo "    Binary     : $(ls -lh "${MACOS_DIR}/${BINARY_NAME}" | awk '{print $5}')"
echo ""
echo "==> Done."
echo ""
echo "    To open on this Mac : open '${APP_DIR}'"
echo "    To share (Gatekeeper): recipient right-clicks → Open on first launch."
