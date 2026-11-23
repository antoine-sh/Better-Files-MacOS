import XCTest
@testable import FileOSCore

final class FolderStateTests: XCTestCase {
    func testMapping() {
        XCTAssertEqual(FolderState(error: nil), .contents)
        XCTAssertEqual(FolderState(error: .accessDenied("/Users/sam/Desktop")), .locked(folder: "Desktop"))
        XCTAssertEqual(FolderState(error: .notFound("/Users/sam/Gone")), .unavailable("“Gone” could not be found"))
        XCTAssertEqual(FolderState.lockedTitle("Desktop"), "FileOS needs access to “Desktop”")
    }

    func testUnreadableFolderIsLockedNotBlank() throws {
        try XCTSkipIf(getuid() == 0, "root reads everything")
        let dir = makeTempDir().appendingPathComponent("Secret")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        touch(dir, "a.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        var error: FileOSError?
        do { _ = try FileOps.listDirectory(dir) } catch let e as FileOSError { error = e }
        XCTAssertEqual(FolderState(error: error), .locked(folder: "Secret"))
    }

    func testDisplayPath() {
        let home = URL(fileURLWithPath: "/Users/sam")
        XCTAssertEqual(PathBar.display("/Users/sam", home: home), "~")
        XCTAssertEqual(PathBar.display("/Users/sam/a b", home: home), "~/a b")
        XCTAssertEqual(PathBar.display("/Users/samuel", home: home), "/Users/samuel")
    }
}

final class CanonicalURLTests: XCTestCase {
    func testTrailingSlashAndDotsDoNotMatter() throws {
        let tmp = makeTempDir()
        let docs = tmp.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let viaAppend = tmp.appendingPathComponent("Documents")              // may carry a trailing slash
        let viaParent = docs.appendingPathComponent("a.txt").deletingLastPathComponent()
        let viaString = URL(fileURLWithPath: tmp.path + "/x/../Documents/")
        XCTAssertEqual(FileOps.canonical(viaAppend), FileOps.canonical(viaParent))
        XCTAssertEqual(FileOps.canonical(viaAppend), FileOps.canonical(viaString))
        XCTAssertEqual(FileOps.canonical(viaAppend).path, tmp.path + "/Documents")
        XCTAssertEqual(FileOps.canonical(URL(fileURLWithPath: "/")).path, "/")
        XCTAssertEqual(FileOps.canonical(docs.deletingLastPathComponent()), FileOps.canonical(tmp))
    }
}
