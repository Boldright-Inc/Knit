#!/usr/bin/env bash
# Build Knit.app:
#   - compiles Sources/KnitApp/main.swift to a Mach-O executable
#   - generates AppIcon.icns and KnitDocument.icns
#   - assembles the .app bundle at dist/Knit.app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST="${ROOT_DIR}/dist"
APP="${DIST}/Knit.app"
ICONS_TMP="${DIST}/.icons"

mkdir -p "${DIST}"
rm -rf "${APP}" "${ICONS_TMP}"
mkdir -p "${ICONS_TMP}"

# 1. Generate icon PNGs.
#    If Resources/Icons/app-icon.png exists, use it (and optionally doc-icon.png).
#    Otherwise fall back to the Swift-drawn defaults in make-icons.swift.
APP_ICON_PNG="${ROOT_DIR}/Resources/Icons/app-icon.png"
if [[ -f "${APP_ICON_PNG}" ]]; then
    echo ">> Building icons from Resources/Icons/*.png"
    swift "${SCRIPT_DIR}/build-icons-from-png.swift" "${ICONS_TMP}"
else
    echo ">> Resources/Icons/app-icon.png not found — using Swift-drawn defaults"
    swift "${SCRIPT_DIR}/make-icons.swift" "${ICONS_TMP}"
fi

# 2. Convert .iconset directories to .icns
echo ">> Packing .icns"
iconutil -c icns -o "${ICONS_TMP}/AppIcon.icns"      "${ICONS_TMP}/AppIcon.iconset"
iconutil -c icns -o "${ICONS_TMP}/KnitDocument.icns" "${ICONS_TMP}/KnitDocument.iconset"

# 3. Assemble the bundle layout.
echo ">> Assembling Knit.app"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

# Info.plist
cp "${ROOT_DIR}/Sources/KnitApp/Info.plist" "${APP}/Contents/Info.plist"

# Icons
cp "${ICONS_TMP}/AppIcon.icns"      "${APP}/Contents/Resources/AppIcon.icns"
cp "${ICONS_TMP}/KnitDocument.icns" "${APP}/Contents/Resources/KnitDocument.icns"

# 4. Compile the launcher. Glob every .swift in Sources/KnitApp/ so
#    new files (e.g. OperationCoordinator.swift, PR #57) get picked up
#    without having to update this list each time.
echo ">> Compiling launcher (swiftc)"
KNIT_APP_SOURCES=("${ROOT_DIR}/Sources/KnitApp/"*.swift)
swiftc -O \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -target arm64-apple-macos15.0 \
    -framework AppKit \
    -o "${APP}/Contents/MacOS/Knit" \
    "${KNIT_APP_SOURCES[@]}"

# 5. PkgInfo (legacy but harmless; some tools still check for it).
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# 6. Strip and ad-hoc sign so Gatekeeper accepts a local launch.
strip -x "${APP}/Contents/MacOS/Knit" 2>/dev/null || true
codesign --force --deep --sign - "${APP}" 2>/dev/null || true

rm -rf "${ICONS_TMP}"

echo
echo "Built: ${APP}"
ls -la "${APP}/Contents/" "${APP}/Contents/Resources/"
