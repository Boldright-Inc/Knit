#!/usr/bin/env bash
# bench-corpora.sh — run `knit pack --analyze` and `knit unpack --analyze`
# against every corpus under KNIT_BENCH_CORPUS_ROOT, then write a
# summary.tsv plus per-corpus analyze logs to
# Tests/Benchmarks/results/<timestamp>/.
#
# The post-#39 "Current bench reference" section in CLAUDE.md captures
# expected stage walls; this script makes those numbers reproducible
# from local corpora and gives every future codec PR a one-command
# regression check (per CLAUDE.md § Performance investigation
# discipline — analyse-driven, not intuition-driven).
#
# Corpus discovery:
#   - KNIT_BENCH_CORPUS_ROOT (default: Tests/TestData/) — every direct
#     child is a corpus. Directories are packed as folders;
#     standalone files are packed individually.
#   - Each corpus name = basename of the child; that's the prefix used
#     for output filenames.
#
# Selection:
#   - Optional positional args restrict the run to specific corpora by
#     name. e.g. `bench-corpora.sh test2` only runs `test2`. With no
#     args, every corpus under the root is bench'd.
#
# Output:
#   Tests/Benchmarks/results/<timestamp>/
#     summary.tsv                          tab-separated wall/cpu/size table
#     <corpus>-pack-analyze.txt            stderr from `knit pack --analyze`
#     <corpus>-unpack-analyze.txt          stderr from `knit unpack --analyze`
#
# Usage:
#   ./Scripts/bench-corpora.sh                # all corpora under default root
#   ./Scripts/bench-corpora.sh test2          # one corpus by name
#   KNIT_BENCH_CORPUS_ROOT=/path/to/data ./Scripts/bench-corpora.sh
#   KNIT_BENCH_MODE=zip ./Scripts/bench-corpora.sh   # use `knit zip` + `knit unzip`
#                                                    # instead of `knit pack` + `knit unpack`
#
# Mode selector:
#   KNIT_BENCH_MODE=knit (default) — packs to `.knit`, unpacks via `knit unpack`.
#   KNIT_BENCH_MODE=zip            — zips to `.zip`, unzips via `knit unzip`.
#                                    Used to gather analyze data on the ZIP
#                                    extractor path (CLAUDE.md "Investigated,
#                                    no-go" / GPU-decode verification work).
#
# Exit status: non-zero on the first knit invocation that fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CORPUS_ROOT="${KNIT_BENCH_CORPUS_ROOT:-${ROOT_DIR}/Tests/TestData}"
RESULTS_ROOT="${ROOT_DIR}/Tests/Benchmarks/results"
KNIT="${ROOT_DIR}/.build/release/knit"
MODE="${KNIT_BENCH_MODE:-knit}"

# Validate the mode selector early — typo'd values would silently fall
# through to `knit pack` which makes regression-bench results
# misleading.
case "${MODE}" in
    knit|zip) ;;
    *)
        echo "error: KNIT_BENCH_MODE must be 'knit' or 'zip', got '${MODE}'" >&2
        exit 2
        ;;
esac

# Per-mode subcommand + extension names. Used in `run_one` below.
case "${MODE}" in
    knit)
        PACK_CMD=pack
        UNPACK_CMD=unpack
        ARCHIVE_EXT=knit
        ;;
    zip)
        PACK_CMD=zip
        UNPACK_CMD=unzip
        ARCHIVE_EXT=zip
        ;;
esac

if [[ ! -d "${CORPUS_ROOT}" ]]; then
    echo "error: corpus root not found: ${CORPUS_ROOT}" >&2
    echo "       set KNIT_BENCH_CORPUS_ROOT or stage corpora under Tests/TestData/" >&2
    exit 2
fi

# Build knit in release if missing or older than Package.swift. Release
# mode is the only mode that runs Swift 6 strict-concurrency to
# completion (CLAUDE.md Rule 1), so the benchmarked binary is always
# the same one our PRs ship.
if [[ ! -x "${KNIT}" ]] || [[ "${ROOT_DIR}/Package.swift" -nt "${KNIT}" ]]; then
    echo "Building knit (release)..." >&2
    ( cd "${ROOT_DIR}" && swift build -c release )
fi

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${RESULTS_ROOT}/${TS}"
mkdir -p "${OUT_DIR}"

SUMMARY="${OUT_DIR}/summary.tsv"
printf 'corpus\toperation\twall_s\tcpu_s\tin_bytes\tout_bytes\tratio\n' > "${SUMMARY}"

