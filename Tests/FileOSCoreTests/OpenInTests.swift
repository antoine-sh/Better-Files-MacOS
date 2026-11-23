import XCTest
@testable import FileOSCore

final class OpenInTests: XCTestCase {
    func testTarget() {
        let cwd = URL(fileURLWithPath: "/tmp/cwd")
        let file = cwd.appendingPathComponent("a.txt"), dir = cwd.appendingPathComponent("d")
        XCTAssertEqual(OpenIn.target(kind: .terminal, selection: [file], cwd: cwd), cwd)
        XCTAssertEqual(OpenIn.target(kind: .terminal, selection: [file], cwd: cwd), cwd)
        XCTAssertEqual(OpenIn.target(kind: .editor, selection: [file, dir], cwd: cwd), file)
        XCTAssertEqual(OpenIn.target(kind: .editor, selection: [], cwd: cwd), cwd)
    }

    func testTerminalTargetIsSelectedFolder() {
        let root = makeTempDir(); let d = root.appendingPathComponent("d")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        XCTAssertEqual(OpenIn.target(kind: .terminal, selection: [d], cwd: root), d)
    }

    func testArgsAndApps() {
        let app = OpenIn.apps.first { $0.id == "vscode" }!
        XCTAssertEqual(OpenIn.openArguments(app: app, url: URL(fileURLWithPath: "/a b")), ["-a", app.bundleName, "/a b"])
        XCTAssertEqual(OpenIn.apps.count, 23)
    }

    func testProcessRunner() async throws {
        let r = try await ProcessRunner().run("/bin/echo", ["hi"], timeout: 5)
        XCTAssertEqual(r.status, 0); XCTAssertEqual(r.stdout, "hi\n")
        do { _ = try await ProcessRunner().run("/bin/sleep", ["5"], timeout: 0.2); XCTFail() }
        catch CommandError.timedOut {}
        do { _ = try await ProcessRunner().run("no-such-exe-xyz", [], timeout: 1); XCTFail() }
        catch CommandError.notFound(let n) { XCTAssertEqual(n, "no-such-exe-xyz") }
    }
}
