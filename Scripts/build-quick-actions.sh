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
        # Quick Action vs. Service: both ship as .workflow bundles under
        # /Library/Services, but the type identifier decides where Finder
        # surfaces them in the right-click menu.
        #
        #   * servicesMenu   → "Services >" submenu (2nd-level, dim, easy to miss)
        #   * quickActionMenu → "Quick Actions >" submenu (still 2nd-level, but
        #                       sibling of Services rather than nested under it,
        #                       AND Quick Actions also appear in Finder's preview
        #                       pane on the right and in the Touch Bar)
        #
        # Truly top-level placement (alongside "Open With" etc.) would
        # require a FinderSync app extension — a separate .appex bundle
        # with sandbox + entitlements + manual user activation. PR #51
        # explored that and we chose this lighter promotion instead.
        "workflowTypeIdentifier": "com.apple.Automator.quickActionMenu",
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
# auto-closes when the runner finishes — AppleScript polls the new
# tab's `busy` property and closes the window when the shell exits,
# regardless of the user's Terminal "Close window when shell exits"
# preference.
#
# The osascript invocation is backgrounded with `& disown` so the
# Automator workflow returns immediately while Terminal does its
# thing — otherwise Finder's Quick Action spinner would stay up for
# the whole run.

# The runner script:
#   1. Runs the actual knit command(s) so the user sees `--progress`.
#   2. Prints "[Done.]" and then `sleep 3` — the sleep keeps the tab
#      "busy" for three more seconds so the user can read the result
#      summary before the window vanishes.
#   3. Removes itself and exits.
#
# The `do script` invocation appends `; exit` to the runner path so the
# *outer* interactive zsh that Terminal opened also exits when the
# runner is done. Without that step, Terminal's "Ask before closing"
# preference still considers the tab to be running processes (the
# interactive shell + the just-ran knit binary) and pops up a
# confirmation dialog when AppleScript tries to close the window. With
# the outer shell exited, the tab has no processes and `close … saving
# no` succeeds silently regardless of the user's preference.

# --------------------------------------------------------------------
# Shared shell helpers (sourced into every Quick Action via heredoc).
# Sizes inputs and chooses between two paths:
#
#   * Silent background: input total < SIZE_THRESHOLD_BYTES.
#       knit runs detached, stdout/stderr to /dev/null, no Terminal
#       window, no notification. The user gets quiet success.
#
#   * Terminal-displayed: input total >= SIZE_THRESHOLD_BYTES.
#       The existing osascript path opens Terminal.app, runs knit with
#       --progress, auto-closes the window when the runner finishes.
#
# Threshold: 100 MiB. On M5 Max this is ~0.02 s of pack work and
# ~0.05 s of unpack work — well under the "noticeable enough to want
# feedback" line. Below the threshold the operation is over before
# Terminal would have finished animating its window in. On lower-tier
# Apple Silicon (base M1 / M2 with slower SSDs ≈ 1.5 GB/s) 100 MiB
# is closer to 0.1–0.2 s — still imperceptible.
#
# Larger values shift more operations to silent. 100 MiB is the
# user-preferred value (PR #50 spec).
SHARED_PRELUDE='
SIZE_THRESHOLD_BYTES=$((100 * 1024 * 1024))

input_total_bytes() {
    # Sum the size of every regular file under each argument. Handles
    # mixed selections of files + directories. Directories are
    # recursed via `find -type f` so we count payload bytes only
    # (directory inodes themselves arent compressed).
    local total=0
    local arg s
    for arg in "$@"; do
        if [[ -d "$arg" ]]; then
            s=$(/usr/bin/find "$arg" -type f -print0 2>/dev/null \
                  | /usr/bin/xargs -0 /usr/bin/stat -f "%z" 2>/dev/null \
                  | /usr/bin/awk "{ s += \$1 } END { print s+0 }")
        elif [[ -f "$arg" ]]; then
            s=$(/usr/bin/stat -f "%z" "$arg" 2>/dev/null || echo 0)
        else
            s=0
        fi
        total=$((total + s))
    done
    echo "$total"
}

should_show_terminal() {
    # Echo 1 if Terminal should be opened, 0 if the run should be
    # silent. Threshold-only; no time-based heuristic because we cant
    # retroactively attach a Terminal to a process we already started.
    local bytes
    bytes=$(input_total_bytes "$@")
    if (( bytes >= SIZE_THRESHOLD_BYTES )); then
        echo 1
    else
        echo 0
    fi
}
'

cat > "${TMP}/zip.sh" <<BS
${SHARED_PRELUDE}

if [[ "\$(should_show_terminal "\$@")" = "0" ]]; then
    # Small input: run silently in the background. The user gets a
    # quick visual cue from Finder (the new .zip appears alongside
    # the source) without a Terminal pop-up.
    for f in "\$@"; do
        /usr/local/bin/knit zip "\$f" --parallel --level 6 -o "\${f}.zip" \\
            >/dev/null 2>&1 &
    done
    disown
    exit 0
fi

