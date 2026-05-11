#!/bin/bash
# Uninstall Knit.command — user-facing uninstaller, double-clickable from
# Finder.
#
# This is the *template* that install.sh and Scripts/build-pkg.sh copy
# (renamed to "Uninstall Knit.command") into /Applications/ during
# install. The .command extension makes Finder open it in Terminal when
# the user double-clicks; the script then walks through the removal
# steps, asking for the admin password the same way `./uninstall.sh`
# does from a checkout.
#
# Why this file exists at all: macOS's .pkg installer system has no
# native uninstall mechanism (unlike Windows MSI). The standard
# industry pattern is to bundle a discoverable uninstaller alongside
# the installed app — what Adobe, Microsoft, and many smaller vendors
# do. Putting "Uninstall Knit.command" in /Applications/ next to the
# app makes it findable without any system-settings spelunking.
#
# Differences from Scripts/uninstall.sh (the dev-facing repo script):
#   * Friendly banner + summary of what will be removed.
#   * Asks the user to press Enter before doing anything destructive,
#     so an accidental double-click is recoverable.
#   * Holds the Terminal window open at the end so the user can read
#     the output before the window closes.
#   * Self-deletes on success — once Knit is gone there's no reason to
#     keep the uninstaller around.

set -u  # not -e: keep going on individual rm failures (idempotent)

cat <<'BANNER'
+---------------------------------------------------------+
|                    Knit Uninstaller                     |
+---------------------------------------------------------+

This will remove Knit from your Mac:

  * /Applications/Knit.app
  * /usr/local/bin/knit (CLI)
  * Knit Compress / Knit Extract Quick Actions
    (under "Services" in Finder's right-click menu)
  * Installer receipt (co.boldright.knit)
  * This uninstaller itself

You may be prompted for your administrator password during the
process — some of these files live in system locations that require
sudo to remove.

BANNER

printf "Press [Enter] to continue, or close this window to cancel: "
read -r _confirm
echo

QA_DST_USER="${HOME}/Library/Services"
QA_DST_SYS="/Library/Services"
BIN_DST="/usr/local/bin/knit"
APP_DST="/Applications/Knit.app"
SELF_PATH="$0"
PKG_ID="co.boldright.knit"

WORKFLOW_NAMES=(
    "Knit Compress (ZIP).workflow"
    "Knit Compress (.knit).workflow"
    "Knit Extract.workflow"
)

removed_anything=0

echo ">> Removing user-scope Quick Actions (${QA_DST_USER})"
for name in "${WORKFLOW_NAMES[@]}"; do
    if [[ -d "${QA_DST_USER}/${name}" ]]; then
        rm -rf "${QA_DST_USER}/${name}"
        echo "   removed: ${name}"
        removed_anything=1
    fi
done

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

if /usr/sbin/pkgutil --pkg-info "${PKG_ID}" >/dev/null 2>&1; then
    echo ">> Forgetting installer receipt (${PKG_ID}, sudo)"
    sudo /usr/sbin/pkgutil --forget "${PKG_ID}" >/dev/null 2>&1 || true
    removed_anything=1
fi

echo ">> Refreshing Services menu cache"
/System/Library/CoreServices/pbs -flush  >/dev/null 2>&1 || true
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
killall Finder Dock 2>/dev/null || true

echo
if (( removed_anything )); then
    cat <<'DONE'
+---------------------------------------------------------+
|       Knit has been removed from your Mac.              |
+---------------------------------------------------------+
DONE
else
    echo "Nothing to remove — Knit doesn't appear to be installed on this Mac."
fi
echo

printf "Press [Enter] to close this window."
read -r _close

# Self-delete: the uninstaller itself becomes garbage once Knit is gone.
# Terminal still has the file open as the running script, but on Unix
# the inode survives until last fd closes — `rm` on the open file is
# safe and the file is gone from /Applications the moment we exit.
rm -f -- "${SELF_PATH}" 2>/dev/null || true
exit 0
