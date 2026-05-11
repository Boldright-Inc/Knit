# Knit

> Fast, modern file compression for Apple Silicon.

Knit is a compression utility built natively for Apple Silicon Macs (M-series). It pairs a standard ZIP encoder with a custom `.knit` archive format, both driven by a multi-threaded compression engine designed to saturate the M-series memory subsystem and modern NVMe storage — fast enough that the bottleneck shifts from the CPU back to your disk.

When interoperability matters, `knit zip` produces fully spec-compliant ZIP archives — including ZIP64 for files beyond 4 GB — that open with any standard unzip implementation on any platform. When you want the absolute best throughput, `knit pack` writes a `.knit` container: each entry is split into independent zstd frames, allowing the encoder to fan out across every core and the decoder to support random-access seeking into any block. Single huge files (10 GB+) compress in parallel via a pigz-style chunked DEFLATE strategy that emits one valid stream while still keeping all cores busy.

In benchmarks on a 1 GB mixed corpus (M5 Max), Knit is up to **~50× faster** than macOS's built-in `ditto` / Archive Utility for `.knit` output, and roughly **~10× faster** than `pigz` for standard ZIP — at equal or better compression ratios. The numbers reproduce with the included `Scripts/bench.sh` harness.

Right-click integration is included: installing Knit adds three Finder Quick Actions — *Knit Compress (ZIP)*, *Knit Compress (.knit)*, and *Knit Extract* — that wrap the CLI for day-to-day use. Under the hood, the engine is a **hybrid CPU + GPU pipeline**: **libdeflate** drives single-threaded DEFLATE, **system zlib** powers `Z_SYNC_FLUSH`-based chunk-parallel ZIP, **libzstd** is the core of `.knit`, and a **Metal compute pipeline** runs the work that benefits most from massive parallelism — CRC32 integrity, byte-histogram entropy analysis, and post-extract verification.

## Highlights

- **Apple Silicon native** — arm64-only binary, tuned for unified memory and high-bandwidth interconnect
- **Two formats, one tool**
  - **ZIP** — fully standard, ZIP64-capable, interoperable everywhere
  - **`.knit`** — block-parallel zstd container, faster and smaller than DEFLATE at equivalent compression levels
- **Up to ~50× faster** than macOS Archive Utility, **~10× faster** than `pigz`
- **Single-file parallelism** via zlib `Z_SYNC_FLUSH` stitching — one logical DEFLATE stream, full multi-core utilization
- **Hybrid CPU + GPU pipeline** — Metal handles CRC32, entropy pre-screening, and extract-time verification; libdeflate / libzstd handle the codec itself
- **Compressibility heatmap** — after every `--heatmap` run, Knit renders an entropy-coloured grid of every block in the archive (also exportable as PNG-style PPM)
- **Finder right-click integration** through macOS Quick Actions
- **Distribution-ready** — Developer ID code signing and Apple notarization wired into the packaging script

## Requirements

- macOS 15 Sequoia or later
- Apple Silicon (arm64)
- Xcode Command Line Tools (Swift 6 / Metal SDK)

## Build & Install

```bash
# Fetch vendored sources (libdeflate / zstd)
./Scripts/fetch-vendor.sh

# Release build
swift build -c release

# Install Finder right-click menu items + /usr/local/bin/knit
./Scripts/install.sh        # asks for sudo password
```

After running `install.sh`, right-click any file or folder in Finder to find these entries under **Quick Actions**:

- **Knit Compress (ZIP)** — produces a standard `.zip` (extractable anywhere)
- **Knit Compress (.knit)** — produces the internal high-speed `.knit` format
- **Knit Extract** — auto-detects `.zip` or `.knit` and extracts

## CLI

