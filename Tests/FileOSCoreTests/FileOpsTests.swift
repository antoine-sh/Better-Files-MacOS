import XCTest
@testable import FileOSCore

final class FileOpsTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = makeTempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testListDirectoryHidden() throws {
        touch(dir, "a.pdf"); touch(dir, ".hidden"); try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let shown = try FileOps.listDirectory(dir)
        XCTAssertEqual(Set(shown.map(\.name)), ["a.pdf", "sub"])
        XCTAssertEqual(shown.first { $0.name == "a.pdf" }?.kind, .pdfs)
        XCTAssertNil(shown.first { $0.name == "sub" }?.kind)
        XCTAssertTrue(shown.first { $0.name == "sub" }!.isDirectory)
        let all = try FileOps.listDirectory(dir, showHidden: true)
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all.first { $0.name == ".hidden" }!.isHidden)
    }

    func testListDirectoryAccessDenied() throws {
        try XCTSkipIf(getuid() == 0, "root bypasses permissions")
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o755) }
        XCTAssertThrowsError(try FileOps.listDirectory(locked)) {
            XCTAssertEqual($0 as? FileOSError, .accessDenied(locked.path))
        }
    }

    func testListDirectoryMissing() {
        XCTAssertThrowsError(try FileOps.listDirectory(dir.appendingPathComponent("nope"))) {
            XCTAssertEqual($0 as? FileOSError, .notFound(dir.appendingPathComponent("nope").path))
        }
    }

    func testUniqueName() {
        XCTAssertEqual(FileOps.uniqueName(in: dir, for: "a b.tar.gz"), "a b.tar.gz")
        touch(dir, "a b.tar.gz")
        XCTAssertEqual(FileOps.uniqueName(in: dir, for: "a b.tar.gz"), "a b 2.tar.gz")
        touch(dir, "a b 2.tar.gz")
        XCTAssertEqual(FileOps.uniqueName(in: dir, for: "a b.tar.gz"), "a b 3.tar.gz")
    }

    func testNewFolder() throws {
        XCTAssertEqual(try FileOps.newFolder(in: dir).lastPathComponent, "untitled folder")
        XCTAssertEqual(try FileOps.newFolder(in: dir).lastPathComponent, "untitled folder 2")
    }

    func testDuplicate() throws {
        let f = touch(dir, "report.pdf")
        XCTAssertEqual(try FileOps.duplicate(f).lastPathComponent, "report copy.pdf")
        XCTAssertEqual(try FileOps.duplicate(f).lastPathComponent, "report copy 2.pdf")
    }

    func testDuplicateFolder() throws {
        touch(dir, "d/inner.txt")
        let c = try FileOps.duplicate(dir.appendingPathComponent("d"))
        XCTAssertEqual(c.lastPathComponent, "d copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.appendingPathComponent("inner.txt").path))
    }

    func testMakeAlias() throws {
        let f = touch(dir, "report.pdf")
        let a = try FileOps.makeAlias(f)
        XCTAssertEqual(a.lastPathComponent, "report alias.pdf")
        XCTAssertNotNil(try? FileManager.default.attributesOfItem(atPath: a.path))
    }

    func testRename() throws {
        let f = touch(dir, "a.txt")
        let r = try FileOps.rename(f, to: "A.txt")
        XCTAssertEqual(r.lastPathComponent, "A.txt")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains("A.txt"))
    }

    func testRenameClashAndInvalid() throws {
        let a = touch(dir, "a.txt"); touch(dir, "b.txt")
        XCTAssertThrowsError(try FileOps.rename(a, to: "b.txt")) { XCTAssertEqual($0 as? FileOSError, .alreadyExists("b.txt")) }
        for bad in ["", ".", "..", "x/y"] {
            XCTAssertThrowsError(try FileOps.rename(a, to: bad)) { XCTAssertEqual($0 as? FileOSError, .invalidName(bad)) }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertEqual(try FileOps.rename(a, to: "a.txt"), a) // same name: nothing to do
    }

    func testRenameAllowsBackslash() throws { // legal on macOS, and Rename.validate allows it in batch renames
        let r = try FileOps.rename(touch(dir, "a.txt"), to: "x\\y.txt")
        XCTAssertTrue(exists(r))
    }

    func testCrossVolumeMoveKeepsWhatAppearedAtTheDestination() {
        let a = touch(dir, "a.txt", "A")
        let to = dir.appendingPathComponent("b.txt")
        XCTAssertThrowsError(try FileOps.copyThenRemove(a, to: to) { _, to in
            try "theirs".write(to: to, atomically: false, encoding: .utf8) // another process got there first
            try FileManager.default.copyItem(at: a, to: to)
        }) { XCTAssertEqual($0 as? FileOSError, .alreadyExists("b.txt")) }
        XCTAssertEqual(try? String(contentsOf: to, encoding: .utf8), "theirs")
        XCTAssertTrue(exists(a))
    }

    func testRenameMissingIsNotFound() {
        let missing = dir.appendingPathComponent("nope.txt")
        XCTAssertThrowsError(try FileOps.rename(missing, to: "x.txt")) { XCTAssertEqual($0 as? FileOSError, .notFound(missing.path)) }
    }

    func testRenameInReadOnlyDirIsAccessDenied() throws {
        try XCTSkipIf(getuid() == 0, "root bypasses permissions")
        let f = touch(dir, "ro/a.txt")
        let ro = dir.appendingPathComponent("ro")
        chmod(ro.path, 0o555)
        defer { chmod(ro.path, 0o755) }
        XCTAssertThrowsError(try FileOps.rename(f, to: "b.txt")) { XCTAssertEqual($0 as? FileOSError, .accessDenied(f.path)) }
    }

    func testRenameHardLinkNotSilentlyAccepted() throws {
        // Same inode but different name (not case-only) must still be a clash, not a no-op.
        let a = touch(dir, "a.txt")
        let b = dir.appendingPathComponent("b.txt")
        try FileManager.default.linkItem(at: a, to: b)
        XCTAssertThrowsError(try FileOps.rename(a, to: "b.txt")) { XCTAssertEqual($0 as? FileOSError, .alreadyExists("b.txt")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }

    func testTrashRestoreRoundTrip() throws {
        let trash = dir.appendingPathComponent("Trash")
        let f = touch(dir, "a.txt"), g = touch(dir, "sub/a.txt")
        let moves = try FileOps.trash([f, g], trashDir: trash)
        XCTAssertEqual(Set(moves.map { $0.to.lastPathComponent }), ["a.txt", "a 2.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
        let r = FileOps.restore(moves)
        XCTAssertEqual(Set(r.restored), [f, g])
        XCTAssertTrue(r.failed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: g.path))
    }

    func testRestoreWhenOriginalPathTaken() throws {
        let trash = dir.appendingPathComponent("Trash")
        let f = touch(dir, "a.txt", "old")
        let moves = try FileOps.trash([f], trashDir: trash)
        touch(dir, "a.txt", "new")
        let r = FileOps.restore(moves)
        XCTAssertTrue(r.restored.isEmpty)
        XCTAssertEqual(r.failed.map(\.url), [f])
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: moves[0].to, encoding: .utf8), "old")
    }

    func testRestoreRecreatesParentAndReportsRest() throws {
        let trash = dir.appendingPathComponent("Trash")
        let f = touch(dir, "gone/a.txt"), g = touch(dir, "b.txt")
        let moves = try FileOps.trash([f, g], trashDir: trash)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("gone"))
        touch(dir, "b.txt", "taken")
        let r = FileOps.restore(moves)
        XCTAssertEqual(r.restored, [f])
        XCTAssertEqual(r.failed.map(\.url), [g])
    }

    func testMoveDoesNotOverwrite() throws {
        let a = touch(dir, "a.txt"), b = touch(dir, "b.txt")
        XCTAssertThrowsError(try FileOps.move(a, to: b)) { XCTAssertEqual($0 as? FileOSError, .alreadyExists("b.txt")) }
        try FileOps.move(a, to: dir.appendingPathComponent("c.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
    }

    func testTrashSummaryAndEmpty() throws {
        let trash = dir.appendingPathComponent("Trash")
        XCTAssertEqual(try FileOps.trashSummary(trash).count, 0) // missing reads as empty
        touch(trash, "a.txt", "12345"); touch(trash, "d/b.txt", "123")
        let s = try FileOps.trashSummary(trash)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.bytes, 8)
        let e = try FileOps.emptyTrash(trash)
        XCTAssertEqual(e.count, 2)
        XCTAssertEqual(e.bytes, 8)
        XCTAssertEqual(try FileOps.trashSummary(trash).count, 0)
    }

    func testTrashSummaryThrowsWhenTheTrashCantBeListed() {
        let notADir = touch(dir, "Trash") // stands in for a Trash we may not read (root ignores permissions)
        XCTAssertThrowsError(try FileOps.trashSummary(notADir))
    }

    func testMoveAcrossVolumesRemovesItsPartialCopyOnFailure() {
        let a = touch(dir, "a.txt", "A")
        let to = dir.appendingPathComponent("b.txt")
        struct Boom: Error {}
        XCTAssertThrowsError(try FileOps.copyThenRemove(a, to: to) { _, to in
            try "half".write(to: to, atomically: false, encoding: .utf8); throw Boom()
        })
        XCTAssertFalse(exists(to))
        XCTAssertTrue(exists(a))
    }

    func testTrashSummaryCountsDanglingSymlink() throws {
        let trash = dir.appendingPathComponent("Trash")
        touch(trash, "a.txt")
        // A dangling symlink still counts (lstat succeeds); a name that disappears does not.
        try FileManager.default.createSymbolicLink(at: trash.appendingPathComponent("dangling"), withDestinationURL: dir.appendingPathComponent("nowhere"))
        XCTAssertEqual(try FileOps.trashSummary(trash).count, 2)
    }

    func testDirectorySizeSymlinkLoop() throws {
        touch(dir, "a/f.txt", "12345")
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("a/loop"), withDestinationURL: dir)
        let r = FileOps.directorySize(dir)
        XCTAssertEqual(r.bytes, 5)
        XCTAssertEqual(r.items, 3)
    }

    func testDirectorySizeMaxEntries() {
        for i in 0..<10 { touch(dir, "f\(i)") }
        XCTAssertEqual(FileOps.directorySize(dir, maxEntries: 4).items, 4)
    }

    func testDiskInfo() {
        let d = FileOps.diskInfo(for: dir)
        XCTAssertGreaterThan(d.total, 0)
        XCTAssertLessThanOrEqual(d.free, d.total)
    }

    func testErrorCopy() {
        XCTAssertEqual(FileOSError.intoItself("X").errorDescription, "Can't move “X” into itself")
    }
}
