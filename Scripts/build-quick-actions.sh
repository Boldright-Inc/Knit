#!/usr/bin/env bash
# Generate Quick Action (.workflow) bundles for compression/decompression
# under dist/QuickActions/. The workflows shell out to /usr/local/bin/knit
# which Scripts/install.sh places on PATH.
#
# PR #57: workflows now delegate to Knit.app via `open -a` instead of
# opening a Terminal window directly. Knit.app drives the knit CLI as
# a subprocess and surfaces progress through a native `NSProgress`
# (which Finder decorates the output file's icon with, plus shows in
# the system menu-bar progress widget). Net effect: no Terminal
# pop-up, no "terminate processes?" dialog, file-icon overlay during
# the operation, modern macOS UX.
#
# The 30 MiB size threshold from PR #55 is no longer needed —
# NSProgress is light enough to publish for any size, including a
# 5 MB zip. A trivial operation just produces a brief progress flash;
# nothing as intrusive as a Terminal window. The CLI itself is
# unchanged and can still be invoked directly from a terminal with
# `--progress` for the text-bar UX.
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

# Each Quick Action delegates to Knit.app via `open -a` with the
# operation flag + input paths. Knit.app is responsible for the
# progress UI (native NSProgress + Finder file-icon overlay) and for
# running the knit CLI subprocess. The Quick Action script itself
# stays trivial: assemble args, fork open, exit.
#
# `open -a /Applications/Knit.app --args …` will:
#   * launch Knit.app if not already running
#   * pass `--args …` through to the new process's ARGV
#   * return immediately, so the Finder spinner doesn't linger
#
# We pass:
#   --operation pack | zip | extract
#   --inputs <path>...     (selected files; consumed until next --flag)
#   --level <N>            (compression level; pack→3, zip→6 default)
# Knit.app parses these in `parseQuickActionArgs()` (Sources/KnitApp/main.swift).

cat > "${TMP}/zip.sh" <<'BS'
#!/bin/zsh
# Knit Compress (ZIP) — delegates to Knit.app which drives the native
# NSProgress + Finder file-icon overlay. CLI invocations from a
# terminal still work via /usr/local/bin/knit zip … --progress.
exec /usr/bin/open -a /Applications/Knit.app --args \
    --operation zip --level 6 --inputs "$@"
BS

cat > "${TMP}/bzx.sh" <<'BS'
#!/bin/zsh
# Knit Compress (.knit) — see Knit Compress (ZIP) for the
# Knit.app-delegated UX rationale.
exec /usr/bin/open -a /Applications/Knit.app --args \
    --operation pack --level 3 --inputs "$@"
BS

cat > "${TMP}/extract.sh" <<'BS'
#!/bin/zsh
# Knit Extract — accepts both .knit and .zip; Knit.app routes based
# on the file extension (`.zip` falls back to /usr/bin/unzip there).
exec /usr/bin/open -a /Applications/Knit.app --args \
    --operation extract --inputs "$@"
BS

emit_workflow "Knit Compress (ZIP)"  "${TMP}/zip.sh"
emit_workflow "Knit Compress (.knit)" "${TMP}/bzx.sh"
emit_workflow "Knit Extract"         "${TMP}/extract.sh"

echo
echo "Quick Actions written to: ${DIST}"
ls -la "${DIST}"
