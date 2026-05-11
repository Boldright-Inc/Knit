#!/usr/bin/env bash
# Install Knit:
#   - Copy Knit.app to /Applications (registers .knit UTI + document icon)
#   - Copy `knit` binary to /usr/local/bin (sudo'd)
#   - Copy Quick Action workflows to ~/Library/Services
#
# Works in two layouts:
#   1) Repo layout    — run from .../<repo>/Scripts/install.sh
#   2) DMG layout     — run from the mounted DMG (Knit.app, bin/, QuickActions/)
#
# Re-run is idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DST="/usr/local/bin/knit"
APP_DST="/Applications/Knit.app"
QA_DST="${HOME}/Library/Services"

# --- Locate sources, detecting layout --------------------------------------
BIN_SRC=""
QA_SRC=""
APP_SRC=""
BUNDLE_SRC=""

# DMG layout: SCRIPT_DIR contains Knit.app, bin/, and QuickActions/
if [[ -x "${SCRIPT_DIR}/bin/knit" ]]; then
    BIN_SRC="${SCRIPT_DIR}/bin/knit"
    QA_SRC="${SCRIPT_DIR}/QuickActions"
    APP_SRC="${SCRIPT_DIR}/Knit.app"
    BUNDLE_SRC="${SCRIPT_DIR}/bin/Knit_KnitCore.bundle"
fi

# Repo layout
if [[ -z "${BIN_SRC}" ]]; then
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
    if [[ -x "${REPO_ROOT}/.build/release/knit" ]]; then
        BIN_SRC="${REPO_ROOT}/.build/release/knit"
        QA_SRC="${REPO_ROOT}/dist/QuickActions"
        APP_SRC="${REPO_ROOT}/dist/Knit.app"
        BUNDLE_SRC="${REPO_ROOT}/.build/release/Knit_KnitCore.bundle"
    elif [[ -f "${REPO_ROOT}/Package.swift" ]]; then
        echo ">> Building knit release..."
        ( cd "${REPO_ROOT}" && swift build -c release )
        BIN_SRC="${REPO_ROOT}/.build/release/knit"
        QA_SRC="${REPO_ROOT}/dist/QuickActions"
        APP_SRC="${REPO_ROOT}/dist/Knit.app"
        BUNDLE_SRC="${REPO_ROOT}/.build/release/Knit_KnitCore.bundle"
    fi

    if [[ -n "${QA_SRC}" && ! -d "${QA_SRC}/Knit Compress (ZIP).workflow" ]]; then
        echo ">> Building Quick Actions..."
        "${SCRIPT_DIR}/build-quick-actions.sh" >/dev/null
    fi
    if [[ -n "${APP_SRC}" && ! -d "${APP_SRC}" ]]; then
        echo ">> Building Knit.app..."
        "${SCRIPT_DIR}/build-app.sh" >/dev/null
    fi
fi

if [[ -z "${BIN_SRC}" || ! -x "${BIN_SRC}" ]]; then
    echo "error: could not locate knit binary." >&2
    exit 1
fi
if [[ -z "${QA_SRC}" || ! -d "${QA_SRC}" ]]; then
    echo "error: could not locate QuickActions/ directory." >&2
    exit 1
fi
if [[ -z "${APP_SRC}" || ! -d "${APP_SRC}" ]]; then
    echo "warning: Knit.app not found — .knit files will keep the generic icon." >&2
fi

# --- Install ----------------------------------------------------------------
echo ">> Installing CLI to ${BIN_DST} (sudo)"
sudo install -m 0755 -o root -g wheel "${BIN_SRC}" "${BIN_DST}"

# PR #63 fix. SwiftPM emits a `Knit_KnitCore.bundle` next to the
# binary containing the Metal kernel sources (`crc32_block.metal`,
# `entropy_probe.metal`). MetalContext.loadRuntimeLibrary reads
# them via Bundle.module, whose accessor looks first at
# `Bundle.main.bundleURL/Knit_KnitCore.bundle` — for an executable
# at /usr/local/bin/knit that resolves to
# /usr/local/bin/Knit_KnitCore.bundle. If absent, the accessor
# falls back to a build-time path baked into the binary
# (/Users/<builder>/...) which only exists on the build machine.
# Recipients then SIGTRAP at first Metal touch. Ship the bundle
# alongside the binary so resolution succeeds on every machine.
BUNDLE_DST="/usr/local/bin/Knit_KnitCore.bundle"
if [[ -n "${BUNDLE_SRC}" && -d "${BUNDLE_SRC}" ]]; then
    echo ">> Installing Metal resource bundle to ${BUNDLE_DST} (sudo)"
    sudo rm -rf "${BUNDLE_DST}"
    sudo cp -R "${BUNDLE_SRC}" "${BUNDLE_DST}"
    sudo chown -R root:wheel "${BUNDLE_DST}"
