import XCTest
@testable import FileOSCore

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
final class Last: @unchecked Sendable {
    private let lock = NSLock(); private var p: TransferProgress?
    func set(_ v: TransferProgress) { lock.withLock { p = v } }
    var value: TransferProgress? { lock.withLock { p } }
}

final class TransferTests: XCTestCase {
    var root: URL!, src: URL!, dst: URL!, trash: URL!
    override func setUp() {
        root = makeTempDir()
        src = root.appendingPathComponent("src"); dst = root.appendingPathComponent("dst"); trash = root.appendingPathComponent("trash")
        for d in [src!, dst!] { try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func read(_ dir: URL, _ n: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8) }
    func has(_ dir: URL, _ n: String) -> Bool { exists(dir.appendingPathComponent(n)) }
    let always: @Sendable (ClashChoice) -> @Sendable (Clash) async -> (ClashChoice, applyToAll: Bool) = { c in { _ in (c, false) } }

    func testCopyAndMoveWithoutClash() async throws {
        let a = touch(src, "a.txt", "A"), b = touch(src, "b.txt", "B")
        let c = try await transfer([a], to: dst, mode: .copy, trashDir: trash, resolve: always(.stop))
        XCTAssertEqual(c.results.first?.action, .copied)
        XCTAssertTrue(has(src, "a.txt")); XCTAssertEqual(read(dst, "a.txt"), "A")
        let m = try await transfer([b], to: dst, mode: .move, trashDir: trash, resolve: always(.stop))
        XCTAssertEqual(m.results.first?.action, .moved)
        XCTAssertFalse(has(src, "b.txt")); XCTAssertEqual(read(dst, "b.txt"), "B")
    }

    func testKeepBoth() async throws {
        touch(dst, "Brand-Guide.pdf", "old")
        let s = touch(src, "Brand-Guide.pdf", "new")
        let r = try await transfer([s], to: dst, mode: .copy, trashDir: trash, resolve: always(.keepBoth))
        XCTAssertEqual(read(dst, "Brand-Guide.pdf"), "old")
        XCTAssertEqual(read(dst, "Brand-Guide 2.pdf"), "new")
        XCTAssertEqual(r.results.first?.to.lastPathComponent, "Brand-Guide 2.pdf")
    }

    func testCopyOntoItselfMakesAnotherWithoutAsking() async throws {
        let s = touch(src, "a.txt", "A")
        let asked = Counter()
        _ = try await transfer([s], to: src, mode: .copy, trashDir: trash, resolve: { _ in asked.bump(); return (.stop, false) })
        XCTAssertEqual(asked.value, 0)
        XCTAssertEqual(read(src, "a 2.txt"), "A")
    }

    func testReplaceTrashesOldAndUndoRestoresIt() async throws {
        touch(dst, "a.txt", "old")
        let s = touch(src, "a.txt", "new")
        let r = try await transfer([s], to: dst, mode: .copy, trashDir: trash, resolve: always(.replace))
        XCTAssertEqual(r.results.first?.action, .replaced)
        XCTAssertEqual(read(dst, "a.txt"), "new")
        XCTAssertEqual(FileOps.trashSummary(trash).count, 1)
        let u = await r.undo()
        XCTAssertTrue(u.failed.isEmpty)
        XCTAssertEqual(read(dst, "a.txt"), "old")
        XCTAssertEqual(FileOps.trashSummary(trash).count, 1) // the copy is in the trash now
    }

    func testApplyToAllAsksOnce() async throws {
        let srcs = (1...3).map { touch(src, "f\($0).txt", "new\($0)") }
        for i in 1...3 { touch(dst, "f\(i).txt", "old") }
        let asked = Counter()
        let r = try await transfer(srcs, to: dst, mode: .copy, trashDir: trash, resolve: { _ in asked.bump(); return (.keepBoth, true) })
        XCTAssertEqual(asked.value, 1)
        XCTAssertEqual(r.results.count, 3)
        XCTAssertEqual(read(dst, "f3 2.txt"), "new3")
    }

    func testRemainingCount() async throws {
        let srcs = (1...3).map { touch(src, "f\($0).txt") }
        for i in 1...3 { touch(dst, "f\(i).txt") }
        let rem = Counter(), d = dst!
        _ = try await transfer(srcs, to: dst, mode: .copy, trashDir: trash, resolve: { c in
            if c.remaining == 2 && c.destination == d && c.name == "f1.txt" { rem.bump() }
            return (.skip, false)
        })
        XCTAssertEqual(rem.value, 1)
    }

    func testSkipLeavesBothAndStillCountsProgress() async throws {
        touch(dst, "a.txt", "old")
        let s = touch(src, "a.txt", "new"); let t = touch(src, "b.txt", "B")
        let last = Last()
        let r = try await transfer([s, t], to: dst, mode: .copy, trashDir: trash, resolve: always(.skip), progress: { last.set($0) })
        XCTAssertEqual(read(dst, "a.txt"), "old")
        XCTAssertEqual(r.results.count, 1)
        XCTAssertEqual(last.value?.itemsDone, 2)
    }

    func testStopHalts() async throws {
        let a = touch(src, "a.txt"), b = touch(src, "b.txt")
        touch(dst, "b.txt")
        let c = touch(src, "c.txt")
        let r = try await transfer([a, b, c], to: dst, mode: .copy, trashDir: trash, resolve: always(.stop))
        XCTAssertTrue(r.stopped)
        XCTAssertNil(r.failure)
        XCTAssertTrue(has(dst, "a.txt")); XCTAssertFalse(has(dst, "c.txt"))
        let u = await r.undo()
        XCTAssertEqual(u.restored.count, 1)
        XCTAssertFalse(has(dst, "a.txt"))
    }

    func testIntoItselfThrowsAndChangesNothing() async throws {
        let a = src.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: a.appendingPathComponent("b"), withIntermediateDirectories: true)
        let other = touch(src, "other.txt")
        for target in [a.appendingPathComponent("b"), a] {
            do {
                _ = try await transfer([other, a], to: target, mode: .move, trashDir: trash, resolve: always(.stop))
                XCTFail("should throw")
            } catch let e as FileOSError { XCTAssertEqual(e, .intoItself("a")) }
        }
        XCTAssertTrue(has(src, "other.txt")); XCTAssertTrue(has(a, "b"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: a.path), ["b"])
    }

