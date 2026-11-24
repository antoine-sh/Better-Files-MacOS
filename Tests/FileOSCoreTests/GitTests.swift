import XCTest
@testable import FileOSCore

final class GitTests: XCTestCase {
    func testParsePorcelain() {
        let s = Git.parse("## main...origin/main\n M a\n?? b\n D c\n", tag: nil)
        XCTAssertEqual(s.branch, "main")
        XCTAssertEqual([s.changed, s.added, s.deleted], [1, 1, 1])
        XCTAssertEqual(s.files.map(\.path), ["a", "b", "c"])
        XCTAssertEqual(s.files.map(\.status), ["M", "??", "D"])
    }

    func testParseOddHeadersAndRenames() {
        XCTAssertEqual(Git.parse("## No commits yet on dev\n", tag: nil).branch, "dev")
        let detached = Git.parse("## HEAD (no branch)\nR  old -> new\nA  x\n", tag: "v1.0")
        XCTAssertEqual(detached.branch, "HEAD")
        XCTAssertEqual(detached.title, "v1.0")
        XCTAssertEqual(detached.files.map(\.path), ["new", "x"])
        XCTAssertEqual([detached.changed, detached.added, detached.deleted], [1, 1, 0])
        XCTAssertEqual(Git.parse("## feature/x [ahead 2]\n", tag: nil).branch, "feature/x")
    }

    func testNotRepoRunsNothing() async {
        let dir = makeTempDir()
        let runner = ScriptedRunner { _, _ in XCTFail("ran a command"); return (0, "") }
        let r = await Git.status(dir, runner: runner)
        XCTAssertEqual(r, .notRepo)
    }

    func testMissingGit() async throws {
        let dir = makeTempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let runner = ScriptedRunner { exe, _ in
            if exe == "xcode-select" { return (0, "/Library/Developer/CommandLineTools\n") }
            throw CommandError.notFound(exe)
        }
        let r = await Git.status(dir, runner: runner)
        XCTAssertEqual(r, .gitMissing)
    }

    func testStatusUsesReadOnlyArguments() async throws {
        let dir = makeTempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let runner = ScriptedRunner { exe, args in
            if exe == "xcode-select" { return (0, "/x\n") }
            XCTAssertEqual(exe, "git")
            XCTAssertEqual(Array(args.prefix(3)), ["--no-optional-locks", "-C", dir.path])
            XCTAssertTrue(args.contains("status") || args.contains("describe"))
            if args.contains("describe") { return (0, "v2\n") }
            return (0, "## main\n M a\n")
        }
        guard case .status(let s) = await Git.status(dir, runner: runner) else { return XCTFail() }
        XCTAssertEqual(s.tag, "v2")
        XCTAssertEqual(s.changed, 1)
    }

    func testRealGit() async throws {
        let git = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let git else { throw XCTSkip("git is missing") }
        let dir = makeTempDir()
        let runner = ProcessRunner()
        func g(_ args: String...) async throws {
            _ = try await runner.run(git, ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args, timeout: 20)
        }
        try await g("init", "-q", "-b", "trunk")
        touch(dir, "kept.txt", "1")
        touch(dir, "gone.txt", "1")
        try await g("add", ".")
        try await g("commit", "-q", "-m", "first")
        let index = dir.appendingPathComponent(".git/index")
        let before = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        touch(dir, "kept.txt", "2")
        touch(dir, "new.txt", "n")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("gone.txt"))
        let r = await Git.status(dir, runner: runner)
        guard case .status(let s) = r else {
            // macOS without developer tools: still a valid answer.
            return XCTAssertEqual(r, .gitMissing)
        }
        XCTAssertEqual(s.branch, "trunk")
        XCTAssertNil(s.tag)
        XCTAssertEqual([s.changed, s.added, s.deleted], [1, 1, 1])
        let after = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "status must not rewrite the index")
        let none = await Git.status(makeTempDir(), runner: runner)
        XCTAssertEqual(none, .notRepo)
    }
}
