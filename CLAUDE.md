# CLAUDE.md

Guidance for Claude Code (and future contributors) working on this
repository. Captures the implementation rules and lessons that
emerged from PRs #14–#28; an extension of `README.md` aimed at
"things you have to know before changing code", not "things a user
needs to know to use the tool".

---

## Project mission

> Apple Silicon の余剰 GPU を圧縮 / 解凍に投入し、pack と unpack を
> I/O 限界まで押し上げる。

Concretely:

- The hardware is Apple Silicon (M-series). Unified memory architecture
  (UMA) is part of the design — GPU paths bytes-no-copy alias UMA pages,
  and "GPU does part of the work, CPU does the rest" patterns that would
  be uneconomic on PCIe are first-class here.
- The benchmark target is **NVMe write ceiling on the host's SSD**
  (~6–8 GB/s on M3 Max / M5 Max for sequential writes). Pack already
  hits this on short bursts; unpack is a separate work-stream.
- "Use the GPU" means specifically: measure where CPU spends time, then
  hand that stage off to a Metal kernel. Speculation about which stage
  to GPU-accelerate is not OK — see the `--analyze` discipline below.

---

## Architecture overview

```
                            knit pack
   File walker                    │
   (FileWalker)                   ▼
        │              ┌──────────────────────┐
        │              │  KnitCompressor      │  ← entry orchestrator
        │              │  • mixed-granularity │
        │              │    parallel: large   │
        │              │    entries serial,   │
        │              │    small entries     │
        │              │    batched           │
        │              └──────────┬───────────┘
        │                         ▼
        │              ┌──────────────────────┐
        │              │ StreamingBlock       │  ← per-block parallel
        │              │ Compressor           │     concurrentMap of
        │              │ • per-batch GPU      │     blocks
        │              │   entropy.probe      │
        │              │ • per-block CRC      │
        │              │ • per-block zstd     │
        │              └──────────┬───────────┘
        ▼                         ▼
   walk skip log            archive frames

                            knit unpack
   .knit reader                   │
   (KnitReader)                   ▼
        │              ┌──────────────────────┐
        │              │ KnitExtractor        │  ← entry orchestrator
        │              │  (currently serial — │     (parallel = next PR)
        │              │   per-entry overhead │
        │              │   is the bottleneck) │
        │              └──────────┬───────────┘
        │                         ▼
        │              ┌──────────────────────┐
        │              │ HybridZstdBatch      │  ← per-block parallel
        │              │ Decoder              │     concurrentMap of
        │              │ • staging + CRC      │     blocks; eager
        │              │   fold per batch     │     fallback machinery
        │              │ • optional GPU       │     for the future GPU
        │              │   plug-in slot       │     decoder
        │              └──────────┬───────────┘
        ▼                         ▼
   safe-path resolve         output files
```

Codec libraries:

- **zstd** (`CZstd`) — block compression / decompression. The `.knit`
  format is a sequence of independent zstd frames per block.
- **libdeflate** (`CDeflate`) — DEFLATE backend for ZIP path; arm64
  hardware CRC32 used for both pack and unpack CRC fold.
- **Apple Metal** — entropy probe, CRC32 verify (existing); future
  Huffman literal decode, full FSE decode, LZ77 match-search.

---

## Implementation rules

### 1. Swift 6 strict-concurrency

