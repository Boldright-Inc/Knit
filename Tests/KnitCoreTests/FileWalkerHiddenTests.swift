import XCTest
@testable import KnitCore

/// Verifies the `FileWalker.enumerate` semantics around hidden items
/// + the `WalkSkipCollector` reporting surface. The behaviour change
/// (default include-hidden, opt-in exclude) was made to align with
/// `tar` / `zip` / `ditto` / `7z`; this test pins the new contract so
/// a future refactor can't silently flip it back.
final class FileWalkerHiddenTests: XCTestCase {

    private func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("knit-walker-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Source layout:
    ///   root/
    ///     visible.txt
    ///     .hidden_file.txt
    ///     .hidden_dir/
    ///       inner.txt
    private func buildLayout() throws -> URL {
        let root = try makeTempDir("layout")
        try Data("v".utf8).write(to: root.appendingPathComponent("visible.txt"))
        try Data("h".utf8).write(to: root.appendingPathComponent(".hidden_file.txt"))
        let hiddenDir = root.appendingPathComponent(".hidden_dir")
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: hiddenDir.appendingPathComponent("inner.txt"))
        return root
    }

    /// Default behaviour: include hidden files and hidden directories.
    /// Matches the policy tar / zip / `ditto` use, and is the change
    /// users requested after `pack` silently dropped 1.5 GB of `.git/`
    /// content on a sample run.
    func testDefaultIncludesHiddenFiles() throws {
        let root = try buildLayout()
        defer { try? FileManager.default.removeItem(at: root) }

        let entries = try FileWalker.enumerate(root)
        let names = Set(entries.map { $0.relativePath })

        let rootName = root.lastPathComponent
        XCTAssertTrue(names.contains { $0.hasSuffix("/visible.txt") },
                      "visible.txt missing from default walk")
        XCTAssertTrue(names.contains { $0.hasSuffix("/.hidden_file.txt") },
                      "hidden file should be included by default (got: \(names))")
        XCTAssertTrue(names.contains { $0.contains("/.hidden_dir/") || $0.hasSuffix("/.hidden_dir/") },
                      "hidden dir should be walked into by default (got: \(names))")
        XCTAssertTrue(names.contains { $0.hasSuffix("/.hidden_dir/inner.txt") },
                      "contents of hidden dir should be enumerated by default")
        _ = rootName
    }

    /// Opt-in: `excludeHidden: true` filters hidden items and skips
    /// descending into hidden directories (so a 100 GB `.git/objects/`
    /// doesn't get stat-walked just to be discarded).
    func testExcludeHiddenSkipsHiddenItemsAndDescendants() throws {
        let root = try buildLayout()
        defer { try? FileManager.default.removeItem(at: root) }

        let entries = try FileWalker.enumerate(root, excludeHidden: true)
        let names = Set(entries.map { $0.relativePath })

        XCTAssertTrue(names.contains { $0.hasSuffix("/visible.txt") })
        XCTAssertFalse(names.contains { $0.hasSuffix("/.hidden_file.txt") },
                       "hidden file should be excluded with excludeHidden=true")
        XCTAssertFalse(names.contains { $0.hasSuffix("/.hidden_dir/inner.txt") },
                       "contents of hidden dir should not be enumerated when its parent is hidden-skipped")
    }

    /// `WalkSkipCollector` records each excluded item with reason +
    /// recursive bytes/items. Without this surface the user has to
    /// diff `du` output against the archive to figure out what got
    /// dropped — exactly the painful debugging session that motivated
    /// the change.
    func testCollectorRecordsHiddenSkipsWithRecursiveSizes() throws {
        let root = try buildLayout()
        defer { try? FileManager.default.removeItem(at: root) }

        let collector = WalkSkipCollector()
        _ = try FileWalker.enumerate(root,
                                     excludeHidden: true,
                                     skipCollector: collector)
        let report = collector.snapshot()

        let hiddenEntries = report.entries(reason: .hidden)
        XCTAssertEqual(hiddenEntries.count, 2,
                       "expected exactly two hidden top-level entries " +
                       "(.hidden_file.txt + .hidden_dir/), got \(hiddenEntries.map { $0.relativePath })")
        XCTAssertTrue(hiddenEntries.contains { $0.relativePath.hasSuffix(".hidden_file.txt") })
        XCTAssertTrue(hiddenEntries.contains { $0.relativePath.contains(".hidden_dir") })

        // The recursive byte count for the hidden dir should include
        // its inner.txt's 2 bytes. Anything ≥ 1 here proves we walked
        // into the hidden subtree just for sizing (without including
        // its contents in the archive).
        let hiddenDir = hiddenEntries.first { $0.relativePath.contains(".hidden_dir") }!
        XCTAssertGreaterThan(hiddenDir.bytes, 0)
        XCTAssertGreaterThan(hiddenDir.itemCount, 0)
    }

    /// Symlinks remain skipped regardless of `excludeHidden`. The
    /// collector records them so `--analyze` output answers "did
    /// any symlinks get dropped?" without the user having to run
    /// `find -type l`.
    func testSymlinksAlwaysSkippedAndRecorded() throws {
        let root = try makeTempDir("symlink-collector")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("real".utf8).write(to: root.appendingPathComponent("real.txt"))
        let target = root.appendingPathComponent("real.txt")
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let collector = WalkSkipCollector()
        let entries = try FileWalker.enumerate(root, skipCollector: collector)
        let names = Set(entries.map { $0.relativePath })
        XCTAssertFalse(names.contains { $0.hasSuffix("/link.txt") },
                       "symlink should not appear in archive entries")

        let symlinks = collector.snapshot().entries(reason: .symlink)
        XCTAssertEqual(symlinks.count, 1)
        XCTAssertTrue(symlinks[0].relativePath.hasSuffix("/link.txt"))
    }
}
