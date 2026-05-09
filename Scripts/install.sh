#!/usr/bin/env bash
# Install Knit:
#   - Copy `knit` binary to /usr/local/bin (sudo'd)
#   - Copy Quick Action workflows to ~/Library/Services
#
# Works in two layouts:
#   1) Repo layout    — run from .../Knit/Scripts/install.sh
#   2) DMG layout     — run from the mounted DMG (bin/, QuickActions/, install.sh)
#
# Re-run is idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DST="/usr/local/bin/knit"
QA_DST="${HOME}/Library/Services"

# --- Locate sources, detecting layout --------------------------------------
BIN_SRC=""
QA_SRC=""

# DMG layout: SCRIPT_DIR contains bin/ and QuickActions/
if [[ -x "${SCRIPT_DIR}/bin/knit" ]]; then
    BIN_SRC="${SCRIPT_DIR}/bin/knit"
    QA_SRC="${SCRIPT_DIR}/QuickActions"
fi

# Repo layout: SCRIPT_DIR is .../Scripts/, parent has .build/release/knit
if [[ -z "${BIN_SRC}" ]]; then
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
    if [[ -x "${REPO_ROOT}/.build/release/knit" ]]; then
        BIN_SRC="${REPO_ROOT}/.build/release/knit"
        QA_SRC="${REPO_ROOT}/dist/QuickActions"
    elif [[ -f "${REPO_ROOT}/Package.swift" ]]; then
        echo ">> Building knit release..."
        ( cd "${REPO_ROOT}" && swift build -c release )
        BIN_SRC="${REPO_ROOT}/.build/release/knit"
        QA_SRC="${REPO_ROOT}/dist/QuickActions"
        if [[ ! -d "${QA_SRC}/Knit Compress (ZIP).workflow" ]]; then
            echo ">> Building Quick Actions..."
            "${SCRIPT_DIR}/build-quick-actions.sh" >/dev/null
        fi
    fi
fi

if [[ -z "${BIN_SRC}" || ! -x "${BIN_SRC}" ]]; then
    echo "error: could not locate knit binary." >&2
    echo "  Expected at:" >&2
    echo "    ${SCRIPT_DIR}/bin/knit            (DMG layout)" >&2
    echo "    .../Knit/.build/release/knit    (repo layout)" >&2
    exit 1
fi

if [[ -z "${QA_SRC}" || ! -d "${QA_SRC}" ]]; then
    echo "error: could not locate QuickActions/ directory." >&2
    exit 1
fi

# --- Install ----------------------------------------------------------------
echo ">> Installing CLI to ${BIN_DST} (sudo)"
sudo install -m 0755 -o root -g wheel "${BIN_SRC}" "${BIN_DST}"

echo ">> Installing Quick Actions to ${QA_DST}"
mkdir -p "${QA_DST}"
for wf in "${QA_SRC}"/*.workflow; do
    [[ -d "${wf}" ]] || continue
    name="$(basename "${wf}")"
    rm -rf "${QA_DST}/${name}"
    cp -R "${wf}" "${QA_DST}/${name}"
    echo "   installed: ${name}"
done

# Refresh the Services menu cache.
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true

echo
echo "Done."
echo
echo "Right-click any file in Finder -> Quick Actions (or Services) submenu:"
echo "  - Knit Compress (ZIP)   .zip output, standard format"
echo "  - Knit Compress (.knit)  high-speed internal format"
echo "  - Knit Extract          .zip / .knit aware extraction"
echo
echo "If the menu doesn't appear, open System Settings -> Keyboard ->"
echo "Keyboard Shortcuts -> Services -> Files and Folders, and tick the Knit items."
