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

# DMG layout: SCRIPT_DIR contains Knit.app, bin/, and QuickActions/
if [[ -x "${SCRIPT_DIR}/bin/knit" ]]; then
    BIN_SRC="${SCRIPT_DIR}/bin/knit"
    QA_SRC="${SCRIPT_DIR}/QuickActions"
    APP_SRC="${SCRIPT_DIR}/Knit.app"
fi

# Repo layout
if [[ -z "${BIN_SRC}" ]]; then
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
    if [[ -x "${REPO_ROOT}/.build/release/knit" ]]; then
        BIN_SRC="${REPO_ROOT}/.build/release/knit"
        QA_SRC="${REPO_ROOT}/dist/QuickActions"
        APP_SRC="${REPO_ROOT}/dist/Knit.app"
    elif [[ -f "${REPO_ROOT}/Package.swift" ]]; then
        echo ">> Building knit release..."
        ( cd "${REPO_ROOT}" && swift build -c release )
        BIN_SRC="${REPO_ROOT}/.build/release/knit"
        QA_SRC="${REPO_ROOT}/dist/QuickActions"
        APP_SRC="${REPO_ROOT}/dist/Knit.app"
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

echo ">> Installing Quick Actions to ${QA_DST}"
mkdir -p "${QA_DST}"
for wf in "${QA_SRC}"/*.workflow; do
    [[ -d "${wf}" ]] || continue
    name="$(basename "${wf}")"
    rm -rf "${QA_DST}/${name}"
    cp -R "${wf}" "${QA_DST}/${name}"
    echo "   installed: ${name}"
done

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