else
    echo "error: Knit_KnitCore.bundle not found (expected at ${BUNDLE_SRC:-<unset>})." >&2
    echo "       Did 'swift build -c release' run? CLI will SIGTRAP on Metal init." >&2
    exit 1
fi

LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [[ -d "${APP_SRC}" ]]; then
    echo ">> Installing Knit.app to ${APP_DST} (sudo)"
    sudo rm -rf "${APP_DST}"
    sudo cp -R "${APP_SRC}" "${APP_DST}"

    # Verify the copy actually landed.
    if [[ ! -d "${APP_DST}/Contents/MacOS" ]]; then
        echo "error: Knit.app did not install correctly to ${APP_DST}" >&2
        exit 1
    fi

    # Hard-reset Launch Services so any stale entry from a previous build is
    # discarded, then re-register Knit.app. Without this step, macOS often
    # sticks with a cached/inactive UTI registration and .knit files keep the
    # generic "?" icon.
    echo ">> Resetting Launch Services + re-registering Knit.app"
    "${LSREG}" -kill -r -domain local -domain user >/dev/null 2>&1 || true
    "${LSREG}" -f "${APP_DST}" >/dev/null 2>&1 || true
fi

# Install the double-clickable uninstaller alongside Knit.app. macOS's
# .pkg system has no native uninstall mechanism, so the standard Mac
# pattern (Adobe / Microsoft / others) is a discoverable
# "Uninstall <App>.command" file in /Applications that runs the
# removal script when the user double-clicks it. PR #53 adds this.
UNINSTALL_CMD_SRC="${SCRIPT_DIR}/uninstall-command-template.sh"
UNINSTALL_CMD_DST="/Applications/Uninstall Knit.command"
# DMG layout ships the template at the root of the mounted volume
# alongside Knit.app / bin / QuickActions — adjust the lookup so
# either layout works.
if [[ ! -f "${UNINSTALL_CMD_SRC}" && -f "${SCRIPT_DIR}/uninstall-command-template.sh" ]]; then
    UNINSTALL_CMD_SRC="${SCRIPT_DIR}/uninstall-command-template.sh"
fi
if [[ -f "${UNINSTALL_CMD_SRC}" ]]; then
    echo ">> Installing uninstaller to ${UNINSTALL_CMD_DST} (sudo)"
    sudo install -m 0755 -o root -g wheel \
        "${UNINSTALL_CMD_SRC}" "${UNINSTALL_CMD_DST}"
else
    echo "warning: uninstaller template not found at ${UNINSTALL_CMD_SRC} — skipping" >&2
fi

echo ">> Installing Quick Actions to ${QA_DST}"
mkdir -p "${QA_DST}"

# Cleanup pass: remove every previously-installed Knit Quick Action
# *before* dropping the new bundles in. Without this, renaming a workflow
# (or installing across versions whose filenames drifted by a space, a
# dot, or unicode) leaves the old bundles behind and the Services menu
# duplicates every entry.
#
# We deliberately also touch /Library/Services (system-wide) in case an
# earlier install ran with sudo — those copies are otherwise invisible
# to the user-scope rm below and silently take precedence.
echo "   cleaning previous Knit workflows from ${QA_DST}"
find "${QA_DST}" -maxdepth 1 -type d -name "Knit *.workflow" \
    -exec rm -rf {} + 2>/dev/null || true

if [[ -d "/Library/Services" ]] && \
   ls /Library/Services/Knit\ *.workflow >/dev/null 2>&1; then
    echo "   cleaning previous Knit workflows from /Library/Services (sudo)"
    sudo find /Library/Services -maxdepth 1 -type d -name "Knit *.workflow" \
        -exec rm -rf {} + 2>/dev/null || true
fi

for wf in "${QA_SRC}"/*.workflow; do
    [[ -d "${wf}" ]] || continue
    name="$(basename "${wf}")"
    cp -R "${wf}" "${QA_DST}/${name}"
    echo "   installed: ${name}"
done

# Force the Services menu to forget any cached registrations from the
# now-removed workflows. Without `pbs -flush` the duplicates can linger
# in the menu until the next login even though the files are gone.
/System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true

# Force Services menu, icon cache, and Finder to pick up the new registrations.
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
sudo rm -rf /Library/Caches/com.apple.iconservices.store 2>/dev/null || true
killall iconservicesagent iconservicesd 2>/dev/null || true
killall Finder Dock 2>/dev/null || true

echo
echo "Done."
echo
echo ".knit files in Finder will now show the Knit document icon."
echo
echo "Right-click any file in Finder -> Quick Actions:"
echo "  - Knit Compress (ZIP)   .zip output"
echo "  - Knit Compress (.knit) high-speed format"
echo "  - Knit Extract          .zip / .knit aware extraction"
echo
echo "If the menu doesn't appear, open System Settings -> Keyboard ->"
echo "Keyboard Shortcuts -> Services -> Files and Folders, and tick the Knit items."