RUNNER="\$(mktemp -t knit_zip_runner)"
{
  echo '#!/bin/zsh'
  echo 'set -u'
  for f in "\$@"; do
    printf '/usr/local/bin/knit zip %q --parallel --level 6 --progress -o %q\n' "\$f" "\${f}.zip"
  done
  echo 'printf "\\n[Done.]\\n"'
  echo 'sleep 3'
  echo "rm -f -- '\${RUNNER}'"
  echo 'exit 0'
} > "\${RUNNER}"
chmod +x "\${RUNNER}"
{
  osascript <<APPLESCRIPT
tell application "Terminal"
    activate
    set theTab to do script "\${RUNNER}; exit"
    -- \`do script\` without an \`in\` clause always opens a fresh window,
    -- so the front window right after the call is ours to close later.
    set theWindowID to id of front window
    repeat while busy of theTab
        delay 0.5
    end repeat
    -- Brief grace period so the outer zsh's \`exit\` finishes processing
    -- before we send the close request — otherwise Terminal still sees
    -- the shell as a "running process" and prompts the user.
    delay 0.3
    repeat with w in windows
        if id of w is theWindowID then
            close w saving no
            exit repeat
        end if
    end repeat
end tell
APPLESCRIPT
} >/dev/null 2>&1 &
disown
BS

cat > "${TMP}/bzx.sh" <<BS
${SHARED_PRELUDE}

if [[ "\$(should_show_terminal "\$@")" = "0" ]]; then
    for f in "\$@"; do
        /usr/local/bin/knit pack "\$f" --level 3 -o "\${f}.knit" \\
            >/dev/null 2>&1 &
    done
    disown
    exit 0
fi

RUNNER="\$(mktemp -t knit_pack_runner)"
{
  echo '#!/bin/zsh'
  echo 'set -u'
  for f in "\$@"; do
    printf '/usr/local/bin/knit pack %q --level 3 --progress -o %q\n' "\$f" "\${f}.knit"
  done
  echo 'printf "\\n[Done.]\\n"'
  echo 'sleep 3'
  echo "rm -f -- '\${RUNNER}'"
  echo 'exit 0'
} > "\${RUNNER}"
chmod +x "\${RUNNER}"
{
  osascript <<APPLESCRIPT
tell application "Terminal"
    activate
    set theTab to do script "\${RUNNER}; exit"
    set theWindowID to id of front window
    repeat while busy of theTab
        delay 0.5
    end repeat
    delay 0.3
    repeat with w in windows
        if id of w is theWindowID then
            close w saving no
            exit repeat
        end if
    end repeat
end tell
APPLESCRIPT
} >/dev/null 2>&1 &
disown
BS

cat > "${TMP}/extract.sh" <<BS
${SHARED_PRELUDE}

# For Extract the input is the compressed archive itself, so the size
# threshold uses the archive's on-disk size. A 100 MiB .knit
# decompresses to anywhere from ~100 MB to ~3 GB depending on ratio;
# treating the archive size as the gate keeps the decision simple
# without parsing the footer.
if [[ "\$(should_show_terminal "\$@")" = "0" ]]; then
    for f in "\$@"; do
        dir="\$(dirname "\$f")"
        case "\$f" in
          *.knit) /usr/local/bin/knit unpack "\$f" -o "\$dir" >/dev/null 2>&1 & ;;
          *.zip)  /usr/bin/unzip -o "\$f" -d "\$dir" >/dev/null 2>&1 & ;;
        esac
    done
    disown
    exit 0
fi

RUNNER="\$(mktemp -t knit_extract_runner)"
{
  echo '#!/bin/zsh'
  echo 'set -u'
  for f in "\$@"; do
    dir="\$(dirname "\$f")"
    case "\$f" in
      *.knit) printf '/usr/local/bin/knit unpack %q --progress -o %q\n' "\$f" "\$dir" ;;
      *.zip)  printf '/usr/bin/unzip -o %q -d %q\n' "\$f" "\$dir" ;;
    esac
  done
  echo 'printf "\\n[Done.]\\n"'
  echo 'sleep 3'
  echo "rm -f -- '\${RUNNER}'"
  echo 'exit 0'
} > "\${RUNNER}"
chmod +x "\${RUNNER}"
{
  osascript <<APPLESCRIPT
tell application "Terminal"
    activate
    set theTab to do script "\${RUNNER}; exit"
    set theWindowID to id of front window
    repeat while busy of theTab
        delay 0.5
    end repeat
    delay 0.3
    repeat with w in windows
        if id of w is theWindowID then
            close w saving no
            exit repeat
        end if
    end repeat
end tell
APPLESCRIPT
} >/dev/null 2>&1 &
disown
BS

emit_workflow "Knit Compress (ZIP)"  "${TMP}/zip.sh"
emit_workflow "Knit Compress (.knit)" "${TMP}/bzx.sh"
emit_workflow "Knit Extract"         "${TMP}/extract.sh"

echo
echo "Quick Actions written to: ${DIST}"
ls -la "${DIST}"
