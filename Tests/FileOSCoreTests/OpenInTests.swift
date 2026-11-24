import XCTest
@testable import FileOSCore

final class OpenInTests: XCTestCase {
    func testTarget() {
        let cwd = URL(fileURLWithPath: "/tmp/cwd")
        let file = cwd.appendingPathComponent("a.txt"), dir = cwd.appendingPathComponent("d")
        XCTAssertEqual(OpenIn.target(kind: .terminal, selection: [file], cwd: cwd), cwd)
        XCTAssertEqual(OpenIn.target(kind: .editor, selection: [file, dir], cwd: cwd), file)
        XCTAssertEqual(OpenIn.target(kind: .editor, selection: [], cwd: cwd), cwd)
    }

    func testEditorTargetIsFirstSelectedFile() {
        let root = makeTempDir(); let f = touch(root, "a.txt")
        XCTAssertEqual(OpenIn.target(kind: .editor, selection: [f], cwd: root), f)
    }

    func testTerminalTargetIsSelectedFolder() {
        let root = makeTempDir(); let d = root.appendingPathComponent("d")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        XCTAssertEqual(OpenIn.target(kind: .terminal, selection: [d], cwd: root), d)
    }

    func testApps() {
        XCTAssertEqual(OpenIn.apps.count, 23)
    }
}
