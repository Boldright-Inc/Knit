// CrossInstanceLock — serializes operations across every Knit.app
// process running on the host. Built on `flock(2)`'s advisory locks.
//
// Why this exists
// ---------------
// `OperationCoordinator.pendingRuns` (PR #58) serialises subprocesses
// WITHIN one Knit.app instance. Quick Actions launch fresh instances
// via `open -n -a` (PR #57 / PR #58 rationale: prevent argv drops on
// reused instances), so firing two Quick Actions in rapid succession
// — say "Compress to .knit" and "Compress to .zip" on the same big
// file — spawns two Knit.app processes that run concurrently with no
// awareness of each other.
//
// User-reported failure on the 80 GB Parallels VM corpus (PR #79):
//
//   1. `knit pack` (Knit.app A): SIGKILL — kernel jetsam under
//      combined memory pressure. Each subprocess holds ~80 GB input
//      mmap plus output staging buffers; two of them together push
//      past the 128 GB RAM ceiling on M5 Max even with PR #76's
//      `MADV_DONTNEED` hint.
//   2. `knit zip`  (Knit.app B): exit status 1, ENOSPC mid-write.
//      Both subprocesses raced for ~80 GB of output each — destination
//      volume couldn't hold both archives.
//
// This lock makes cross-instance behaviour match within-instance: one
// subprocess at a time, host-wide. Each Knit.app's
// `OperationCoordinator` acquires before invoking `subprocess.run()`
// and releases on subprocess exit. The lock holder is the running
// `knit` subprocess's parent Knit.app; macOS automatically drops
// `flock`-held locks when the holding process exits (or crashes), so
// no stale-lockfile cleanup is needed.
//
// Why advisory locks (`flock`) not mandatory locks
// ------------------------------------------------
// macOS doesn't support mandatory file locks. `flock` is the standard
// cross-process coordination primitive on BSDs and macOS — used by
// `dpkg`, `apt-get`, `cron`, Homebrew's `brew update`, etc. Two
// concurrent waiters are serviced in FIFO order by the kernel.
//
// PR #79.

import Foundation
import Darwin

final class CrossInstanceLock: @unchecked Sendable {
    /// `O_RDWR | O_CREAT` lock file's fd, or -1 when not held / not
    /// yet opened. Accessed only from the methods on this object;
    /// `@unchecked Sendable` because mutation is gated by the
    /// `OperationCoordinator`'s single-flight-per-instance contract
    /// (only one acquire / release pair in flight at a time per
    /// `CrossInstanceLock`).
    private var fd: Int32 = -1
    private let path: String

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Knit")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        self.path = dir.appendingPathComponent("operation.lock").path
    }

    /// Try to acquire the lock without blocking. Returns `true` if
    /// acquired; `false` if another Knit.app is holding it.
    func tryAcquire() -> Bool {
        if !ensureOpened() { return false }
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    /// Block until either the lock is acquired or `cancelCheck()`
    /// returns true. Polls every 200 ms (low overhead — we only land
    /// here when another Knit.app is actually running) so the
    /// cancellation hook can interrupt the wait promptly.
    ///
    /// `progressCallback` is invoked once per second while waiting,
    /// receiving the elapsed seconds. Used by `OperationCoordinator`
    /// to tick the "Waiting for another Knit operation..." ETA in
    /// the ProgressWindow.
    func acquireBlocking(
        cancelCheck: () -> Bool,
        progressCallback: (TimeInterval) -> Void
    ) -> Bool {
        if !ensureOpened() { return false }
        let started = Date()
        var nextTick: TimeInterval = 1.0
        while !cancelCheck() {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return true
            }
            usleep(200_000)  // 200 ms — fine balance between
                              // responsiveness to cancellation and
                              // wasted wake-ups while waiting.
            let elapsed = Date().timeIntervalSince(started)
            if elapsed >= nextTick {
                progressCallback(elapsed)
                nextTick = elapsed.rounded(.down) + 1.0
            }
        }
        return false
    }

    /// Release the lock. Safe to call when the lock isn't held — it's
    /// a no-op. Idempotent.
    func release() {
        if fd >= 0 {
            _ = flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    /// Open the lock file lazily so failed `init` (rare; only on
    /// home-directory access denial) doesn't prevent the rest of
    /// Knit.app from running. A nil fd just means "can't coordinate
    /// — proceed without serialisation" rather than "refuse to do
    /// anything", which is the right fail-open behaviour for a
    /// best-effort coordination primitive.
    private func ensureOpened() -> Bool {
        if fd >= 0 { return true }
        fd = open(path, O_RDWR | O_CREAT, 0o644)
        return fd >= 0
    }

    deinit { release() }
}
