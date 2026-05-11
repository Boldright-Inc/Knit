#!/usr/bin/env bash
# Build a redistributable Knit-Installer.pkg.
#
# Output:
#   dist/Knit-Installer.pkg
#       Double-click to launch the standard macOS installer GUI.
#       Installs Knit.app, the `knit` CLI, and the three Quick Action
#       workflows. Runs Launch Services + icon cache refresh in postinstall.
#
# Optional signing & notarization (set these env vars to enable):
#   APP_ID="Developer ID Application: Boldright Inc. (TEAMID)"
#   INSTALLER_ID="Developer ID Installer: Boldright Inc. (TEAMID)"
#   NOTARY_PROFILE="knit-notary"        # `xcrun notarytool store-credentials`
#
# See docs/SIGNING.md for how to obtain those.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST="${ROOT_DIR}/dist"
STAGING="${DIST}/.pkg-staging"
PAYLOAD="${STAGING}/payload"
COMPONENT_PKG="${STAGING}/Knit.component.pkg"
DIST_PKG_UNSIGNED="${STAGING}/Knit-Installer-unsigned.pkg"
PKG_OUT="${DIST}/Knit-Installer.pkg"

PKG_SCRIPTS="${SCRIPT_DIR}/pkg-scripts"
PKG_RESOURCES="${SCRIPT_DIR}/pkg-resources"

APP_ID="${APP_ID:-}"
INSTALLER_ID="${INSTALLER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# ---------------------------------------------------------------------------
# 1. Build artifacts
# ---------------------------------------------------------------------------
echo ">> Building knit (release)"
( cd "${ROOT_DIR}" && swift build -c release ) >/dev/null

echo ">> Building Knit.app"
"${SCRIPT_DIR}/build-app.sh" >/dev/null

echo ">> Building Quick Actions"
"${SCRIPT_DIR}/build-quick-actions.sh" >/dev/null

# ---------------------------------------------------------------------------
# 2. Stage the payload tree (mirrors the file system layout the installer
#    will write to under '/').
# ---------------------------------------------------------------------------
echo ">> Staging payload"
rm -rf "${STAGING}"
mkdir -p "${PAYLOAD}/Applications" \
         "${PAYLOAD}/usr/local/bin" \
         "${PAYLOAD}/Library/Services"

cp -R "${DIST}/Knit.app"                    "${PAYLOAD}/Applications/Knit.app"
cp    "${ROOT_DIR}/.build/release/knit"     "${PAYLOAD}/usr/local/bin/knit"
cp -R "${DIST}/QuickActions/"*.workflow     "${PAYLOAD}/Library/Services/"
chmod 0755 "${PAYLOAD}/usr/local/bin/knit"

# Stage the user-facing uninstaller as /Applications/Uninstall Knit.command.
# macOS .pkg has no native uninstall mechanism (unlike Windows MSI), so the
# industry-standard solution is to ship a discoverable .command file
# alongside the installed app — the user can find it later in Finder and
# double-click to launch the cleanup. PR #53 adds this.
cp "${SCRIPT_DIR}/uninstall-command-template.sh" \
    "${PAYLOAD}/Applications/Uninstall Knit.command"
chmod 0755 "${PAYLOAD}/Applications/Uninstall Knit.command"

# Ensure the postinstall script is executable when pkgbuild reads it.
chmod 0755 "${PKG_SCRIPTS}/postinstall"

# ---------------------------------------------------------------------------
# 3. Sign the payload binaries (only if APP_ID is set)
# ---------------------------------------------------------------------------
if [[ -n "${APP_ID}" ]]; then
    echo ">> Signing CLI + Knit.app with: ${APP_ID}"
    codesign --force --options runtime --timestamp \
        --sign "${APP_ID}" \
        "${PAYLOAD}/usr/local/bin/knit"
    codesign --force --options runtime --timestamp --deep \
        --sign "${APP_ID}" \
        "${PAYLOAD}/Applications/Knit.app"
    codesign --verify --strict --verbose=2 "${PAYLOAD}/Applications/Knit.app"
else
    echo ">> APP_ID not set — skipping codesign (PKG will install but Gatekeeper will prompt)"
fi

# ---------------------------------------------------------------------------
# 4. Build the component pkg (the actual payload + postinstall)
# ---------------------------------------------------------------------------
echo ">> pkgbuild — component package"
# --component-plist passes a hand-written manifest that sets
# BundleIsRelocatable=NO on Knit.app (PR #63 fix). Without it,
# pkgbuild's auto-detected component metadata defaults to
# `BundleIsRelocatable=YES`, and macOS Installer then "relocates"
# the install onto any pre-existing co.boldright.knit Knit.app it
# finds on disk (e.g. a developer's other source-tree checkout under
# ~/ClaudeCode/BoZip/dist/Knit.app, registered with Spotlight). The
# receipt records as installed but /Applications/Knit.app is never
# materialised — only the relocation-immune Uninstall Knit.command
# (no bundle identifier) survives.
pkgbuild \
    --root "${PAYLOAD}" \
    --component-plist "${PKG_RESOURCES}/Knit.component-plist" \
    --identifier "co.boldright.knit" \
    --version "0.1.0" \
    --install-location "/" \
    --scripts "${PKG_SCRIPTS}" \
    --ownership recommended \
    "${COMPONENT_PKG}"

# ---------------------------------------------------------------------------
# 5. Wrap into the user-facing distribution installer (welcome / conclusion)
# ---------------------------------------------------------------------------
echo ">> productbuild — distribution installer"
productbuild \
    --distribution "${PKG_RESOURCES}/Distribution.xml" \
    --package-path "${STAGING}" \
    --resources "${PKG_RESOURCES}" \
    "${DIST_PKG_UNSIGNED}"

# ---------------------------------------------------------------------------
# 6. Sign the installer (Developer ID Installer cert)
# ---------------------------------------------------------------------------
if [[ -n "${INSTALLER_ID}" ]]; then
    echo ">> productsign — installer"
    productsign --sign "${INSTALLER_ID}" \
        "${DIST_PKG_UNSIGNED}" \
        "${PKG_OUT}"
else
    echo ">> INSTALLER_ID not set — emitting unsigned PKG"
    cp "${DIST_PKG_UNSIGNED}" "${PKG_OUT}"
fi

# ---------------------------------------------------------------------------
# 7. Notarize via notarytool (requires INSTALLER_ID + NOTARY_PROFILE)
# ---------------------------------------------------------------------------
if [[ -n "${INSTALLER_ID}" && -n "${NOTARY_PROFILE}" ]]; then
    echo ">> notarytool — submitting (this may take a few minutes)"
    xcrun notarytool submit "${PKG_OUT}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait
    echo ">> stapler — attaching notarization ticket"
    xcrun stapler staple "${PKG_OUT}"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
rm -rf "${STAGING}"

echo
echo "============================================="
echo "Built: ${PKG_OUT}"
ls -lh "${PKG_OUT}"
echo
echo "Distribute this single .pkg file. Recipients:"
echo "  1. double-click Knit-Installer.pkg"
echo "  2. follow the standard macOS installer GUI"
echo "  3. enter their admin password when prompted"
echo "============================================="