    func testIntoItselfThroughSymlinkedDestination() async throws {
        let a = src.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        do { _ = try await transfer([a], to: link, mode: .copy, trashDir: trash, resolve: always(.stop)); XCTFail() }
        catch let e as FileOSError { XCTAssertEqual(e, .intoItself("a")) }
    }

    func testMoveIntoSameFolderIsNoOp() async throws {
        let a = touch(src, "a.txt", "A")
        let last = Last()
        let r = try await transfer([a], to: src, mode: .move, trashDir: trash, resolve: always(.stop), progress: { last.set($0) })
        XCTAssertTrue(r.results.isEmpty); XCTAssertEqual(read(src, "a.txt"), "A")
        XCTAssertEqual(last.value?.itemsDone, 1)
    }

    func testMoveUndoRestores() async throws {
        let a = touch(src, "a.txt", "A")
        let r = try await transfer([a], to: dst, mode: .move, trashDir: trash, resolve: always(.stop))
        let u = await r.undo()
        XCTAssertEqual(u.restored, [a]); XCTAssertEqual(read(src, "a.txt"), "A"); XCTAssertFalse(has(dst, "a.txt"))
    }

    func testMoveReplaceUndoRestoresBoth() async throws {
        touch(dst, "a.txt", "old")
        let a = touch(src, "a.txt", "new")
        let r = try await transfer([a], to: dst, mode: .move, trashDir: trash, resolve: always(.replace))
        let u = await r.undo()
        XCTAssertTrue(u.failed.isEmpty)
        XCTAssertEqual(read(src, "a.txt"), "new"); XCTAssertEqual(read(dst, "a.txt"), "old")
    }

