// Disk-space pre-flight check for `pack` and `zip` subcommands.
//
// Refuses an operation BEFORE any file work begins if the output
// destination doesn't plausibly have room for the result. Catches the
// concurrent-compression failure mode the user hit (PR #79): two
// Quick Actions on an 80 GB Parallels VM image — one to `.knit`, one
// to `.zip` — that raced for ~160 GB of disk space on a volume with
// less than that free. Pre-PR-#79 the codec would crawl most of the
// way through the write before catching `ENOSPC` at the
// `NSFileHandle.write` call site; the user saw a partial output file
// and a Foundation error string like "the file couldn't be saved
// because there isn't enough space". With this check the operation
// fails immediately with an actionable disk-space message — no
// half-written archive on disk.
//
// Single-file inputs are checked exactly (`stat` the input → compare
// against `statfs(.f_bavail × .f_bsize)` of the output directory).
// Directory inputs would require a recursive size walk that adds 1-2
// seconds on a 100 k-file tree before pack starts — annoying for the
// common case, and the codec catches ENOSPC mid-write anyway. We
// instead enforce a 1 GiB free-space floor for directory inputs:
// strict enough to reject "the disk is essentially full" cases
// (where ANY compression would fail), lax enough not to refuse a
// small directory pack on a near-full disk just because we can't
// cheaply estimate the output size.
//
// PR #79.

import Foundation
import ArgumentParser

enum DiskSpacePreflight {
    /// Reserved free-space margin in bytes. Required free space =
    /// estimated output size + this margin. The margin covers
    /// FS metadata overhead (extra extents per file in APFS, journal
    /// growth) and gives the user enough headroom that the disk
    /// isn't pushed to 100 % full even on the happy path.
    private static let safetyMarginBytes: UInt64 = 1 * 1024 * 1024 * 1024  // 1 GiB

    /// Minimum free-space floor enforced for directory inputs (where
    /// we don't cheaply know the input size). Below this, even a
    /// small archive build is likely to fail mid-write — refuse
    /// up-front.
    private static let directoryFreeSpaceFloor: UInt64 = 1 * 1024 * 1024 * 1024  // 1 GiB

    /// Run the pre-flight check. Throws `ValidationError` on failure
    /// (ArgumentParser surfaces these as a clean "Error: ..." line
    /// and a non-zero exit, with no stack trace).
    static func check(input inputURL: URL, output outputURL: URL) throws {
        let inputAttrs = try? FileManager.default.attributesOfItem(atPath: inputURL.path)
        let inputType = inputAttrs?[.type] as? FileAttributeType

        // Determine free space at the output destination's directory.
        // The output file itself doesn't exist yet, so we ask Foundation
        // about its parent. If the parent doesn't exist either, skip
        // the check — the codec's own `createDirectory` /
        // `createFile` path will surface a proper error.
        //
        // `volumeAvailableCapacityForImportantUsageKey` is the
        // Foundation-blessed equivalent of `statfs(.f_bavail × .f_bsize)`:
        // it returns bytes APFS reports as currently available to a
        // foreground user-initiated import (after accounting for purgeable
        // caches that the system can reclaim under pressure). This is the
        // most accurate "would my write fit?" number on macOS.
        let outputDir = outputURL.deletingLastPathComponent()
        let resourceValues = try? outputDir.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let availableInt = resourceValues?.volumeAvailableCapacityForImportantUsage else {
            // Can't determine free space (e.g., output dir doesn't exist
            // yet). Defer to downstream — the codec will fail cleanly
            // on ENOSPC if it really runs out.
            return
        }
        let freeBytes = UInt64(max(0, availableInt))

        // Directory inputs: enforce floor only.
        if inputType == .typeDirectory {
            if freeBytes < Self.directoryFreeSpaceFloor {
                throw ValidationError(
                    "Not enough free disk space at \(outputDir.path). " +
                    "Have \(Self.formatGB(freeBytes)) free; need at least " +
                    "\(Self.formatGB(Self.directoryFreeSpaceFloor)) before starting. " +
                    "Pass --no-disk-check to override (use only if you know the " +
                    "archive will be much smaller than the input)."
                )
            }
            return
        }

        // Single-file input: exact size comparison. Worst-case output
        // (incompressible input, e.g. a Parallels VM image) ≈ input
        // size; that's the conservative bound we use to refuse early.
        // For highly compressible inputs this can be too strict — the
        // CLI exposes `--no-disk-check` as an escape hatch.
        let inputSize = (inputAttrs?[.size] as? UInt64) ?? 0
        let required = inputSize + Self.safetyMarginBytes
        if freeBytes < required {
            throw ValidationError(
                "Insufficient free disk space at \(outputDir.path). " +
                "Input is \(Self.formatGB(inputSize)) (worst-case output ≈ input " +
                "for incompressible data); need ~\(Self.formatGB(required)) free, " +
                "have \(Self.formatGB(freeBytes)). Free up space, choose a " +
                "different output directory, or pass --no-disk-check to override " +
                "(use only if you know the archive will be much smaller — the " +
                "operation will still fail with ENOSPC if the disk actually fills " +
                "up mid-write)."
            )
        }
    }

    private static func formatGB(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 10 {
            return String(format: "%.1f GB", gb)
        } else if gb >= 0.1 {
            return String(format: "%.2f GB", gb)
        } else {
            let mb = Double(bytes) / 1_000_000
            return String(format: "%.1f MB", mb)
        }
    }
}
