# Knit

> Fast, modern file compression for Apple Silicon.

Knit is a compression utility built natively for Apple Silicon Macs (M-series). It pairs a standard ZIP encoder with a custom `.knit` archive format, both driven by a multi-threaded compression engine designed to saturate the M-series memory subsystem and modern NVMe storage — fast enough that the bottleneck shifts from the CPU back to your disk.

When interoperability matters, `knit zip` produces fully spec-compliant ZIP archives — including ZIP64 for files beyond 4 GB — that open with any standard unzip implementation on any platform. When you want the absolute best throughput, `knit pack` writes a `.knit` container: each entry is split into independent zstd frames, allowing the encoder to fan out across every core and the decoder to support random-access seeking into any block. Single huge files (10 GB+) compress in parallel via a pigz-style chunked DEFLATE strategy that emits one valid stream while still keeping all cores busy.

In benchmarks on a 1 GB mixed corpus (M5 Max), Knit is up to **~50× faster** than macOS's built-in `ditto` / Archive Utility for `.knit` output, and roughly **~10× faster** than `pigz` for standard ZIP — at equal or better compression ratios. The numbers reproduce with the included `Scripts/bench.sh` harness.

Right-click integration is included: installing Knit adds three Finder Quick Actions — *Knit Compress (ZIP)*, *Knit Compress (.knit)*, and *Knit Extract* — that wrap the CLI for day-to-day use. Under the hood, the engine is built on **libdeflate** for single-threaded DEFLATE, **system zlib** for `Z_SYNC_FLUSH`-based chunk-parallel ZIP, **libzstd** for `.knit`, and a **Metal compute pipeline** that today accelerates CRC32, with a full GPU zstd block encoder on the roadmap.

## Highlights

- 🚀 **Apple Silicon native** — arm64-only binary, tuned for unified memory and high-bandwidth interconnect
- 📦 **Two formats, one tool**
  - **ZIP** — fully standard, ZIP64-capable, interoperable everywhere
  - **`.knit`** — block-parallel zstd container, faster and smaller than DEFLATE at equivalent compression levels
- ⚡ **Up to ~50× faster** than macOS Archive Utility, **~10× faster** than `pigz`
- 🧵 **Single-file parallelism** via zlib `Z_SYNC_FLUSH` stitching — one logical DEFLATE stream, full multi-core utilization
- 🖱 **Finder right-click integration** through macOS Quick Actions
- 🎮 **Metal compute scaffolding** with working GPU CRC32; full GPU zstd encoder coming
- 🔐 **Distribution-ready** — Developer ID code signing and Apple notarization wired into the packaging script

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

# Tests
swift test

# Install Finder right-click menu items + /usr/local/bin/knit
./Scripts/install.sh        # asks for sudo password

# Build a redistributable DMG (for internal distribution)
DEVELOPER_ID="Developer ID Application: Boldright Inc. (TEAMID)" \
NOTARY_PROFILE=knit-notary \
./Scripts/package-dmg.sh
```

After running `install.sh`, right-click any file or folder in Finder to find these entries under **Quick Actions**:

- **Knit Compress (ZIP)** — produces a standard `.zip` (extractable anywhere)
- **Knit Compress (.knit)** — produces the internal high-speed `.knit` format
- **Knit Extract** — auto-detects `.zip` or `.knit` and extracts

## CLI

```bash
knit info                          # environment + library versions
knit metal-info                    # Metal device probe + GPU CRC32 self-test
knit zip <input> [-o out.zip] [--level 6] [--parallel] [--chunk-kb 1024]
knit pack <input> [-o out.knit] [--level 3] [--block-kb 1024]
knit unpack <archive> [-o output_dir]
```

Add `--parallel` to use the pigz-style chunk-parallel ZIP backend. This is the path to use for a single very large file.

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

**Extrapolated to 50 GB: 6–10 minutes drops to roughly 6 seconds with `.knit`** — though in practice the 5–7 GB/s NVMe SSD I/O ceiling becomes the real upper bound.

Reproduce with `./Scripts/bench.sh [size_mb=1024]`.

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
- **Metal compute shaders** — currently used for parallel CRC32; full zstd block compression on GPU is on the roadmap

```
Sources/
  KnitCore/         compression engine (Swift)
    Engine/
      Backends/      DeflateBackend / BlockBackend protocols + impls
      Containers/    ZipWriter, KnitWriter, KnitReader
      IO/            mmap, FileWalker
      MetalKernels/  *.metal compute shaders
  KnitCLI/          command-line entry point
  CDeflate/          libdeflate (vendored)
  CZstd/             zstd (vendored)
  CZlibBridge/       thin C bridge to system zlib (Z_SYNC_FLUSH)
Scripts/
  fetch-vendor.sh         pull libdeflate / zstd sources
  bench.sh                automated benchmark harness
  build-quick-actions.sh  generate Finder Quick Actions
  install.sh              local install
  package-dmg.sh          DMG build + sign + notarize
```

## Roadmap & known limitations

- **Full GPU compression is on the way, not in yet.** The Metal compute pipeline is wired end-to-end and currently accelerates CRC32; the bulk of compression still runs on the CPU. A block-parallel zstd encoder in MSL is the next major milestone — see the TODO comment in `Sources/KnitCore/Engine/MetalKernels/crc32_block.metal`.
- **`.knit` is a custom container format.** It needs Knit (or a future port of the format) to decode. Tools like `unzip`, 7-Zip, the GNOME Archive Manager, etc. don't understand it. If you need broad interoperability, use ZIP.
- **Apple Silicon only.** The CLI is built for arm64 Macs running macOS 15 or later. Intel Macs are not supported and there are no plans to support them.
- **Not yet streaming on the writer side.** Both formats currently mmap their inputs; very-large directories are fine, but writers don't yet stream from arbitrary `Read` sources or stdin.

## Contributing

Issues and pull requests are welcome. If you're reporting a benchmark regression or a roundtrip integrity bug, please include:

- macOS version, chip (`sysctl -n machdep.cpu.brand_string`), and `swift --version`
- The exact `knit` command line and a minimal reproducer corpus (or its `find -ls` listing if it's not redistributable)
- Output of `knit info` and `knit metal-info`

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
