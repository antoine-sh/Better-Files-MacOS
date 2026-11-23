import XCTest
@testable import FileOSCore

final class PathBarTests: XCTestCase {
    func fixture() -> (cwd: URL, home: URL) {
        let root = makeTempDir()
        let home = root.appendingPathComponent("home"), cwd = root.appendingPathComponent("cwd")
        for d in ["home/Documents", "home/Downloads", "cwd/sub", "cwd/code"] {
            try! FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        return (cwd, home)
    }

    func testCompleteTilde() {
        let (cwd, home) = fixture()
        XCTAssertEqual(PathBar.complete("~/Doc", cwd: cwd, home: home), ["~/Documents"])
        XCTAssertEqual(PathBar.complete("~/do", cwd: cwd, home: home), ["~/Documents", "~/Downloads"])
        XCTAssertEqual(PathBar.complete("su", cwd: cwd, home: home), ["sub"])
    }

    func testParse() {
        let (cwd, home) = fixture()
        guard case .command(let id, let target) = PathBar.parse("code .", cwd: cwd, home: home) else { return XCTFail() }
        XCTAssertEqual(id, "vscode")
        XCTAssertEqual(target.standardizedFileURL.path, cwd.standardizedFileURL.path)
        // "code" is a folder in cwd, so a bare "code" is a path
        guard case .path("code") = PathBar.parse("code", cwd: cwd, home: home) else { return XCTFail() }
        guard case .path = PathBar.parse("hello world", cwd: cwd, home: home) else { return XCTFail() }
    }

    func testResolve() {
        let (cwd, home) = fixture()
        guard case .folder(let h) = PathBar.resolve("~", cwd: cwd, home: home) else { return XCTFail() }
        XCTAssertEqual(h.path, home.path)
        guard case .folder(let d) = PathBar.resolve("documents", cwd: cwd, home: home) else { return XCTFail() }
        XCTAssertEqual(d.lastPathComponent, "Documents")
        guard case .missing(let name, _, let sug) = PathBar.resolve("Documnts", cwd: cwd, home: home) else { return XCTFail() }
        XCTAssertEqual(name, "Documnts"); XCTAssertEqual(sug, "~/Documents")
        let f = touch(cwd, "sub/a.txt")
        guard case .file(let u, let dir) = PathBar.resolve(f.path, cwd: cwd, home: home) else { return XCTFail() }
        XCTAssertEqual(u.path, f.path); XCTAssertEqual(dir.lastPathComponent, "sub")
        guard case .missing(_, _, nil) = PathBar.resolve("zzzzzzzz", cwd: cwd, home: home) else { return XCTFail() }
        XCTAssertEqual(PathBar.missingMessage(name: "X", parent: cwd), "There's no folder called “X” in cwd")
    }
}