Two diagnostics have shipped to `main` and broken `package-dmg.sh`
release builds (PR #26, PR #28). Both slipped through `swift build`
(debug) because the strict-concurrency analyser doesn't run to
completion in debug mode. **Always build with
`swift build -c release` before shipping changes that introduce a
new `@Sendable` capture.**

#### Rule 1.1 — Never capture a `var` inside a `@Sendable` closure

```swift
// ❌ tripped #SendableClosureCaptures in PR #26
var batchStart = 0
while batchStart < n {
    let processed = try concurrentMap(batchIndices, ...) { idx in
        let entropy = perBlock[idx - batchStart]   // capture of var
        ...
    }
}

// ✅ snapshot to let immediately before the closure
var batchStart = 0
while batchStart < n {
    let batchBase = batchStart                     // immutable snapshot
    let processed = try concurrentMap(batchIndices, ...) { idx in
        let entropy = perBlock[idx - batchBase]
        ...
    }
}
```

The pattern: any `var` declared in an outer scope must be re-bound to
a `let` *immediately before* the `concurrentMap` call. Don't try to
reason about whether the `var` happens to be stable for the duration —
the compiler's strict-concurrency check rejects it regardless.

#### Rule 1.2 — Public `struct` types need explicit `: Sendable`

```swift
// ❌ Swift 6 does NOT auto-infer Sendable for public structs
public struct StreamingBlockCompressor {
    let backend: BlockBackend             // BlockBackend: Sendable
    let blockSize: Int
}
// captures from concurrentMap fail with #SendableClosureCaptures
// even though every field is already Sendable.

// ✅ declare it explicitly
public struct StreamingBlockCompressor: Sendable {
    ...
}
```

When adding a struct that:

1. is `public`, AND
2. will be captured by a `@Sendable` closure (e.g. used inside any
   `concurrentMap`, `Task`, or `DispatchQueue.async`),

the conformance must be declared explicitly. Inferred conformance only
works for non-`public` types; `public` types need it spelled out so
clients in other modules can rely on it.

The doc-block on the struct should explain *why* the conformance is
declared, so a future "remove dead annotations" sweep doesn't drop it.

#### Rule 1.3 — Lock-protected mutable shared state needs `@unchecked Sendable`

For state shared across worker threads (analytics accumulators,
progress reporters, heatmap recorders), the convention is:

```swift
public final class FooAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var state: [...] = []

    public func record(_ x: Foo) {
        lock.lock(); defer { lock.unlock() }
        state.append(x)
    }
}
```

`@unchecked` is correct because the safety property (single mutator at
a time) is enforced by the lock, not the type system. Always include a
doc-block comment that says so. Examples in the codebase:
`StageAnalytics`, `WalkSkipCollector`, `HeatmapRecorder`,
`ProgressReporter`.

### 2. String formatting (Swift × Foundation)

`String(format: "%@", swiftString)` and `String(format: "%-20s",
swiftString)` are **undefined behaviour** on Apple platforms. Both rely
on implicit `String → NSString` bridging that may produce a dangling
pointer mid-call. In debug / short-input runs the bridge usually
survives long enough for it to look like it works; in release / long
runs it segfaults.

PR #21 was a hotfix for exactly this — `unpack --analyze` segfaulted
at the very first stage row of an 80 GB unpack analyse on M5 Max,
zero bytes ever made it to stderr.

#### Rule 2.1 — Never pass a Swift `String` to `String(format:)`

| You want… | Use this | Not this |
|---|---|---|
| `"some text"` literal in output | string interpolation: `out += "label: \(value)"` | `String(format: "label: %@", value)` |
| Padded column | `value.padding(toLength: 20, withPad: " ", startingAt: 0)` | `String(format: "%-20s", value)` |
| Numeric format | `String(format: "%.2f", x)` (still safe — `%f` consumes `Double`) | unchanged |

`String(format:)` is fine for `%f`, `%d`, `%x`, `%c` — those consume
`Double`, `Int`, etc. (genuine numeric types). It's *not* fine for any
specifier that reads a pointer.

`Sources/KnitCLI/CLIAnalyze.swift` carries a long doc-block comment
restating this rule for the benefit of anyone touching the renderer.
Treat that file as the canonical pattern.

### 3. Memory & kernel safety

#### Rule 3.1 — Don't `Data(bytesNoCopy:..., deallocator: .none)` for large user buffers

PR #16 used this pattern to avoid memcpy when handing a 64 MiB staging
buffer to `outHandle.write(contentsOf:)`. Foundation's
`FileHandle.write(contentsOf: some DataProtocol)` for large `Data` can
internally use **vm_remap** to alias user pages into kernel buffers
("zero-copy" writes). Each remap adds VM mapping references to the same
physical pages. On the user's first 80 GB unpack (PR #17 hotfix), this
escalated until the per-task `cpt_mapcnt` overflow check tripped and
panicked the kernel:

```
panic(cpu 17): cpt_mapcnt_inc: refcnt overflow: rc 0xfffffde005de0178
               old_value 2050 value 2051
Compressor Info: 1% of compressed pages limit (OK) and 8% of
                 segments limit (OK) with 5 swapfiles
Panicked task pid 14438: knit, 4196192 pages, 21 threads
```

Use `Data(buffer:)` (which copies — fresh ARC-managed allocation) for
write paths. The ~3 s of memcpy across 80 GB on M5 Max is the safety
margin we trade for keeping user buffers and kernel buffers in
disjoint physical pages.

#### Rule 3.2 — F_NOCACHE on output FDs for sustained large writes

Same PR #17. Without it, the page cache holds dirty pages until the
kernel writeback flushes them. For sustained large writes the cache
can grow to ~50 % of RAM, on top of any read-side mmap; the system
engages its memory compressor; under high worker concurrency
`cpt_mapcnt` escalates as above. Setting `F_NOCACHE` makes writes go
straight to the NVMe controller's own DRAM cache:

```swift
_ = fcntl(outHandle.fileDescriptor, F_NOCACHE, 1)  // best-effort
```

Best-effort: a filesystem that doesn't support direct I/O simply
continues through the cached path. No worse than pre-fix.

### 4. Performance investigation discipline

This was the hard-won rule of the session. Three PRs (#15, #16, #17)
shipped speculative optimisations that delivered ~17 % speed-up on
the user's real workload while expecting 4×; some of them (#16)
introduced kernel panics. The pivot was: **stop optimising; build
observation tooling first.**

The result was the `--analyze` flag (PR #19, #22) and the rule below.

#### Rule 4.1 — Do not propose a perf optimisation without `--analyze` data

Before touching the codec, the `KnitCompressor`, the
`HybridZstdBatchDecoder`, or any other hot path:

1. Run `knit pack --analyze <corpus> 2> pack.txt`
2. Run `knit unpack --analyze <archive> 2> unpack.txt`
3. Read the per-stage breakdown.
4. Pick the dominant stage as the target.
5. Match the target to the next intervention from the table below.

Pack-side stage taxonomy:

| dominant stage | meaning | next intervention |
|---|---|---|
| `compute.entropy` | per-block histogram on CPU | wire `MetalEntropyProbe` (PR #23 done) |
| `compute.crc` | per-block libdeflate CRC | wire `MetalCRC32` into the worker pipeline |
| `compute.compress` | libzstd match-search | Phase 1a — GPU LZ77 match-search assist |
| `parallel.compress` wall ≈ encoder wall **and** CPU sums small | already SSD-bound | nothing to do; pack is at ceiling |
| `parallel.compress` wall ≪ encoder wall **and** entries ≫ blocks | too many tiny files, single worker | **entry-level parallelism** (PR #27 done) |

Unpack-side stage taxonomy:

| dominant stage | meaning | next intervention |
|---|---|---|
| `parallel.decode` | libzstd decode itself | Phase 1b — GPU Huffman literal decoder |
| `crc.fold` | per-batch libdeflate CRC fold | wire `MetalCRC32` into the decode batch |
| `sink` (write) | output write phase | double-buffered pipeline (decode N+1 while writing N) |
| `staging.alloc` | per-batch zero-fill of staging buffer | reuse one staging buffer across batches |
| stages sum ≪ total wall | per-entry FS overhead | **entry-level parallelism** (planned, "Open backlog" below) |

Key vocabulary:

- **Wall stages** sum toward `encoder wall` / `decoder wall`. They
  describe how the orchestrator's wall clock was spent.
- **Cumulative-CPU stages** (`compute.*` on encode) sum *across all
  workers* — they intentionally exceed wall time, because they
  measure the **total CPU work that GPU offload could absorb**.

Don't conflate them in the renderer. `CLIAnalyze.renderPack` keeps
them in separate sections for exactly this reason.

#### Rule 4.2 — Distinguish per-block-bound vs per-entry-bound workloads

Two completely different bottlenecks exist on small-file vs
large-file corpora:

- **Large-file workload** (e.g. 80 GB Windows-VM `.pvm.knit`,
  29 entries averaging ~3 GB each): bottleneck is per-block compute.
  Block-level parallelism matters; GPU-side codec offload matters.
  Per-entry overhead is irrelevant (29 entries total).
- **Small-file workload** (e.g. 9 GB github tree, 100 k entries
  averaging ~100 KB each): bottleneck is per-entry orchestration
  (mkdir, openFile, mmap, sync, verifyCRC). Block parallelism does
  nothing because there's only one block per entry. **Entry-level
  parallelism is the only lever.** GPU is irrelevant — every
  per-block compute already takes microseconds.

Don't reach for a GPU optimisation when the workload looks like the
second one.

### 5. Threading model conventions

#### Rule 5.1 — Use `concurrentMap` (in `Compressor.swift`) for parallel work

The codebase's parallel primitive is the `concurrentMap` helper:

```swift
let results: [U] = try concurrentMap(items, concurrency: N) { item in
    // @Sendable closure — pure transform, no mutable shared state
}
```

It dispatches up to `concurrency` tasks via GCD's global concurrent
queue, gathers results in input order, and rethrows the first error.
Existing call sites: `StreamingBlockCompressor` (per-block),
`KnitCompressor` (per-entry batch), `HybridZstdBatchDecoder`
(per-block), `CPUEntropyProbe` (per-block when ≥ 4 blocks).

Don't introduce parallel `Task { }` directly without strong reason —
the helper handles error propagation and result ordering for you.

#### Rule 5.2 — Mixed-granularity parallelism for mixed corpora

`KnitCompressor.compress` (PR #27) demonstrates the canonical pattern:

- **Large entries** (size ≥ `concurrency × 2 × blockSize`) take a
  serial streaming path: one entry at a time, with intra-entry
  block-level parallelism. Memory bound `O(concurrency × blockSize)`.
- **Small entries** are gathered into batches of
  `max(concurrency × 4, 8)` consecutive entries and compressed across
  workers in parallel via `concurrentMap`. Drained into the archive
  in input order so on-disk layout stays deterministic.

Memory bound for the small-entry batch: `batchSize × threshold` =
`concurrency² × 8 × blockSize` ≈ ~2 GiB worst-case on defaults.

Apply the same shape when adding parallelism to `KnitExtractor`
(planned). Don't unconditionally parallelise across entries — large
entries should still take the serial streaming path so memory stays
bounded for 100 GB+ single files.

#### Rule 5.3 — Don't nest `concurrentMap` at full concurrency

If both the outer and inner `concurrentMap` are dispatched at the
host's `activeProcessorCount`, you can end up with up to N² tasks
queued on GCD. The kernel will sort it out but it's wasteful. When
running an outer parallel loop that calls into a method which itself
parallelises, either:

- Pass `concurrency: 1` to the inner call when it makes sense.
- Or accept the over-subscription if the inner work is short-lived
  (`KnitCompressor.compress`'s parallel-batch path does this for the
  small-entry case; each inner `streamer.compress` has typically 1
  block per entry, so the inner concurrentMap dispatches 1 task and
  there's no real over-subscription).

### 6. CLI / UX conventions

#### Rule 6.1 — Default = least-surprising tar/zip behaviour

`FileWalker.enumerate` defaults to **including** hidden items
(`.git/`, `.DS_Store`, `.vscode/`, etc.) — matching `tar`, `zip`,
`ditto`, `7z`, Archive Utility. The previous default (excluded)
silently dropped 1.5 GB of `.git/` content on the user's `github`
folder; PR #24 fixed this. Pass `--exclude-hidden` to opt back into
the strict behaviour.

Symlinks are still skipped regardless: zip-slip via symlink
redirection + `.knit` v1 has no symlink record type. Lifting this
restriction is gated on a `.knit` v2 format change.

#### Rule 6.2 — `--analyze` is a hidden flag for diagnostics

Use `ArgumentHelp(visibility: .private)` so it doesn't show up in
`--help`:

```swift
@Flag(name: .customLong("analyze"),
      help: ArgumentHelp("Print decode-stage timing breakdown to stderr (internal).",
                         visibility: .private))
var analyze: Bool = false
```

When `--analyze` is set:

- Pack: construct `StageAnalytics()` + `WalkSkipCollector()`, thread
  through to `KnitCompressor.Options`.
- Unpack: construct `StageAnalytics()`, thread through to
  `KnitExtractor.analytics`.
- After the operation finishes, render the snapshot via
  `CLIAnalyze.renderPack` / `renderUnpack` and write to stderr.

The render output goes to **stderr**, not stdout, so the normal
`entries / out / time / verify` summary on stdout stays
machine-parsable.

#### Rule 6.3 — Progress bar default-on when stderr is a TTY

PR #18. `--progress` forces on (e.g. inside `tee`); `--no-progress`
forces off; default uses `isatty(stderr)`. Don't ship CLI subcommands
without the same treatment — interactive users expect feedback;
piped consumers don't want `\r`-overwriting noise in their logs.

---

## Testing requirements

### Round-trip is the strongest invariant

For any change that touches the encode or decode path, a round-trip
test (`pack` → `unpack`, byte-compare with original) is the highest-
leverage check. Existing fixtures: `KnitRoundTripTests`,
`StreamingPackTests`, `RoundtripTests`, `SecurityTests`. Add a new
fixture only if an existing one doesn't exercise the change.

### Differential vs reference for codec changes

When introducing a parallel path that has a serial fallback (e.g.
`CPUEntropyProbe` after PR #25), add a test that runs the same input
through both paths and asserts byte-identical results. Float
comparisons must be **bit-equal** when the math is the same;
`XCTAssertEqual(a, b, accuracy: ...)` masks bugs where the parallel
path took a slightly different code path.

### Fuzz-rate target

PRs that touch the codec correctness path (decoder, frame parser,
CRC fold) should run **≥ 10⁹ randomised inputs** before flag-flip.
The hybrid-decoder roadmap (Phase 1b GPU Huffman) has this
requirement baked into the planning doc; smaller per-PR targets
(10⁶ overnight) are fine for incremental work.

---

## PR / git workflow

### Always rebase before opening when the base PR has merged

If you're stacking on a not-yet-merged PR and the base merges first,
the stale base creates a confusing diff. Rebase onto current `main`
before opening (or if conflicts appear after another PR merges).

```sh
git fetch origin main
git rebase origin/main
git push --force-with-lease
```

Pattern: PR #20 was opened against a base branch that had the PR #16
content; #16 merged first; #20 became "delete every file added since
#16" and would have regressed `main` by 317 lines on merge. Closed
without merging; resolved by opening a fresh PR with rebase.

### PR description must include

- **What problem the PR solves** (one paragraph; cite the analyse
  data or user report that motivated it).
- **What changes** (table format if more than two files; one-liner
  per file for small PRs).
- **Predicted impact** (quantified: "X GB/s before → Y GB/s after").
- **Verification commands** the reviewer can run.
- **Out of scope** (so future PRs don't get blocked on this one).

The trailing `https://claude.ai/code/session_018j5qnomGpYdJvw1tJbkkB3`
URL is auto-appended by the harness — leave it.

### Commit message style

Conventional-commit-flavoured prefix (`feat`, `fix`, `perf`,
`refactor`, `test`, `chore`, `doc`); short subject line; long body
with the "why" rather than the "what". The PR description and the
commit message body are both read by humans — don't make them say
exactly the same thing; commit body for "code archaeology in 6
months", PR description for "review me now".

---

## Recent landed work (PRs #29–#39)

Complements the rule sections above with the narrative of what
shipped *after* CLAUDE.md was first written. Read here for "why is
the codebase like this"; read the rules above for "what to do
about it".

| PR | Title | What it taught / what landed |
|---|---|---|
| #29, #30 | docs: add CLAUDE.md | This document |
| #31, #32 | unpack entry-level parallelism + regression fix | Mirroring PR #27's mixed-granularity pattern on the unpack side initially regressed by 16 s — APFS directory b-tree contention from 16-way `createFile` on same parent dir. Fix: serial pre-create of parent directories before parallel extract; `concurrency=1` fast-path inside `concurrentMap` |
| #33 | skip per-entry fsync + skip entropy probe for tiny batches | Foundation's `FileHandle.close()` already syncs metadata; explicit `fsync()` was redundant. Tiny batches (< `MetalEntropyProbe.minBufferForGPU`) skip probe altogether — synthesise zero entropy |
| #34, #35 | shard StageAnalytics across 32 stripes | Single NSLock in `StageAnalytics.record()` was contended across 16 workers; `compute.crc` measurement inflated 12×. Fix: 32 shards selected by Knuth multiplicative hash. Critically, use the *high bits* of the hash — low bits are zero for object-pointer-derived hashes |
| #36, #37 | adaptive probe-skip lock for incompressible big files **(reverted)** | Removing the per-batch ~18 ms probe wall accidentally also removed the thermal "settling" pacing — M5 Max throttled, GCD oversubscribed. 37 % pack regression on VM, 49 % on GitHub. Reverted; replaced by PR #38's pipelining approach |
| #38 | pipeline entropy probe with worker compress | Per-batch probe dispatched on `DispatchQueue.global` *before* workers start the current batch — async resolve via `ProbeFuture` (DispatchSemaphore + NSLock). Workers still consume entropy from `EntropyResult` arrays; probe wall hides behind worker work |
| #39 | chunk pipelined probe into ~256 MiB | One GPU dispatch per ~8 batches instead of per batch; 2 291 dispatches × 18 ms → ~320 dispatches × 30 ms. Bootstrap-resolves chunk 0; thereafter chunks resolve at transitions with the worker-loop wall already covering the dispatch wall |

## Current bench reference (M5 Max, post-PR-#39, 2026-05-10)

The reference walls we're working against. Use `--analyze` to refresh
after every codec/orchestrator change. Numbers ≠ baselines if they
came from a different build of `main`.

**Pack — 80 GB Windows-VM `.pvm.knit`** (29 entries, ratio 99.7 %):
- total: 74.3 s — encoder wall 74.3 s
- stage wall: entropy.probe 0.2 s, parallel.compress 65.5 s, archive.write 8.5 s
- cumulative CPU: **compute.crc 1141.7 s (498 ms/batch)**, compute.compress 15.8 s
- **next lever per Rule 4.1**: wire `MetalCRC32` into the per-block worker pipeline

**Pack — 9 GB GitHub folder** (100 817 small files):
- total: 10.6 s, batches 89 653, avg 0.1 MiB, ratio 83.1 %
- stage wall: entropy.probe 7.0 s, parallel.compress 15.3 s, archive.write 0.4 s
- cumulative CPU: compute.crc 31.7 s, compute.compress 5.9 s
- bottleneck: per-entry FS overhead; further wins require batched CRC dispatch and/or `KnitWriter` syscall reduction

**Unpack — 80 GB VM**: total 101.8 s; parallel.decode 61.2 s (47 ms/batch); sink 7.8 s
**Unpack — 9 GB GitHub**: total 19.2 s; parallel.decode 2.1 s; sink 6.3 s — sink-bound

Raw analyze output is reproducible from `Tests/Benchmarks/data/external/`
(see "Bench corpus directory convention" below).

## Phase 1b — GPU Huffman literal decode (next major phase)

Detail-heavy section so a fresh agent can pick this up cold.

### Why this is "next"

Unpack-side, `parallel.decode` is the dominant stage on every
corpus large enough to be GPU-relevant: 61 s on the 80 GB VM,
30 % of the GitHub-corpus decoder wall. Per Rule 4.1 the
intervention is "GPU Huffman literal decoder".

Pack-side, the dominant lever is `MetalCRC32` (see bench
reference above). The Huffman work below is the larger /
higher-impact piece, but a pack-side GPU CRC PR is a natural
smaller stepping stone if Phase 1b risk feels too large
upfront. Either order is fine; Phase 1b *first* gives the next
agent a chance to validate the differential-fuzz harness
against a smaller surface before scaling it to Phase 2.

### Goal

Decode the **Huffman_4Stream literal section** of each `.knit`
zstd block in parallel on Metal; hand the decoded literals back
to the CPU for sequence execution; produce bit-identical output
to `ZSTD_decompress`. Target on the VM unpack:
~0.83 GB/s → ≥ 2.5 GB/s on M3 Max; ≥ 3.5 GB/s on M5 Max.

### Codec scope

In-scope literal block types:
- `Compressed_Literals_Block` with `Huffman_4Stream` (the
  common case for ≥ 256-byte literal sections)

Out-of-scope (fall back to CPU; track rate as a metric):
- `Compressed_1Stream` (single-stream Huffman — parallelism is
  per-symbol-bitstream, harder; Phase 2 candidate)
- `Raw_Literals_Block`, `RLE_Literals_Block` — no compression
  work to offload
- `Treeless_Literals_Block` — uses repeat table; tractable but
  ordering constraints across blocks add bookkeeping. Defer
- FSE/sequence decoding — Phase 2

### File layout to add

```
Sources/KnitCore/Engine/MetalKernels/
    zstd_huffman_decode.metal        ← per-stream Huffman bit reader
    zstd_block_parse.metal           ← (optional, stretch) GPU-side parse
Sources/KnitCore/Engine/Backends/
    MetalZstdLiteralDecoder.swift    ← BlockDecoding conformer
    MetalZstdContext.swift           ← persistent buffers + pipeline
Tests/KnitCoreTests/
    HybridZstdDecodeTests.swift      ← differential vs ZSTD_decompress
    HybridZstdDecodeFuzzTests.swift  ← bit-flip + property fuzz
    HuffmanLiteralFallbackTests.swift ← exercises non-4Stream paths
```

The existing `HybridZstdBatchDecoder` already has a `gpuPath:
BlockDecoding?` slot (see file header doc). The new decoder
plugs in there; the orchestration / safety wrapper does not
change.

### Architecture (concrete)

For each batch of N blocks (input to `MetalZstdLiteralDecoder.decodeBlock`):

1. **CPU pre-parse** (≤ 50 µs target per block): walk each zstd
   frame header to (a) sniff `Literals_Section_Header` and
   classify, (b) extract Huffman tree description offset/length,
   (c) record the four stream offsets relative to the literal
   section start, (d) record `regenerated_size`. Blocks that
   classify as out-of-scope are short-circuited to the CPU path
   (`cpuPath.decodeBlock(...)`).
2. **CPU → GPU staging** (per batch, not per block): build a
   contiguous MTLBuffer containing every in-scope block's
   literal section. For page-aligned, mmap-backed inputs use
   `bytesNoCopy:` (see `MetalCRC32` for the exact aliasing
   pattern; same Rule 3.1 caveats apply). Build a parallel
   table of per-block descriptors (offsets, sizes, Huffman tree
   pointer).
3. **GPU dispatch** — one threadgroup per block, 4 threads per
   threadgroup, one thread per stream. Each thread decodes its
   stream by walking the Huffman codes from its bitstream tail
   forward. Output is written to a contiguous per-batch literal
   buffer at the block's pre-computed slot. **Defensive bounds
   checks every write** (output buffer length vs `regenerated_size`).
4. **CPU sequence execution**: for each in-scope block, run the
   FSE+sequence stage of libzstd using the GPU-decoded literals
   as input. **Implementation note**: there is no public libzstd
   API to inject pre-decoded literals. Easiest correct path:
   re-decode the entire frame on CPU into a separate buffer and
   `memcmp` against the GPU literal output (= per-block
   correctness oracle); on mismatch route the block through the
   CPU fallback. This sacrifices 50 % of the literal-decode
   wall-time gain but is the safest first step. A
   skip-the-oracle optimisation is a later PR once the GPU path
   is trusted (months of TestFlight time).
5. **Per-batch CRC fold and commit** — unchanged from existing
   `HybridZstdBatchDecoder.decodeBatch` flow.

### Safety contract (mandatory on day one)

All of these already exist in `HybridZstdBatchDecoder` as the
orchestration layer; the new decoder must respect them:

- `MetalContext()` returns nil → silently fall back to CPU.
  Construct the decoder with `MetalZstdLiteralDecoder(...)? = nil`
  and route everything through `cpuPath`.
- **Eager pipeline compile at construction** — never first-dispatch
  surprise. If `makePipeline("zstd_huffman_decode")` throws, the
  factory returns nil and `HybridZstdBatchDecoder` constructs
  with `gpuPath: nil`.
- **Per-block CPU fallback** is already wired in
  `parallelDecodeBlocks(... perBlockFallback:)`; any GPU throw
  routes that single block to CPU without poisoning the batch.
- **Whole-batch CPU fallback** on the rare case of a non-block-
  scoped error.
- **Bounds-check assertions on every kernel write** stay on in
  debug + TestFlight.
- **Watchdog adaptive batch size** is already there; new decoder
  inherits it.
- **Differential vs libzstd** is the *correctness oracle* for
  Phase 1b (see step 4 above).

### Performance budget

| Stage | Target | Why |
|---|---|---|
| CPU pre-parse | ≤ 50 µs/block | Otherwise the CPU parse becomes the serial bottleneck — defeats the purpose |
| GPU dispatch | 30–60 ms/batch (64 blocks × ~64 MiB literals) | One commit per batch; aim to hide behind the previous batch's CPU sequence-execute work |
| Per-block fallback rate | ≤ 15 % on Silesia/enwik9/VM | > 30 % means the in-scope classifier is wrong |
| End-to-end unpack wall (M5 Max VM) | 102 s → ≤ 50 s | Halving the dominant stage; rest is sink-write and per-entry overhead |

### Differential fuzz harness (must be automated end-to-end)

The local agent runs the test suite itself; no manual
intervention should be needed. Targets:

```
swift test --filter HybridZstdDecodeTests              # ~30 s
swift test --filter HybridZstdDecodeFuzzTests          # ~10 min (1e5 inputs)
./Scripts/diff-fuzz-decode.sh 1e6                      # ~1 hour (1e6 inputs)
./Scripts/diff-fuzz-decode.sh 1e9                      # overnight (1e9 inputs)
./Scripts/bench-corpora.sh                             # corpus replay (see below)
```

Fuzz assertion: for any input byte sequence the CPU
`ZSTD_decompress` accepts, the hybrid path either produces
byte-identical output **or** throws cleanly and falls back to
CPU (the orchestrator's existing mechanism produces correct
output regardless). Track fallback rate as a metric; reject
fuzz inputs that fall back > 50 % (suggests the test corpus
isn't exercising the GPU path).

10⁹ inputs is the same scale as nvCOMP's pre-release; see the
codec roadmap plan (`/root/.claude/plans/...puffin.md`) for the
reasoning.

## Bench corpus directory convention

The local agent has real input data. Standard locations:

```
Tests/Benchmarks/data/external/      ← real-world inputs; gitignored
    github/                          ← real GitHub repo checkout (~9 GB, 100k files)
    pvm/                             ← Windows VM .pvm files (~80 GB, 29 files)
    silesia/                         ← Silesia benchmark suite (~210 MB)
    enwik9                           ← Wikipedia text corpus (~1 GB)
```

The local agent has read access to these. They are
**gitignored** (large + non-redistributable); do not check them
in. Bench scripts source from this directory:

- `./Scripts/bench-corpora.sh` — pack and unpack each subdirectory
  with `--analyze`, dump stage breakdowns to
  `Tests/Benchmarks/results/<timestamp>/`. If this script does
  not exist yet, the next agent's first concrete task is to
  write it — convention above is the canonical layout.
- `./Scripts/diff-fuzz-decode.sh <iterations>` — Phase 1b
  differential fuzzer. Same shape: source data from
  `data/external/`, write fuzz seeds to
  `Tests/Benchmarks/results/fuzz/<timestamp>/`.

Reference results from before any Phase 1b work are in
`Tests/Benchmarks/results/baseline-2026-05-10.tsv` (or will be
once the next agent runs `bench-corpora.sh` on post-#39 main —
the analyze numbers in the "Current bench reference" section
above are the expected output).

## Open backlog

Tracked in PR descriptions; consolidated here for ease of
prioritisation. Most-recent first.

| Item | Why | Sketch |
|---|---|---|
| **Phase 1b — GPU Huffman literal decode** | see "Phase 1b" section above; dominant unpack lever (61 s of 102 s on VM) | MSL kernel, plug into `HybridZstdBatchDecoder.gpuPath` |
| **Pack-side GPU CRC** | `compute.crc` is 1141 s cumulative on VM pack (Rule 4.1 next intervention for the pack side). `MetalCRC32` exists but is not wired into the per-block worker pipeline | replace `libdeflate_crc32` call in `StreamingBlockCompressor` worker with a batched MetalCRC32 path; falls back to CPU when `MetalContext()` is nil |
| **CI release-mode build** | PRs #26 and #28 both broke `package-dmg.sh` because debug `swift build` didn't run strict-concurrency to completion | add `swift build -c release` + `swift test -c release` jobs to CI |
| **Atomic-on-success commit for `unpack`** | Streaming write + final-CRC mismatch leaves a partial output file on disk | write to `.tmp`, rename on CRC pass |
| **Per-block CRCs in `.knit` v2** | Allows per-batch verify-before-commit instead of end-of-entry only | format version bump |
| **Symlink preservation** | Currently always skipped; tar/zip preserve them | `.knit` v2 entry type, plus `--preserve-symlinks` flag |
| **Heatmap interleave on parallel-entry path** | When `KnitCompressor` runs entries in parallel, heatmap samples interleave non-deterministically | thread per-task `HeatmapRecorder`s, drain in order |
| **Decoder per-entry wall analytics bug** | `StageAnalytics.startWallClock()` is called per-entry, which overwrites earlier starts; analyse shows `decoder wall: 0.022 s` while stage sums are 4 s | accumulate or only set first |

---

## Out-of-scope reminders

- The `.knit` format hasn't changed. Any new on-disk layout requires
  a deliberate v2 bump and migration plan. Don't introduce one
  inside an unrelated PR.
- This is a macOS-only tool. Don't add Linux-portability conditional
  compilation unless explicitly asked — the codebase relies on
  `mmap`, `fcntl(F_NOCACHE)`, Foundation-on-Darwin, Metal, etc.
- Tests run on Apple Silicon. Don't add tests that assume specific
  CPU core counts or memory sizes; use
  `ProcessInfo.processInfo.activeProcessorCount` and
  `MTLDevice.maxBufferLength` consistently.
