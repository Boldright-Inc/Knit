#!/usr/bin/env bash
# Run KnitCoreTests during development.
#
# The shipping Package.swift intentionally omits the test target so that
# distribution clones (which may not include Tests/) build cleanly in Xcode.
# This script temporarily swaps in a dev manifest that *does* declare the
# tests, runs `swift test`, and restores the original manifest afterwards.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ ! -d "Tests/KnitCoreTests" ]]; then
    echo "error: Tests/KnitCoreTests/ is not present — nothing to run." >&2
    exit 1
fi

# Append the test target to a copy of Package.swift, build/run, then revert.
ORIG="$(mktemp)"
cp Package.swift "${ORIG}"
trap 'cp "${ORIG}" Package.swift; rm -f "${ORIG}"' EXIT

# Insert a test target just before the closing `]` `)` of `targets:`.
python3 - <<'PYEOF'
import re, pathlib
p = pathlib.Path("Package.swift")
src = p.read_text()
inject = '''        .testTarget(
            name: "KnitCoreTests",
            dependencies: ["KnitCore"],
            path: "Tests/KnitCoreTests"
        ),
'''
# Add the .testTarget line before the closing `]\n    )\n`
new = re.sub(r'(\n    \]\n\)\n?$)', '\n' + inject + r'\1', src, count=1)
if new == src:
    raise SystemExit("Couldn't locate target list closer in Package.swift")
p.write_text(new)
PYEOF

echo ">> Running tests..."
rm -rf .build/checkouts .build/repositories || true
swift test "$@"
