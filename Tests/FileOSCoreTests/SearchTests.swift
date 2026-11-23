import Foundation
import XCTest
@testable import FileOSCore

final class SearchTests: XCTestCase {
    func testFoldersComeFirstThenFilesByKind() {
        let root = makeTempDir()
        touch(root, "report notes.md")
        touch(root, "report.pdf")
        touch(root, "sub/report.png")
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("Reports"), withIntermediateDirectories: true)
        let names = search(roots: [root], query: "REPORT").map(\.name)
        XCTAssertEqual(names, ["Reports", "report.pdf", "report.png", "report notes.md"])
        let hit = search(roots: [root], query: "reports").first
        XCTAssertEqual(hit?.isDirectory, true)
        XCTAssertNil(hit?.kind)
    }

    func testContentsFindsTheFirstMatchingLine() {
        let root = makeTempDir()
        touch(root, "a.md", "nothing here")
        touch(root, "dir/b.md", "first\nsecond has the Needle\nneedle again")
        XCTAssertTrue(search(roots: [root], query: "needle").isEmpty)
        let hits = search(roots: [root], query: "needle", contents: true)
        XCTAssertEqual(hits.map(\.name), ["b.md"])
        XCTAssertEqual(hits.first?.line?.number, 2)
        XCTAssertEqual(hits.first?.line?.text, "second has the Needle")
    }

    func testContentsSkipsBinaryAndLargeFiles() throws {
        let root = makeTempDir()
        try Data([0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65, 0x00, 0xFF]).write(to: root.appendingPathComponent("bin.dat"))
        try Data(repeating: 0x61, count: 2_000_001).write(to: root.appendingPathComponent("big.txt"))
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("big.txt"))
        handle.seekToEndOfFile()
        handle.write(Data("needle".utf8))
        try handle.close()
        XCTAssertTrue(search(roots: [root], query: "needle", contents: true).isEmpty)
    }

    func testContentsReadsOnlyRegularFilesNotLinksOrFifos() throws {
        let root = makeTempDir()
        let target = touch(makeTempDir(), "real.txt", "the needle")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: target)
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe.txt").path, 0o644), 0)
        touch(root, "plain.txt", "a needle here")
        let start = Date()
        let hits = search(roots: [root], query: "needle", contents: true)
        XCTAssertEqual(hits.map(\.name), ["plain.txt"]) // a FIFO read would block forever
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testContentsChecksCancellationPerEntry() {
        let root = makeTempDir()
        for i in 0..<5 { touch(root, "f\(i).txt", "needle") }
        let calls = CallCounter()
        let hits = search(roots: [root], query: "needle", contents: true, isCancelled: { calls.next() > 2 })
        XCTAssertTrue(hits.isEmpty)
        XCTAssertLessThan(calls.value, 6)
    }

    func testSymlinkLoopTerminatesAndIsNotFollowed() throws {
        let root = makeTempDir()
        touch(root, "a/target.txt")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("a/loop"), withDestinationURL: root)
        let hits = search(roots: [root], query: "target", maxDepth: 50)
        XCTAssertEqual(hits.map(\.url.path), [root.appendingPathComponent("a/target.txt").path])
    }

    func testMaxDepth() {
        let root = makeTempDir()
        touch(root, "1/2/deep.txt")
        XCTAssertTrue(search(roots: [root], query: "deep", maxDepth: 2).isEmpty)
        XCTAssertEqual(search(roots: [root], query: "deep", maxDepth: 3).count, 1)
    }

    func testSkipsNodeModulesGitAndHiddenFolders() {
        let root = makeTempDir()
        touch(root, "node_modules/x.js")
        touch(root, ".git/x.js")
        touch(root, ".cache/x.js")
        touch(root, "src/x.js")
        XCTAssertEqual(search(roots: [root], query: "x.js").map(\.url.path), [root.appendingPathComponent("src/x.js").path])
    }

    func testChipFilters() {
        let root = makeTempDir()
        for name in ["k.png", "Screenshot k.png", "k.mov", "k.mp3", "k.pdf", "k.docx", "k.zip"] { touch(root, name) }
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("k folder"), withIntermediateDirectories: true)
        func names(_ chip: SearchChip) -> Set<String> { Set(search(roots: [root], query: "k", chip: chip).map(\.name)) }
        XCTAssertEqual(names(.folders), ["k folder"])
        XCTAssertEqual(names(.images), ["k.png", "Screenshot k.png"])
        XCTAssertEqual(names(.videos), ["k.mov"])
        XCTAssertEqual(names(.music), ["k.mp3"])
        XCTAssertEqual(names(.documents), ["k.pdf", "k.docx"])
        XCTAssertEqual(names(.all).count, 8)
        XCTAssertTrue(names(.workspaces).isEmpty)
        XCTAssertTrue(names(.bookmarks).isEmpty)
    }

    func testLimitAndCancellation() {
        let root = makeTempDir()
        for i in 0..<10 { touch(root, "f\(i).txt") }
        XCTAssertEqual(search(roots: [root], query: "f", limit: 3).count, 3)
        XCTAssertTrue(search(roots: [root], query: "f", isCancelled: { true }).isEmpty)
        XCTAssertTrue(search(roots: [root], query: "  ").isEmpty)
    }

    func testHitEqualityIsURLAndLineNumber() {
        let url = URL(fileURLWithPath: "/tmp/x.md")
        let a = SearchHit(url: url, name: "x.md", isDirectory: false, kind: .documents, line: (3, "a"))
        let b = SearchHit(url: url, name: "x.md", isDirectory: false, kind: .documents, line: (3, "b"))
        let c = SearchHit(url: url, name: "x.md", isDirectory: false, kind: .documents, line: nil)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(Set([a, b, c]).count, 2)
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func next() -> Int { lock.withLock { n += 1; return n } }
}
