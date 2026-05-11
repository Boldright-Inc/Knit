#!/usr/bin/env bash
# Remove Knit from this Mac.
#
# Covers both install paths:
#   1) Scripts/install.sh — writes the Quick Actions to ~/Library/Services
#      and the CLI/Knit.app under sudo to /usr/local/bin and /Applications.
#   2) Knit-Installer.pkg (from build-pkg.sh) — writes the Quick Actions
#      to /Library/Services (system-wide, sudo) instead of ~/Library/Services,
#      plus the same /usr/local/bin and /Applications paths.
#
# An earlier version of this script only swept ~/Library/Services and left
# .pkg-installed Quick Actions on disk, so the Knit menu items kept appearing
# in Finder's Services menu even after a Done message (PR #52 fix).
set -euo pipefail

QA_DST_USER="${HOME}/Library/Services"
QA_DST_SYS="/Library/Services"
BIN_DST="/usr/local/bin/knit"
APP_DST="/Applications/Knit.app"
PKG_ID="co.boldright.knit"

WORKFLOW_NAMES=(
    "Knit Compress (ZIP).workflow"
    "Knit Compress (.knit).workflow"
    "Knit Extract.workflow"
)

# Track whether anything was actually removed so the final summary can
# tell the user "nothing was installed" instead of a misleading "Done."
removed_anything=0

echo ">> Removing user-scope Quick Actions (${QA_DST_USER})"
for name in "${WORKFLOW_NAMES[@]}"; do
    if [[ -d "${QA_DST_USER}/${name}" ]]; then
        rm -rf "${QA_DST_USER}/${name}"
        echo "   removed: ${name}"
        removed_anything=1
    fi
done

# /Library/Services is where Knit-Installer.pkg puts the workflows. The
# install.sh helper drops them in the user-scope dir, but the .pkg's
# postinstall writes here under root. Either install vector can have
# stale bundles, so always sweep both.
need_sudo=0
for name in "${WORKFLOW_NAMES[@]}"; do
    if [[ -d "${QA_DST_SYS}/${name}" ]]; then
        need_sudo=1
        break
    fi
done

if (( need_sudo )); then
    echo ">> Removing system-scope Quick Actions (${QA_DST_SYS}, sudo)"
    for name in "${WORKFLOW_NAMES[@]}"; do
        if [[ -d "${QA_DST_SYS}/${name}" ]]; then
            sudo rm -rf "${QA_DST_SYS}/${name}"
            echo "   removed: ${name}"
            removed_anything=1
        fi
    done
fi

if [[ -x "${BIN_DST}" ]]; then
    echo ">> Removing CLI (${BIN_DST}, sudo)"
    sudo rm -f "${BIN_DST}"
    removed_anything=1
fi

if [[ -d "${APP_DST}" ]]; then
    echo ">> Removing Knit.app (${APP_DST}, sudo)"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u "${APP_DST}" 2>/dev/null || true
    sudo rm -rf "${APP_DST}"
    removed_anything=1
fi

# Forget the installer receipt so a future `pkgutil --pkgs` doesn't
# show the package as still installed. Without this the pkg system
# thinks Knit is present even though its payload is gone, which
# blocks a clean reinstall via the .pkg.
if /usr/sbin/pkgutil --pkg-info "${PKG_ID}" >/dev/null 2>&1; then
    echo ">> Forgetting installer receipt (${PKG_ID}, sudo)"
    sudo /usr/sbin/pkgutil --forget "${PKG_ID}" >/dev/null 2>&1 || true
    removed_anything=1
fi

# Flush the Services menu cache. `pbs -flush` invalidates the on-disk
# registration cache; `pbs -update` then re-scans so the Knit entries
# are removed from the menu without requiring logout. `killall Finder
# Dock` picks up the change for the running session — the Dock caches
# Services too, not just the Finder menu.
echo ">> Refreshing Services menu cache"
/System/Library/CoreServices/pbs -flush  >/dev/null 2>&1 || true
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
killall Finder Dock 2>/dev/null || true

if (( removed_anything )); then
    echo "Done."
else
    echo "Nothing to remove — Knit doesn't appear to be installed on this Mac."
fi