# Build the list of corpora to bench. Positional args (if any) name the
# children to include; otherwise we take every direct child of the root.
declare -a CORPORA
if (( $# > 0 )); then
    for name in "$@"; do
        path="${CORPUS_ROOT}/${name}"
        if [[ ! -e "${path}" ]]; then
            echo "error: corpus not found under ${CORPUS_ROOT}: ${name}" >&2
            exit 2
        fi
        CORPORA+=( "${path}" )
    done
else
    while IFS= read -r -d '' entry; do
        # Skip hidden entries (.DS_Store, .gitkeep, etc.) — they're never corpora.
        base="$(basename "${entry}")"
        [[ "${base}" == .* ]] && continue
        CORPORA+=( "${entry}" )
    done < <(find "${CORPUS_ROOT}" -mindepth 1 -maxdepth 1 -print0 | sort -z)
fi

if (( ${#CORPORA[@]} == 0 )); then
    echo "error: no corpora discovered under ${CORPUS_ROOT}" >&2
    exit 2
fi

# Wall + CPU capture. `/usr/bin/time -lp -o <file>` runs the command
# and writes `real`/`user`/`sys` (plus rusage detail) to <file>,
# leaving the child's stderr free for the --analyze stream. The `-p`
# format is POSIX-stable: three lines of `key value` we grep out.
parse_rusage_field() {
    # $1 = path to rusage file, $2 = field name (real/user/sys)
    awk -v k="$2" '$1 == k { printf "%.3f", $2; found=1 } END { if (!found) print "0.000" }' "$1"
}

size_of() {
    # Bytes of a file or recursive directory total. macOS `du -k` is
    # 1024-byte blocks; we want exact byte counts for the ratio
    # column, so use find + stat to sum file sizes.
    local p="$1"
    if [[ -d "${p}" ]]; then
        # %z = total size in bytes (POSIX); macOS stat uses -f '%z'.
        find "${p}" -type f -print0 \
            | xargs -0 stat -f '%z' 2>/dev/null \
            | awk '{ s += $1 } END { print (s+0) }'
    elif [[ -e "${p}" ]]; then
        stat -f '%z' "${p}"
    else
        echo 0
    fi
}

ratio_pct() {
    # $1 = original bytes, $2 = compressed bytes. Print compressed/orig
    # as a percentage, three decimals. Zero originals report "n/a".
    python3 -c "o=${1}; c=${2}; print(f'{(c/o*100):.3f}' if o else 'n/a')"
}

run_one() {
    local input="$1"
    local name
    name="$(basename "${input}")"

    local archive="${OUT_DIR}/${name}.${ARCHIVE_EXT}"
    local extract="${OUT_DIR}/${name}-unpacked"
    local pack_log="${OUT_DIR}/${name}-${PACK_CMD}-analyze.txt"
    local unpack_log="${OUT_DIR}/${name}-${UNPACK_CMD}-analyze.txt"

    mkdir -p "${extract}"

    local in_bytes
    in_bytes="$(size_of "${input}")"

    local pack_rusage="${OUT_DIR}/${name}-${PACK_CMD}-rusage.txt"
    local unpack_rusage="${OUT_DIR}/${name}-${UNPACK_CMD}-rusage.txt"

    # `knit zip` doesn't have --analyze (it's a compress-side
    # diagnostic that requires StageAnalytics wiring through the
    # pack-specific pipeline — the ZIP compress path is separate).
    # The unpack/unzip side does support --analyze for both modes,
    # which is the bench's primary purpose here.
    local pack_analyze_flag=()
    if [[ "${MODE}" == "knit" ]]; then
        pack_analyze_flag=(--analyze)
    fi

    echo "== ${name}: ${PACK_CMD}" >&2
    /usr/bin/time -lp -o "${pack_rusage}" \
        "${KNIT}" "${PACK_CMD}" "${input}" -o "${archive}" \
            "${pack_analyze_flag[@]}" 2> "${pack_log}"
    local pack_wall pack_user pack_sys pack_cpu out_bytes ratio
    pack_wall="$(parse_rusage_field "${pack_rusage}" real)"
    pack_user="$(parse_rusage_field "${pack_rusage}" user)"
    pack_sys="$(parse_rusage_field  "${pack_rusage}" sys)"
    pack_cpu="$(python3 -c "print(f'{${pack_user} + ${pack_sys}:.3f}')")"
    out_bytes="$(size_of "${archive}")"
    ratio="$(ratio_pct "${in_bytes}" "${out_bytes}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${name}" "${PACK_CMD}" "${pack_wall}" "${pack_cpu}" \
        "${in_bytes}" "${out_bytes}" "${ratio}" >> "${SUMMARY}"

    echo "== ${name}: ${UNPACK_CMD}" >&2
    /usr/bin/time -lp -o "${unpack_rusage}" \
        "${KNIT}" "${UNPACK_CMD}" "${archive}" -o "${extract}" --analyze 2> "${unpack_log}"
    local unpack_wall unpack_user unpack_sys unpack_cpu
    unpack_wall="$(parse_rusage_field "${unpack_rusage}" real)"
    unpack_user="$(parse_rusage_field "${unpack_rusage}" user)"
    unpack_sys="$(parse_rusage_field  "${unpack_rusage}" sys)"
    unpack_cpu="$(python3 -c "print(f'{${unpack_user} + ${unpack_sys}:.3f}')")"
    # For unpack the "out" is the extracted tree; "in" is the .knit.
    # Reuse the same columns but flipped — keeps summary.tsv schema
    # stable across pack/unpack rows.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${name}" "${UNPACK_CMD}" "${unpack_wall}" "${unpack_cpu}" \
        "${out_bytes}" "${in_bytes}" "${ratio}" >> "${SUMMARY}"

    # Clean up the extracted tree and the archive. The post-run results
    # dir only needs to keep the small analyze + rusage logs to be
    # useful as a regression record — the .knit is ~80 GB on the VM
    # corpus and we'd run out of disk after a handful of runs. Set
    # KNIT_BENCH_KEEP_ARCHIVE=1 to opt out (e.g. when iterating on a
    # codec change and you want to re-unpack the same archive
    # without re-packing).
    rm -rf "${extract}"
    if [[ "${KNIT_BENCH_KEEP_ARCHIVE:-0}" != "1" ]]; then
        rm -f "${archive}"
    fi
}

for input in "${CORPORA[@]}"; do
    run_one "${input}"
done

echo "Done. Results in ${OUT_DIR}" >&2
echo "Summary:" >&2
column -t -s $'\t' "${SUMMARY}" >&2
