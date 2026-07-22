#!/usr/bin/env bash
# make_dmg.sh — Package dist/DemoStrudel.app into dist/DemoStrudel.dmg
# Usage: bash scripts/make_dmg.sh  (from repo root, after build_app.sh)
# Produces: dist/DemoStrudel.dmg  (UDZO compressed, ~drag-to-Applications)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_DIR="dist/DemoStrudel.app"
DMG_PATH="dist/DemoStrudel.dmg"
DMG_STAGING="dist/_dmg_staging"
VOLNAME="DemoStrudel"

# Guard
if [ ! -d "$APP_DIR" ]; then
    echo "ERROR: ${APP_DIR} not found. Run scripts/build_app.sh first."
    exit 1
fi

# ---------------------------------------------------------------------------
echo "==> 1. Preparing staging folder"
# ---------------------------------------------------------------------------
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_DIR" "$DMG_STAGING/"

# Symlink to /Applications for drag-install convenience
ln -s /Applications "$DMG_STAGING/Applications"

# ---------------------------------------------------------------------------
echo "==> 2. Creating DMG (UDZO)"
# ---------------------------------------------------------------------------
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# ---------------------------------------------------------------------------
echo "==> 3. Verifying DMG contents"
# ---------------------------------------------------------------------------
MOUNT_POINT="/Volumes/${VOLNAME}"

# Detach if already mounted
if [ -d "$MOUNT_POINT" ]; then
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
fi

hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_POINT" -nobrowse -quiet

echo ""
echo "    Mounted at: ${MOUNT_POINT}"
echo ""
echo "    --- Contents of DMG ---"
ls -la "$MOUNT_POINT/"

INNER_APP="${MOUNT_POINT}/DemoStrudel.app"

if [ ! -d "$INNER_APP" ]; then
    echo "ERROR: DemoStrudel.app not found inside DMG!"
    hdiutil detach "$MOUNT_POINT" -quiet
    exit 1
fi

echo ""
echo "    --- Contents of .app ---"
find "$INNER_APP/Contents" -type f | sort

# Check for required resources
BUNDLE_INSIDE=$(find "$INNER_APP/Contents/Resources" -name "*.bundle" -maxdepth 1 | head -1)
if [ -z "$BUNDLE_INSIDE" ]; then
    echo "    WARNING: no SPM resource bundle found inside .app"
else
    echo ""
    echo "    --- SPM bundle resources ---"
    find "$BUNDLE_INSIDE" -type f | sort
fi

hdiutil detach "$MOUNT_POINT" -quiet
echo ""
echo "    Unmounted."

# ---------------------------------------------------------------------------
echo ""
echo "==> 4. Cleanup staging"
# ---------------------------------------------------------------------------
rm -rf "$DMG_STAGING"

# ---------------------------------------------------------------------------
echo ""
echo "==> Done."
echo ""
echo "    DMG path : ${DMG_PATH}"
echo "    DMG size : $(du -sh "$DMG_PATH" | cut -f1)"
