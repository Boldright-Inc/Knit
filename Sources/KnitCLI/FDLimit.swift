// FDLimit — raise the process's open-file-descriptor soft limit at
// startup so the codec doesn't trip `EMFILE` on workloads with many
// small files (e.g. packing a git repo with ~50 k objects under
// `.git/objects/`).
//
// macOS launches user processes with `RLIMIT_NOFILE.rlim_cur = 256`
// by default. That's enough for shells, GUI apps, and most ordinary
// utilities, but it's an obstacle for a codec that fans out file
// opens across `concurrentMap` workers AND, post-PR-#70, keeps a
// `MappedFile` (= open fd) alive for each `.stored` entry until the
// write phase consumes it. PR #80's `storedStreamingThreshold`
// change drops the small-file FD multiplier; this file is the
// belt-and-braces second layer that catches the edge case where
// many >4 MiB `.stored` entries still build up.
//
// The macOS hard limit (`rlim_max`) is typically much higher (often
// `OPEN_MAX = 10240` or larger; `kern.maxfilesperproc` can be
// queried for the true cap). We try to raise the soft limit to the
// hard limit, capped at 65 536 to leave headroom for the rest of
// the system. Non-root processes can do this without privilege
// escalation.
//
// PR #80.

import Foundation
import Darwin

enum FDLimit {
    /// Raise the soft FD limit toward the hard limit. Best-effort:
    /// any failure (rare; only if `getrlimit` itself fails) is
    /// silently ignored, leaving the inherited limit in place. The
    /// codec still works at the original 256 for most workloads.
    static func raiseToMax(target: rlim_t = 65_536) {
        var current = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &current) == 0 else { return }
        // Cap at the kernel hard limit. Setting `rlim_cur > rlim_max`
        // is `EINVAL`.
        let newSoft = min(current.rlim_max, target)
        guard newSoft > current.rlim_cur else { return }
        var updated = current
        updated.rlim_cur = newSoft
        _ = setrlimit(RLIMIT_NOFILE, &updated)
    }
}