    func testCopyUndoAfterUserDeletedOneCopyReportsItAndStillRestoresReplaced() async throws {
        touch(dst, "a.txt", "old")
        let a = touch(src, "a.txt", "new"), b = touch(src, "b.txt", "B")
        let r = try await transfer([a, b], to: dst, mode: .copy, trashDir: trash, resolve: always(.replace))
        try FileManager.default.removeItem(at: dst.appendingPathComponent("b.txt")) // user deleted the copy of b
        let u = await r.undo()
        XCTAssertEqual(u.failed.map { $0.url.lastPathComponent }, ["b.txt"])
        XCTAssertEqual(u.restored.map(\.lastPathComponent).sorted(), ["a.txt", "a.txt"]) // copy trashed, original back
        XCTAssertEqual(read(dst, "a.txt"), "old")
    }

    func testMoveUndoWhenOriginalPathTakenReportsAndDoesNotOverwrite() async throws {
        let a = touch(src, "a.txt", "A"), b = touch(src, "b.txt", "B")
        let r = try await transfer([a, b], to: dst, mode: .move, trashDir: trash, resolve: always(.stop))
        touch(src, "a.txt", "squatter")
        let u = await r.undo()
        XCTAssertEqual(u.failed.map { $0.url }, [a])
        XCTAssertEqual(read(src, "a.txt"), "squatter"); XCTAssertEqual(read(dst, "a.txt"), "A")
        XCTAssertEqual(read(src, "b.txt"), "B") // the rest still restored
    }

    func testMidBatchErrorKeepsPartialResultAndUndo() async throws {
        let a = touch(src, "a.txt", "A")
        let missing = src.appendingPathComponent("missing.txt")
        let c = touch(src, "c.txt", "C")
        let r = try await transfer([a, missing, c], to: dst, mode: .copy, trashDir: trash, resolve: always(.stop))
        XCTAssertTrue(r.stopped); XCTAssertNotNil(r.failure)
        XCTAssertEqual(r.results.count, 1); XCTAssertFalse(has(dst, "c.txt"))
        let u = await r.undo()
        XCTAssertTrue(u.failed.isEmpty); XCTAssertFalse(has(dst, "a.txt"))
    }

    func testFailedReplaceRestoresTheTrashedOriginal() async throws {
        touch(dst, "a.txt", "old")
        let ghost = src.appendingPathComponent("a.txt") // doesn't exist, so the copy fails after the old one was trashed
        let r = try await transfer([ghost], to: dst, mode: .copy, trashDir: trash, resolve: always(.replace))
        XCTAssertNotNil(r.failure)
        XCTAssertEqual(read(dst, "a.txt"), "old")
    }

    func testCancelStops() async throws {
        let a = touch(src, "a.txt")
        let r = try await transfer([a], to: dst, mode: .copy, trashDir: trash, resolve: always(.stop), isCancelled: { true })
        XCTAssertTrue(r.stopped); XCTAssertFalse(has(dst, "a.txt"))
    }

    func testProgressEndsComplete() async throws {
        let srcs = [touch(src, "a.txt", "aaaa"), touch(src, "b.txt", "bb")]
        let last = Last()
        _ = try await transfer(srcs, to: dst, mode: .copy, trashDir: trash, resolve: always(.stop), progress: { last.set($0) })
        XCTAssertEqual(last.value?.itemsDone, 2); XCTAssertEqual(last.value?.itemsTotal, 2)
        XCTAssertEqual(last.value?.bytesDone, 6); XCTAssertEqual(last.value?.bytesTotal, 6)
    }

    func testCopiesFolderRecursively() async throws {
        touch(src, "d/inner/f.txt", "deep")
        _ = try await transfer([src.appendingPathComponent("d")], to: dst, mode: .copy, trashDir: trash, resolve: always(.stop))
        XCTAssertEqual(read(dst, "d/inner/f.txt"), "deep")
    }
}
