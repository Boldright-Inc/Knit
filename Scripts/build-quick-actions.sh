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

cat > "${TMP}/zip.sh" <<'BS'
for f in "$@"; do
  /usr/local/bin/knit zip "$f" --parallel --level 6 -o "${f}.zip" 2>>/tmp/knit-quickaction.log
done
osascript -e "display notification \"Compressed $# item(s) to .zip\" with title \"Knit\"" >/dev/null
BS

cat > "${TMP}/bzx.sh" <<'BS'
for f in "$@"; do
  /usr/local/bin/knit pack "$f" --level 3 -o "${f}.knit" 2>>/tmp/knit-quickaction.log
done
osascript -e "display notification \"Compressed $# item(s) to .knit\" with title \"Knit\"" >/dev/null
BS

cat > "${TMP}/extract.sh" <<'BS'
for f in "$@"; do
  dir="$(dirname "$f")"
  case "$f" in
    *.knit) /usr/local/bin/knit unpack "$f" -o "$dir" 2>>/tmp/knit-quickaction.log ;;
    *.zip) /usr/bin/unzip -q -o "$f" -d "$dir" 2>>/tmp/knit-quickaction.log ;;
  esac
done
osascript -e "display notification \"Extracted $# item(s)\" with title \"Knit\"" >/dev/null
BS

emit_workflow "Knit Compress (ZIP)"  "${TMP}/zip.sh"
emit_workflow "Knit Compress (.knit)" "${TMP}/bzx.sh"
emit_workflow "Knit Extract"         "${TMP}/extract.sh"

echo
echo "Quick Actions written to: ${DIST}"
ls -la "${DIST}"
