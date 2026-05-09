#!/usr/bin/env bash
# Remove Knit from this Mac.
set -euo pipefail

QA_DST="${HOME}/Library/Services"
BIN_DST="/usr/local/bin/knit"
APP_DST="/Applications/Knit.app"

echo ">> Removing Quick Actions"
for name in "Knit Compress (ZIP).workflow" "Knit Compress (.knit).workflow" "Knit Extract.workflow"; do
    if [[ -d "${QA_DST}/${name}" ]]; then
        rm -rf "${QA_DST}/${name}"
        echo "   removed: ${name}"
    fi
done

echo ">> Removing CLI (sudo)"
if [[ -x "${BIN_DST}" ]]; then
    sudo rm -f "${BIN_DST}"
fi

echo ">> Removing Knit.app (sudo)"
if [[ -d "${APP_DST}" ]]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u "${APP_DST}" 2>/dev/null || true
    sudo rm -rf "${APP_DST}"
fi

/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
killall Finder 2>/dev/null || true
echo "Done."
