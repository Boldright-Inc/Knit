#!/usr/bin/env bash
set -euo pipefail

# Fetches libdeflate and zstd C sources, copies them into the SPM C targets,
# and rewrites a few "../foo.h" relative includes that don't fit SwiftPM's flat layout.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/Vendor"
WORK_DIR="${VENDOR_DIR}/.work"

LIBDEFLATE_REPO="https://github.com/ebiggers/libdeflate.git"
LIBDEFLATE_TAG="v1.22"

ZSTD_REPO="https://github.com/facebook/zstd.git"
ZSTD_TAG="v1.5.6"

mkdir -p "${WORK_DIR}"

fetch_repo() {
    local name="$1" repo="$2" tag="$3"
    local dst="${WORK_DIR}/${name}"
    if [[ -d "${dst}/.git" ]]; then
        echo ">> Updating ${name} to ${tag}"
        git -C "${dst}" fetch --tags --depth 1 origin "${tag}"
        git -C "${dst}" checkout -q "${tag}"
    else
        echo ">> Cloning ${name} @ ${tag}"
        git clone --depth 1 --branch "${tag}" "${repo}" "${dst}"
    fi
}

fetch_repo libdeflate "${LIBDEFLATE_REPO}" "${LIBDEFLATE_TAG}"
fetch_repo zstd       "${ZSTD_REPO}"       "${ZSTD_TAG}"

# --- libdeflate -> Sources/CDeflate ---
LD_DST="${ROOT_DIR}/Sources/CDeflate"
LD_SRC="${WORK_DIR}/libdeflate"
echo ">> Installing libdeflate -> ${LD_DST}"
rm -rf "${LD_DST}/src" "${LD_DST}/include/libdeflate.h"
mkdir -p "${LD_DST}/src" "${LD_DST}/include"

# Copy lib sources flatly while preserving subdirs (arm/, x86/, etc.)
( cd "${LD_SRC}/lib" && find . \( -name '*.c' -o -name '*.h' \) -print0 \
  | xargs -0 -I{} bash -c 'mkdir -p "$2/$(dirname "$1")" && cp "$1" "$2/$1"' _ {} "${LD_DST}/src" )

# Top-level headers used via "../foo.h" from lib/. Place them in src/ and rewrite.
cp "${LD_SRC}/common_defs.h" "${LD_DST}/src/common_defs.h"
cp "${LD_SRC}/libdeflate.h"  "${LD_DST}/src/libdeflate.h"

# Public umbrella header so Swift can `import CDeflate`
cp "${LD_SRC}/libdeflate.h" "${LD_DST}/include/libdeflate.h"
cat > "${LD_DST}/include/CDeflate.h" <<'EOF'
#ifndef CDEFLATE_H
#define CDEFLATE_H
#include "libdeflate.h"
#endif
EOF
cp "${LD_SRC}/COPYING" "${LD_DST}/LICENSE" 2>/dev/null || true

# Rewrite "../common_defs.h" / "../libdeflate.h" -> sibling include
find "${LD_DST}/src" -type f \( -name '*.c' -o -name '*.h' \) -print0 \
  | xargs -0 sed -i '' -e 's|"\.\./common_defs\.h"|"common_defs.h"|g' \
                       -e 's|"\.\./libdeflate\.h"|"libdeflate.h"|g'

# --- zstd -> Sources/CZstd ---
ZS_DST="${ROOT_DIR}/Sources/CZstd"
ZS_SRC="${WORK_DIR}/zstd"
echo ">> Installing zstd -> ${ZS_DST}"
rm -rf "${ZS_DST}/src" "${ZS_DST}/include/zstd.h"
mkdir -p "${ZS_DST}/src" "${ZS_DST}/include"

# Copy required directories (preserve common/ compress/ decompress/)
for sub in common compress decompress; do
    mkdir -p "${ZS_DST}/src/${sub}"
    cp "${ZS_SRC}/lib/${sub}"/*.c "${ZS_DST}/src/${sub}/" 2>/dev/null || true
    cp "${ZS_SRC}/lib/${sub}"/*.h "${ZS_DST}/src/${sub}/" 2>/dev/null || true
    cp "${ZS_SRC}/lib/${sub}"/*.S "${ZS_DST}/src/${sub}/" 2>/dev/null || true
done

# zstd lib/*.h sit at the lib/ root and are referenced via "../foo.h" from common/, etc.
# Place them at src/ root so the relative includes resolve.
cp "${ZS_SRC}/lib/zstd.h"        "${ZS_DST}/src/zstd.h"
cp "${ZS_SRC}/lib/zstd_errors.h" "${ZS_DST}/src/zstd_errors.h" 2>/dev/null || \
  cp "${ZS_SRC}/lib/common/zstd_errors.h" "${ZS_DST}/src/zstd_errors.h"

# Public umbrella header
cp "${ZS_SRC}/lib/zstd.h"        "${ZS_DST}/include/zstd.h"
cp "${ZS_SRC}/lib/zstd_errors.h" "${ZS_DST}/include/zstd_errors.h" 2>/dev/null || \
  cp "${ZS_SRC}/lib/common/zstd_errors.h" "${ZS_DST}/include/zstd_errors.h"

cat > "${ZS_DST}/include/CZstd.h" <<'EOF'
#ifndef CZSTD_H
#define CZSTD_H
#include "zstd.h"
#include "zstd_errors.h"
#endif
EOF
cp "${ZS_SRC}/LICENSE" "${ZS_DST}/LICENSE" 2>/dev/null || true

echo ">> Done."
echo "   libdeflate: ${LIBDEFLATE_TAG}"
echo "   zstd:       ${ZSTD_TAG}"
