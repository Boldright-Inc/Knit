#!/usr/bin/env bash
# Build a redistributable DMG containing:
#   - knit CLI binary
#   - Quick Action workflows
#   - install.sh / uninstall.sh
#
# Optional signing & notarization:
#   DEVELOPER_ID="Developer ID Application: Boldright Inc. (TEAMID)" \
#   NOTARY_PROFILE=knit-notary \
#   ./Scripts/package-dmg.sh
#
# DEVELOPER_ID must be one of `security find-identity -v -p codesigning`.
# NOTARY_PROFILE is a `xcrun notarytool store-credentials <name>` profile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST="${ROOT_DIR}/dist"
STAGING="${DIST}/staging"
DMG_OUT="${DIST}/Knit.dmg"
VOLNAME="Knit"

DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# 1. Build release binary
#    Always wipe `.build/` first. SwiftPM caches `.pcm` modules with the
#    *absolute* repo path baked in, so anyone who has ever moved the
#    project directory (rename, clone elsewhere, switch from Xcode to a
#    fresh checkout, etc.) ends up with an error like:
#       "precompiled file ... was compiled with module cache path
#        '/Users/.../old-path/...' but the path is currently
#        '/Users/.../new-path/...'"
#    Distribution builds should always be reproducible from a clean
#    state anyway, so the cost of re-compiling libdeflate / libzstd
#    here is acceptable.
( cd "${ROOT_DIR}" && rm -rf .build && swift build -c release )
BIN="${ROOT_DIR}/.build/release/knit"

# 2. Build Quick Actions
"${SCRIPT_DIR}/build-quick-actions.sh" >/dev/null

# 3. Build Knit.app (icons + UTI registration bundle)
"${SCRIPT_DIR}/build-app.sh" >/dev/null

# 4. Stage files
rm -rf "${STAGING}"
mkdir -p "${STAGING}/bin" "${STAGING}/QuickActions"
cp "${BIN}" "${STAGING}/bin/knit"
cp -R "${DIST}/Knit.app" "${STAGING}/Knit.app"
cp -R "${DIST}/QuickActions/"*.workflow "${STAGING}/QuickActions/"
cp "${SCRIPT_DIR}/install.sh"   "${STAGING}/install.sh"
cp "${SCRIPT_DIR}/uninstall.sh" "${STAGING}/uninstall.sh"
chmod 0755 "${STAGING}/bin/knit" "${STAGING}/install.sh" "${STAGING}/uninstall.sh"

cat > "${STAGING}/README.txt" <<'EOF'
Knit — Apple Silicon high-speed compression

To install:
    open Terminal.app, cd to this volume, then run:
        ./install.sh

This installs:
    /Applications/Knit.app          (registers .knit icon + UTI)
    /usr/local/bin/knit             (CLI)
    ~/Library/Services/Knit *.workflow (Finder right-click items)

Right-click any file or folder in Finder -> Quick Actions:
    Knit Compress (ZIP)    standard .zip output
    Knit Compress (.knit)  high-speed format
    Knit Extract           handles both formats

To uninstall:
    ./uninstall.sh
EOF

# 5. Sign binary + app if credentials provided
if [[ -n "${DEVELOPER_ID}" ]]; then
    echo ">> codesign with: ${DEVELOPER_ID}"
    codesign --force --options runtime --timestamp \
        --sign "${DEVELOPER_ID}" \
        "${STAGING}/bin/knit"
    codesign --verify --strict --verbose=2 "${STAGING}/bin/knit"
    codesign --force --options runtime --timestamp --deep \
        --sign "${DEVELOPER_ID}" \
        "${STAGING}/Knit.app"
    codesign --verify --strict --verbose=2 "${STAGING}/Knit.app"
fi

# 5. Build DMG
rm -f "${DMG_OUT}"
hdiutil create -volname "${VOLNAME}" -srcfolder "${STAGING}" -ov -format UDZO "${DMG_OUT}"

# 6. Sign + notarize DMG
if [[ -n "${DEVELOPER_ID}" ]]; then
    codesign --force --sign "${DEVELOPER_ID}" --timestamp "${DMG_OUT}"
    if [[ -n "${NOTARY_PROFILE}" ]]; then
        echo ">> Submitting to Apple notary service ($(basename ${DMG_OUT}))..."
        xcrun notarytool submit "${DMG_OUT}" \
            --keychain-profile "${NOTARY_PROFILE}" \
            --wait
        xcrun stapler staple "${DMG_OUT}"
    else
        echo ">> NOTARY_PROFILE not set; DMG signed but not notarized."
    fi
fi

echo
echo "DMG built: ${DMG_OUT}"
ls -lh "${DMG_OUT}"
