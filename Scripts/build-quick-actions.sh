#!/usr/bin/env bash
# Generate Quick Action (.workflow) bundles for compression/decompression
# under dist/QuickActions/. The workflows shell out to /usr/local/bin/knit
# which Scripts/install.sh places on PATH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST="${ROOT_DIR}/dist/QuickActions"
mkdir -p "${DIST}"

emit_workflow() {
    local name="$1" script_file="$2"
    local bundle="${DIST}/${name}.workflow"
    rm -rf "${bundle}"
    mkdir -p "${bundle}/Contents"

    cat > "${bundle}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key>
      <dict><key>default</key><string>${name}</string></dict>
      <key>NSMessage</key><string>runWorkflowAsService</string>
      <key>NSRequiredContext</key>
      <dict><key>NSApplicationIdentifier</key><string>com.apple.finder</string></dict>
      <key>NSSendFileTypes</key>
      <array><string>public.item</string></array>
      <key>NSSendTypes</key>
      <array><string>NSFilenamesPboardType</string></array>
    </dict>
  </array>
</dict>
</plist>
EOF

    # Build document.wflow via Python — safer than sed for multi-line strings.
    /usr/bin/env python3 - "${bundle}/Contents/document.wflow" "${script_file}" <<'PYEOF'
import os, plistlib, sys
out_path  = sys.argv[1]
script    = open(sys.argv[2]).read()
wflow = {
    "AMApplicationVersion": "2.10",
    "AMDocumentVersion": "2",
    "actions": [{
        "action": {
            "AMAccepts": {
                "Container": "List", "Optional": True,
                "Types": ["com.apple.cocoa.path"],
            },
            "AMActionVersion": "2.0.3",
            "AMApplication": ["Automator"],
            "AMParameterProperties": {
                "COMMAND_STRING": {}, "CheckedForUserDefaultShell": {},
                "inputMethod": {}, "shell": {}, "source": {},
            },
            "AMProvides": {
                "Container": "List", "Types": ["com.apple.cocoa.string"],
            },
            "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action",
            "ActionName": "Run Shell Script",
            "ActionParameters": {
                "COMMAND_STRING": script,
                "CheckedForUserDefaultShell": 1,
                "inputMethod": 1,           # pass selection as $@
                "shell": "/bin/zsh",
                "source": "",
            },
            "BundleIdentifier": "com.apple.RunShellScript",
            "CFBundleVersion": "2.0.3",
            "CanShowSelectedItemsWhenRun": False,
            "CanShowWhenRun": True,
            "Category": ["AMCategoryUtilities"],
            "Class Name": "RunShellScriptAction",
            "InputUUID": "00000000-0000-0000-0000-000000000001",
            "Keywords": ["Shell"],
            "OutputUUID": "00000000-0000-0000-0000-000000000002",
            "UUID": "00000000-0000-0000-0000-000000000003",
            "UnlocalizedApplications": ["Automator"],
            "arguments": {
                "0": {"default value": 0, "name": "inputMethod",
                      "required": "0", "type": "0", "uuid": "0"},
                "1": {"default value": "", "name": "CheckedForUserDefaultShell",
                      "required": "0", "type": "0", "uuid": "1"},
                "2": {"default value": "", "name": "source",
                      "required": "0", "type": "0", "uuid": "2"},
                "3": {"default value": "", "name": "COMMAND_STRING",
                      "required": "0", "type": "0", "uuid": "3"},
                "4": {"default value": "/bin/sh", "name": "shell",
                      "required": "0", "type": "0", "uuid": "4"},
            },
            "isViewVisible": 1,
            "location": "309.000000:316.000000",
            "nibPath": "/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib",
        },
        "isViewVisible": 1,
    }],
    "connectors": {},
    "workflowMetaData": {
        "serviceApplicationBundleID": "com.apple.finder",
        "serviceApplicationPath": "/System/Library/CoreServices/Finder.app",
        "serviceInputTypeIdentifier": "com.apple.Automator.fileSystemObject",
        "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
        "serviceProcessesInput": 0,
        "useAutomaticInputType": 0,
        "workflowTypeIdentifier": "com.apple.Automator.servicesMenu",
    },
}
with open(out_path, "wb") as f:
    plistlib.dump(wflow, f, fmt=plistlib.FMT_BINARY)
PYEOF

    echo "  built: ${bundle}"
}

# Use mktemp and feed shell snippets through files.
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Each Quick Action spawns a temporary Terminal window so the user can
# see Knit's `--progress` bar for long-running operations. The window
# auto-exits the shell on completion; whether macOS auto-closes the
# window after that depends on Terminal > Settings > Profiles > Shell
# ("Close the window — When the shell exits cleanly" or "Always").
# Either way, the operation runs to completion regardless of the user's
# Terminal preference.

cat > "${TMP}/zip.sh" <<'BS'
RUNNER="$(mktemp -t knit_zip_runner)"
{
  echo '#!/bin/zsh'
  echo 'set -u'
  for f in "$@"; do
    printf '/usr/local/bin/knit zip %q --parallel --level 6 --progress -o %q\n' "$f" "${f}.zip"
  done
  echo 'printf "\\n[Done. Press ⌘W to close.]\\n"'
  echo "rm -f -- '${RUNNER}'"
  echo 'exit 0'
} > "${RUNNER}"
chmod +x "${RUNNER}"
osascript -e "tell application \"Terminal\" to activate" \
          -e "tell application \"Terminal\" to do script \"${RUNNER}\"" >/dev/null
BS

cat > "${TMP}/bzx.sh" <<'BS'
RUNNER="$(mktemp -t knit_pack_runner)"
{
  echo '#!/bin/zsh'
  echo 'set -u'
  for f in "$@"; do
    printf '/usr/local/bin/knit pack %q --level 3 --progress -o %q\n' "$f" "${f}.knit"
  done
  echo 'printf "\\n[Done. Press ⌘W to close.]\\n"'
  echo "rm -f -- '${RUNNER}'"
  echo 'exit 0'
} > "${RUNNER}"
chmod +x "${RUNNER}"
osascript -e "tell application \"Terminal\" to activate" \
          -e "tell application \"Terminal\" to do script \"${RUNNER}\"" >/dev/null
BS

cat > "${TMP}/extract.sh" <<'BS'
RUNNER="$(mktemp -t knit_extract_runner)"
{
  echo '#!/bin/zsh'
  echo 'set -u'
  for f in "$@"; do
    dir="$(dirname "$f")"
    case "$f" in
      *.knit) printf '/usr/local/bin/knit unpack %q --progress -o %q\n' "$f" "$dir" ;;
      *.zip)  printf '/usr/bin/unzip -o %q -d %q\n' "$f" "$dir" ;;
    esac
  done
  echo 'printf "\\n[Done. Press ⌘W to close.]\\n"'
  echo "rm -f -- '${RUNNER}'"
  echo 'exit 0'
} > "${RUNNER}"
chmod +x "${RUNNER}"
osascript -e "tell application \"Terminal\" to activate" \
          -e "tell application \"Terminal\" to do script \"${RUNNER}\"" >/dev/null
BS

emit_workflow "Knit Compress (ZIP)"  "${TMP}/zip.sh"
emit_workflow "Knit Compress (.knit)" "${TMP}/bzx.sh"
emit_workflow "Knit Extract"         "${TMP}/extract.sh"

echo
echo "Quick Actions written to: ${DIST}"
ls -la "${DIST}"
