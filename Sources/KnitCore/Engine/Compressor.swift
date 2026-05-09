import Foundation

public struct CompressionStats: Sendable {
    public let entriesWritten: Int
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public let elapsed: TimeInterval

    public var inputThroughputMBPerSec: Double {
        guard elapsed > 0 else { return 0 }
        return Double(bytesIn) / 1_000_000.0 / elapsed
    }

    public var ratio: Double {
        guard bytesIn > 0 else { return 0 }
        return Double(bytesOut) / Double(bytesIn)
    }
}

/// High-level compression orchestrator. Reads files, fans out to a backend,
/// writes results into a streaming `ZipWriter`.
public final class ZipCompressor: Sendable {

    public struct Options: Sendable {
        public var level: CompressionLevel
        /// Maximum concurrent compression jobs. Defaults to physical core count.
        public var concurrency: Int
        /// Files smaller than this are compressed inline; larger files are
        /// memory-mapped before compression.
        public var mmapThreshold: Int

        public init(level: CompressionLevel = .default,
                    concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
                    mmapThreshold: Int = 4 * 1024 * 1024) {
            self.level = level
            self.concurrency = max(1, concurrency)
            self.mmapThreshold = mmapThreshold
        }
    }

    private let backend: DeflateBackend
    private let crc: CRC32Computing
    private let options: Options

    public init(backend: DeflateBackend & CRC32Computing, options: Options = Options()) {
        self.backend = backend
        self.crc = backend
        self.options = options
    }

    /// Compress every entry under `input` (file or directory) into a ZIP at `output`.
    public func compress(input: URL, to output: URL) throws -> CompressionStats {
        let entries = try FileWalker.enumerate(input)
        let writer = try ZipWriter(url: output)

        let start = ContinuousClock.now
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0

        // Stage 1: concurrently produce per-entry compressed payloads.
        // Stage 2: write to ZIP serially in walk order.
        let prepared: [PreparedEntry] = try concurrentMap(
            entries,
            concurrency: options.concurrency
        ) { entry in
            try self.prepare(entry: entry)
        }

        for p in prepared {
            try writer.writeEntry(
                descriptor: p.descriptor,
                method: p.method,
                crc32: p.crc,
                uncompressedSize: p.uncompressedSize,
                payload: p.payload
            )
            bytesIn  += p.uncompressedSize
            bytesOut += UInt64(p.payload.count)
        }

        try writer.close()
        let elapsed = ContinuousClock.now - start

        return CompressionStats(
            entriesWritten: prepared.count,
            bytesIn: bytesIn,
            bytesOut: bytesOut,
            elapsed: elapsed.timeIntervalSeconds
        )
    }

    // MARK: - Per-entry preparation

    fileprivate struct PreparedEntry: Sendable {
        let descriptor: ZipWriter.EntryDescriptor
        let method: CompressionMethod
        let crc: UInt32
        let uncompressedSize: UInt64
        let payload: Data
    }

    private static func dataFromBuffer(_ buf: UnsafeBufferPointer<UInt8>) -> Data {
        guard let base = buf.baseAddress, buf.count > 0 else { return Data() }
        return Data(bytes: base, count: buf.count)
    }

    private func prepare(entry: FileEntry) throws -> PreparedEntry {
        let descriptor = ZipWriter.EntryDescriptor(
            name: entry.relativePath,
            modificationDate: entry.modificationDate,
            unixMode: entry.unixMode,
            isDirectory: entry.isDirectory
        )

        if entry.isDirectory {
            return PreparedEntry(
                descriptor: descriptor,
                method: .stored,
                crc: 0,
                uncompressedSize: 0,
                payload: Data()
            )
        }

        let mapped = try MappedFile(url: entry.absoluteURL)
        let buf = mapped.buffer

        // Decide method: store if data is small, incompressible (heuristic on
        // try-then-fallback) or level == 0.
        if options.level.raw == 0 || buf.count == 0 {
            let crcVal = buf.count == 0 ? 0 : crc.crc32(buf, seed: 0)
            return PreparedEntry(
                descriptor: descriptor,
                method: .stored,
                crc: crcVal,
                uncompressedSize: UInt64(buf.count),
                payload: Self.dataFromBuffer(buf)
            )
        }

        let compressed = try backend.compress(buf, level: options.level.clampedForDeflate())
        let crcVal = crc.crc32(buf, seed: 0)

        // If compression made it larger, store uncompressed instead (ZIP spec encourages this).
        if compressed.count >= buf.count {
            return PreparedEntry(
                descriptor: descriptor,
                method: .stored,
                crc: crcVal,
                uncompressedSize: UInt64(buf.count),
                payload: Self.dataFromBuffer(buf)
            )
        }

        return PreparedEntry(
            descriptor: descriptor,
            method: .deflate,
            crc: crcVal,
            uncompressedSize: UInt64(buf.count),
            payload: compressed
        )
    }
}

// MARK: - Concurrent map helper

private final class ConcurrentMapState<V: Sendable>: @unchecked Sendable {
    var results: [V?]
    var firstError: Error?
    let lock = NSLock()
    init(count: Int) { self.results = Array(repeating: nil, count: count) }
}

/// Apply `transform` to each element of `items` using a concurrent dispatch
/// queue, preserving input order in the result. Throws the first error seen.
func concurrentMap<T: Sendable, U: Sendable>(
    _ items: [T],
    concurrency: Int,
    _ transform: @escaping @Sendable (T) throws -> U
) throws -> [U] {
    if items.isEmpty { return [] }
    let state = ConcurrentMapState<U>(count: items.count)
    let queue = DispatchQueue(label: "co.boldright.knit.concurrent",
                              attributes: .concurrent)
    let semaphore = DispatchSemaphore(value: concurrency)
    let group = DispatchGroup()

    for (idx, item) in items.enumerated() {
        semaphore.wait()
        state.lock.lock()
        let stop = state.firstError != nil
        state.lock.unlock()
        if stop {
            semaphore.signal()
            break
        }
        group.enter()
        queue.async {
            defer {
                semaphore.signal()
                group.leave()
            }
            do {
                let value = try transform(item)
                state.lock.lock(); state.results[idx] = value; state.lock.unlock()
            } catch {
                state.lock.lock()
                if state.firstError == nil { state.firstError = error }
                state.lock.unlock()
            }
        }
    }
    group.wait()
    if let e = state.firstError { throw e }
    return state.results.compactMap { $0 }
}

// MARK: - Helpers

extension Duration {
    public var timeIntervalSeconds: TimeInterval {
        let (sec, atto) = self.components
        return Double(sec) + Double(atto) / 1.0e18
    }
}
