#!/usr/bin/env bash
# Compare Knit CPU vs alternatives on a corpus of mixed compressibility data.
# Usage:  ./Scripts/bench.sh [size_mb=1024]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SIZE_MB="${1:-1024}"
WORK="${ROOT_DIR}/Tests/Benchmarks/data"
RESULTS_DIR="${ROOT_DIR}/Tests/Benchmarks/results"
mkdir -p "${WORK}" "${RESULTS_DIR}"

CORPUS="${WORK}/corpus_${SIZE_MB}mb"
KNIT="${ROOT_DIR}/.build/release/knit"

if [[ ! -x "${KNIT}" ]]; then
    echo "Building knit release..."
    ( cd "${ROOT_DIR}" && swift build -c release >/dev/null )
fi

# --- Build corpus ---
if [[ ! -d "${CORPUS}" ]]; then
    echo "Building ${SIZE_MB} MB corpus at ${CORPUS}"
    mkdir -p "${CORPUS}"
    third=$(( SIZE_MB / 3 ))
    # 1) random/incompressible
    dd if=/dev/urandom of="${CORPUS}/random.bin"      bs=1m count=${third} status=none
    # 2) highly compressible repeating text
    yes "Knit benchmark line for compression test " | head -c $(( third * 1024 * 1024 )) > "${CORPUS}/repeating.txt"
    # 3) "realistic" mix — concat of system text files + duplication
    {
        find /usr/share/man -type f -name '*.gz' 2>/dev/null | head -2000 | xargs -I{} gzcat {} 2>/dev/null
        cat /usr/share/dict/words 2>/dev/null
        cat /System/Library/Frameworks/Foundation.framework/Headers/*.h 2>/dev/null
    } | head -c $(( third * 1024 * 1024 )) > "${CORPUS}/mixed.txt" || true
    # Pad to size if mixed.txt didn't fill
    actual=$(du -m "${CORPUS}/mixed.txt" | awk '{print $1}')
    if (( actual < third )); then
        dd if=/dev/zero of="${CORPUS}/zeros.bin" bs=1m count=$(( third - actual )) status=none
    fi
fi

# Total input size
INPUT_BYTES=$(find "${CORPUS}" -type f -exec stat -f '%z' {} \; | awk '{s+=$1} END {print s}')
INPUT_MB=$(( INPUT_BYTES / 1024 / 1024 ))
echo
echo "==== Corpus: ${INPUT_MB} MB ($(find "${CORPUS}" -type f | wc -l | tr -d ' ') files) ===="
echo

# --- Bench helpers ---
RESULTS="${RESULTS_DIR}/bench_$(date +%Y%m%d_%H%M%S).tsv"
{
    printf "tool\tlevel\twall_s\tin_mb\tout_mb\tratio\tmbs\n"
} > "${RESULTS}"

bench_run() {
    local label="$1" level="$2" outfile="$3"
    shift 3
    local cmd="$@"
    rm -f "${outfile}"
    # Use /usr/bin/time for wall clock
    local start end
    start=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    eval "${cmd}" >/dev/null 2>&1
    end=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    local wall
    wall=$(awk -v s="$start" -v e="$end" 'BEGIN{printf "%.3f", e - s}')
    local out_bytes=0
    if [[ -f "${outfile}" ]]; then
        out_bytes=$(stat -f '%z' "${outfile}")
    fi
    local out_mb
    out_mb=$(awk -v b="$out_bytes" 'BEGIN{printf "%.2f", b/1024/1024}')
    local ratio
    ratio=$(awk -v o="$out_bytes" -v i="$INPUT_BYTES" 'BEGIN{printf "%.2f", o/i*100}')
    local mbs
    mbs=$(awk -v in_mb="$INPUT_MB" -v w="$wall" 'BEGIN{printf "%.1f", in_mb/w}')
    printf "%-22s lvl=%-2s  wall=%6.2fs  in=%5dMB  out=%6sMB  ratio=%5s%%  speed=%6s MB/s\n" \
        "${label}" "${level}" "${wall}" "${INPUT_MB}" "${out_mb}" "${ratio}" "${mbs}"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "${label}" "${level}" "${wall}" "${INPUT_MB}" "${out_mb}" "${ratio}" "${mbs}" >> "${RESULTS}"
}

# Drop kernel page cache for input between runs (best effort)
purge_caches() {
    sync
    # purge requires sudo; on M-series RAM is huge so caching doesn't matter much for >1GB data.
    return 0
}

# --- 1) macOS Archive Utility (via ditto, equivalent compression engine) ---
purge_caches
bench_run "ditto (Archive Util)" "-" "${WORK}/out_ditto.zip" \
    "ditto -c -k --sequesterRsrc \"${CORPUS}\" \"${WORK}/out_ditto.zip\""

# --- 2) zip (single-threaded) ---
purge_caches
bench_run "zip -6" "6" "${WORK}/out_zip6.zip" \
    "( cd \"$(dirname "${CORPUS}")\" && /usr/bin/zip -r -q -6 \"${WORK}/out_zip6.zip\" \"$(basename "${CORPUS}")\" )"

# --- 3) pigz (multi-threaded gzip — note: produces .tar.gz, not .zip) ---
purge_caches
bench_run "tar+pigz -6" "6" "${WORK}/out_pigz.tgz" \
    "tar -cf - -C \"$(dirname "${CORPUS}")\" \"$(basename "${CORPUS}")\" | pigz -6 > \"${WORK}/out_pigz.tgz\""

# --- 4) Knit CPU per-file backend at multiple levels ---
for level in 1 6 9; do
    purge_caches
    bench_run "knit CPU lvl=${level}" "${level}" "${WORK}/out_knit_${level}.zip" \
        "${KNIT} zip \"${CORPUS}\" -o \"${WORK}/out_knit_${level}.zip\" --level ${level}"
done

# --- 5) Knit parallel zlib backend at multiple levels ---
for level in 1 6 9; do
    purge_caches
    bench_run "knit PAR lvl=${level}" "${level}" "${WORK}/out_knit_par_${level}.zip" \
        "${KNIT} zip \"${CORPUS}\" -o \"${WORK}/out_knit_par_${level}.zip\" --level ${level} --parallel"
done

# --- 6) Knit .knit (zstd block-parallel) at multiple levels ---
for level in 1 3 9; do
    purge_caches
    bench_run "knit pack lvl=${level}" "${level}" "${WORK}/out_knit_${level}.knit" \
        "${KNIT} pack \"${CORPUS}\" -o \"${WORK}/out_knit_${level}.knit\" --level ${level}"
done

echo
echo "Results saved to ${RESULTS}"