```bash
knit info                            # environment + library versions
knit metal-info                      # Metal device probe + GPU CRC32 self-test
knit zip   <input> [-o out.zip]   [--level 6] [--parallel] [--chunk-kb 1024]
                                  [--heatmap] [--heatmap-image map.ppm]
knit pack  <input> [-o out.knit]  [--level 3] [--block-kb 1024]
                                  [--heatmap] [--heatmap-image map.ppm]
knit unpack <archive> [-o output_dir] [--no-gpu-verify]
```

Add `--parallel` to use the pigz-style chunk-parallel ZIP backend. This is the path to use for a single very large file. Add `--heatmap` to either `zip` or `pack` to print the compressibility map after the run, and `--heatmap-image <path>` to also save a portable PPM image you can open in Preview.app.

By default `unpack` verifies every entry's CRC32 on the GPU for entries ≥ 4 MiB and falls through to libdeflate's CPU path otherwise. Use `--no-gpu-verify` to force the CPU path (debugging or comparison only).

## Hybrid CPU + GPU pipeline

Compression is fundamentally serial at the codec level — DEFLATE and zstd's match search and entropy coding contain dependencies that don't map cleanly to the SIMT execution model. Apple Silicon also already has the rare property that a well-tuned CPU codec can saturate available memory bandwidth at low compression levels, so moving the codec itself onto the GPU produces minimal end-to-end gains.

Knit's Metal pipeline therefore focuses on the work where massive parallelism *does* pay:

| Stage | Engine | What it does |
|---|---|---|
| Codec (DEFLATE / zstd) | **CPU** (libdeflate / libzstd) | The actual literal/match emission and entropy coding |
| **Compressibility pre-screen** | **GPU** (`byte_histogram` MSL kernel) | Per-block 256-bin byte histogram → Shannon entropy. Above 7.5 bits/byte, ZIP entries skip the codec entirely; `.knit` blocks downgrade to lvl=1 since match search is wasted on noise. Dispatched at ~256 MiB chunk granularity, pipelined alongside worker compress. |
| **CRC32 — pack side** | **CPU** (libdeflate) | Per-block CRC inside the compression worker, on cache-warm pages. We investigated moving this to MetalCRC32 (per-batch dispatch, pipelined like the entropy probe), but per-dispatch overhead exceeds libdeflate's full compute on typical 32–64 MiB batch sizes — see "Architecture decisions we ruled out" below. |
| **CRC32 — extract side** | **GPU** (`crc32_per_slice` MSL kernel) | After each entry is written, the freshly written file is mmap'd (page-cache hot) and re-CRC'd to verify against the archive header. Entries < 4 MiB fall through to libdeflate. The GPU path wins here because the input is one large contiguous buffer — exactly the regime where MetalCRC32's dispatch overhead amortises. |
| **Literal-section classifier** | **CPU** (header walker) | Inside `unpack --analyze`, every zstd block's literal-section header is classified (Raw / RLE / Compressed_1Stream / Compressed_4Stream / Treeless). The output drives the Phase 1b GPU-Huffman go/no-go gate. Stays under 2 % of `parallel.decode` wall; opt-in via `--analyze`. |
| **Heatmap visualization** | **GPU** (probe data) → **CPU** render | Per-block samples drive a 24-bit ANSI heatmap and an exportable PPM. |

The result is an honest division of labour: the CPU compresses, the GPU classifies and verifies, and the user gets to *see* the compressibility of their data — which is what the heatmap is for.

## The compressibility heatmap

Add `--heatmap` to any `zip` or `pack` invocation:

