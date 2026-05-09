# Knit

A high-speed compression tool for Apple Silicon. In addition to multi-threaded standard ZIP, Knit supports `.knit`, an internal-only format optimized for speed. Right-click integration with Finder is included.

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
| Sharing with other Macs / Windows / Linux | **ZIP** (`knit zip --parallel`) |
| Sharing among internal Apple Silicon Macs | **`.knit`** (`knit pack`) — faster and smaller than standard ZIP |
| Personal backups | **`.knit`** is fine |

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

## License

- Knit: internal use only (Boldright Inc.)
- libdeflate: MIT
- zstd: BSD / GPL dual
- system zlib: zlib license