```text
╭──────────────────────────────────────────────────────────────╮
│  Knit Compressibility Map                                    │
│  archive.knit  •  12.3 GB  •  12,584 block samples           │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ▁▁▁▁▁▁▂▃▄▅▆▇█▇▆▅▄▃▂▁▂▃▄▅▆█▇▆▅▄▃▂▁▁▁▂▃▄▅▆▇█▇▆▅▄▃▂▁▁▁▁▁▁▁▁  │
│  ▁▁▂▃▅▆█▇▅▃▂▁▁▁▁▂▃▄▅▆▇█▇▆▅▄▃▂▁▂▃▄▅▆▇█▇▆▅▄▃▂▁▁▁▂▃▄▅▆▇█▇▆▅▄  │
│  ▃▂▁▁▁▂▃▄▅▆▇█▇▆▅▄▃▂▁▁▁▁▁▁▁▂▃▄▅▆▇█▇▆▅▄▃▂▁▁▁▁▁▂▃▄▅▆▇█▇▆▅▄▃▂  │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│  Entropy ramp:                                               │
│    ████████████████████████████████████████████              │
│    0 bit/byte ◀────── compressible ──────▶ 8 bit/byte        │
│    Bar height: stored/original ratio (▁ smaller, █ unchanged)│
├──────────────────────────────────────────────────────────────┤
│  Blocks:         12584  total                                │
│  Compressed:      9341  ( 74.2%)  ████████████████████░░░    │
│  Stored:          3243  ( 25.8%)  ██████░░░░░░░░░░░░░░░░░    │
│  Mean entropy: 5.40 bits/byte                                │
│  Bytes in/out: 12300.00 MB → 4271.10 MB  (34.72%)            │
│  Throughput:   1.49 s wall, 8255 MB/s                        │
│  GPU:          Apple M5 Max  (unified memory)                │
╰──────────────────────────────────────────────────────────────╯
```

In a 24-bit-capable terminal (Terminal.app, iTerm2, VS Code's integrated terminal) every cell is coloured by entropy — deep indigo for highly compressible text and code, ramping through teal/green/amber up to red for already-compressed media (JPEG, MP4, encrypted blobs). Bar heights show how much each block actually shrank on disk: short bars are big wins, full-height bars are blocks that landed verbatim.

`--heatmap-image <path>` also writes a P6 PPM that opens directly in Preview.app — useful for sharing screenshots or attaching to a bug report.

## Benchmark (M5 Max, 1 GB mixed corpus)

| Tool | Speed | Ratio | vs. Archive Utility |
|---|---|---|---|
| macOS Archive Utility (`ditto`) | 165 MB/s | 34.81% | **1.0×** (baseline) |
| `zip -6` (single-threaded) | 143 MB/s | 34.81% | 0.86× |
| `tar+pigz -6` (multi-threaded) | 1020 MB/s | 34.82% | 6.2× |
| **Knit ZIP `--parallel` lvl=1** | **2214 MB/s** | 35.20% | **13.4×** |
| **Knit ZIP `--parallel` lvl=6** | **1789 MB/s** | 34.81% | **10.8×** |
| **Knit `.knit` lvl=1** (zstd) | **7998 MB/s** | 34.80% | **48.5×** |
| **Knit `.knit` lvl=3** (zstd) | **8226 MB/s** | **34.70%** | **49.8×** |
| Knit `.knit` lvl=9 (zstd) | 5735 MB/s | 34.55% | 34.8× |

**Extrapolated to 50 GB: 6–10 minutes drops to roughly 6 seconds with `.knit`** — though in practice the 5–7 GB/s NVMe SSD I/O ceiling becomes the real upper bound. On lower-tier Apple Silicon (base M1/M2/M3 with 256 GB SSDs ≈ 1.5–2 GB/s), I/O is the dominant bottleneck for any compression tool, and the entropy probe pays off most when the corpus mixes compressible and already-compressed content.

Reproduce with `./Scripts/bench.sh [size_mb=1024]`.

**About these numbers (caveat).** The table above is a *cool-start single-shot* measurement. `Scripts/bench.sh` runs an 11-tool sequence back-to-back without sleep between tools — by the time it reaches `knit pack`, the M5 Max has already been driven hard by `ditto` (~9 s burn) and `knit CPU lvl=9` (~5 s burn), so the SoC is in a partially thermally-throttled state. Re-running `bench.sh` on a warm system can produce numbers **~1.5–2× slower for the same binary** — a same-code bisect documented a 0.19 s → 0.35 s swing on identical commits between cool and warm states (60 s `sleep` between runs did not fully cool the system back down). The relative ordering of the tools stays stable, but absolute throughput is reproducible only from a near-idle system. See `CLAUDE.md` Rule 4.3 for the full investigation.

## Choosing a format

| Use case | Recommended |
|---|---|
| Sharing across platforms (Windows, Linux, older Macs) | **ZIP** (`knit zip --parallel`) |
| Apple-Silicon-to-Apple-Silicon transfers | **`.knit`** (`knit pack`) — faster encode/decode and smaller output than DEFLATE |
| Local backups, scratch archives, large dataset snapshots | **`.knit`** is the better default |
| Anything that needs to round-trip through `unzip`, browsers, CI tooling, or other archiving software | **ZIP** |

## Architecture

- **Swift 6** for orchestration and UI; **C** for speed-critical codecs
- **libdeflate** (vendored) — fastest single-threaded DEFLATE
- **zlib** (system) — chunk-parallel DEFLATE built on `Z_SYNC_FLUSH`
- **libzstd** (vendored) — core of `.knit`, designed for block parallelism
- **Metal compute** — `crc32_per_slice` for extract-side integrity, `byte_histogram` for compressibility analysis; both are runtime-compiled and dispatched through a single shared `MetalContext`
- **Pipelined GPU dispatch** — the entropy probe and (extract-side) CRC are kicked off on `DispatchQueue.global` *before* the worker fan-out, so the GPU compute overlaps with the CPU codec instead of stacking on top of it
- **Sharded analytics** — `StageAnalytics` / `LiteralTypeAnalytics` use 32 lock-striped shards (Knuth-multiplicative hash on `Thread.current`) so per-block instrumentation doesn't contend across 16 worker threads

```
Sources/
  KnitCore/          compression engine (Swift)
    Engine/
      Backends/       DeflateBackend / BlockBackend / EntropyProbing protocols + impls
                      MetalCRC32, MetalEntropyProbe, CPU equivalents
                      ZstdLiteralClassifier (RFC 8478 literal-section walker)
      Containers/     ZipWriter, KnitWriter, KnitReader, HybridZstdBatchDecoder
                      (with per-block CPU fallback + rolling-CRC verify)
      IO/             mmap, FileWalker (firmlink-safe path resolution via realpath(3))
      MetalKernels/   crc32_block.metal, entropy_probe.metal
      Telemetry/      StageAnalytics, LiteralTypeAnalytics (32-shard accumulators)
      Visualization/  CompressibilityHeatmap, HeatmapRenderer
      Progress/       ProgressReporter
  KnitCLI/           command-line entry point (`knit pack`, `unpack`, `zip`, …)
  CDeflate/          libdeflate (vendored)
  CZstd/             zstd (vendored)
  CZlibBridge/       thin C bridge to system zlib (Z_SYNC_FLUSH)

Scripts/
  fetch-vendor.sh         pull libdeflate / zstd sources
  bench.sh                synthetic-corpus benchmark harness (random/repeating/mixed)
  bench-corpora.sh        real-corpus --analyze runner (defaults to Tests/TestData/)
  build-quick-actions.sh  generate Finder Quick Actions
  install.sh              local install
  package-dmg.sh          DMG build + sign + notarize

.github/workflows/
  ci.yml                  release-mode build on macos-15 hosted runner
```

## Roadmap & known limitations

- **The codec runs on the CPU, intentionally.** We evaluated a full GPU zstd encoder and concluded the ROI is poor on Apple Silicon: libzstd already saturates available memory bandwidth at low levels, and high-level strategies (lazy / btopt) don't map onto SIMT. Knit's GPU pipeline focuses on classification, integrity, and visualization — work the GPU genuinely does better.
- **Pack on M5 Max is SSD-write-bound, not CPU-bound.** Benched against an 80 GB Windows VM image: encoder workers finish in ~3.7 s wall, `KnitWriter` drains to NVMe in ~20 s. Free CPU compute on this tier no longer translates to faster pack — moving a stage off the CPU would have to either fit the NVMe write budget (it already does) or shorten the write itself (NVMe controllers don't compress). This is the design target, not a regression to chase.
- **Adaptive hardware-aware routing is the next milestone.** A short calibration step (run once at install time and cached) measures the local CPU/GPU/SSD ratios so the right backend is picked automatically per machine — base M-series, Pro/Max-tier, fanless Air under sustained load, etc.
- **`.knit` is a custom container format.** It needs Knit (or a future port of the format) to decode. Tools like `unzip`, 7-Zip, the GNOME Archive Manager, etc. don't understand it. If you need broad interoperability, use ZIP.
- **Apple Silicon only.** The CLI is built for arm64 Macs running macOS 15 or later. Intel Macs are not supported and there are no plans to support them.
- **Not yet streaming on the writer side.** Both formats currently mmap their inputs; very-large directories are fine, but writers don't yet stream from arbitrary `Read` sources or stdin.

### Architecture decisions we ruled out

A few well-motivated GPU codec interventions were investigated and retired on bench data. Listed here so future contributors don't repeat the work without new data:

- **GPU Huffman literal decode (Phase 1b).** Plan was a Metal kernel decoding the `Huffman_4Stream` literal section of each `.knit` block in parallel, plugged into the existing `HybridZstdBatchDecoder.gpuPath` slot. The CPU-side classifier we shipped (`ZstdLiteralClassifier`) measures the kernel's blast radius: on the Windows VM corpus, **18 %** of literal-bearing bytes are `Compressed_4Stream`; on a github-like 4 GB tree, **49 %**. Both below the **70 %** threshold at which the kernel would justify its surface area and 10⁹-input differential-fuzz harness. libzstd emits 99.7 % of VM blocks as `Raw_Block` because the data doesn't compress — a perfect GPU Huffman decoder would touch ~25 MB of literals out of 85 GB of decode work. Re-open if a corpus surfaces where the gate passes; the classifier output is one `unpack --analyze` away.
- **Pack-side GPU CRC.** Plan was to replace the per-worker `libdeflate_crc32` call with a single per-batch `MetalCRC32` dispatch, pipelined behind worker compress. The kernel's per-dispatch overhead is **~80 ms on 35 MiB buffers** (M5 Max self-test reports 731 MB/s vs CPU libdeflate at 71 GB/s on the same size) — that's a 7× pack-time regression on the VM corpus. MetalCRC32 only beats libdeflate on very large single buffers (> 1 GiB), where dispatch cost amortises; it stays in use on the unpack-side post-extract verifier where that condition holds.

## Contributing

Issues and pull requests are welcome. If you're reporting a benchmark regression or a roundtrip integrity bug, please include:

- macOS version, chip (`sysctl -n machdep.cpu.brand_string`), and `swift --version`
- The exact `knit` command line and a minimal reproducer corpus (or its `find -ls` listing if it's not redistributable)
- Output of `knit info` and `knit metal-info`
- For visualization issues, the heatmap output (text paste or `--heatmap-image` PPM attachment)

For format-level changes to `.knit`, please open an issue first to discuss — the magic bytes / header layout are versioned (`KnitFormat.archiveVersion`) and breaking changes will get a new version tag.

## License

Knit is released under the **MIT License** — see [LICENSE](LICENSE) for the full text.

The project bundles or links against the following third-party components, each retained under its own license:

| Component | License | Role |
|---|---|---|
| [libdeflate](https://github.com/ebiggers/libdeflate) | MIT | fastest single-threaded DEFLATE |
| [zstd](https://github.com/facebook/zstd) | BSD-3-Clause / GPLv2 dual | core compressor for `.knit` |
| system zlib (macOS) | zlib license | `Z_SYNC_FLUSH` chunk-parallel DEFLATE |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 | CLI parsing |
