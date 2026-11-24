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
            XCTAssertEqual(Array(args.prefix(5)), ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", dir.path])
            XCTAssertTrue(args.contains("status") || args.contains("describe") || args.contains("config"))
            if args.contains("describe") { return (0, "v2\n") }
            // A user-wide filter (git-lfs) is the user's own and doesn't stop the count.
            if args.contains("config") { return (0, "global\0filter.lfs.clean\ngit-lfs clean -- %f\0local\0core.bare\nfalse\0") }
            XCTAssertTrue(args.contains("-z"))
            return (0, "## main\0 M a\0")
        }
        guard case .status(let s) = await Git.status(dir, runner: runner) else { return XCTFail() }
        XCTAssertEqual(s.tag, "v2")
        XCTAssertEqual(s.changed, 1)
    }

    func testParseNulSeparated() {
        let s = Git.parse("## main...origin/main\0R  new name\0old name\0?? a -> b\0 M \"q\".txt\0", tag: nil)
        XCTAssertEqual(s.files.map(\.path), ["new name", "a -> b", "\"q\".txt"])
        XCTAssertEqual([s.changed, s.added, s.deleted], [2, 1, 0])
    }

    func testRepoWithFiltersNeverRunsStatus() async throws {
        let dir = makeTempDir()
        touch(dir, ".git/HEAD", "ref: refs/heads/feature/x\n")
        touch(dir, ".git/config", "[core]\n\tbare = false\n[filter \"evil\"]\n\tclean = ./run-me\n")
        let runner = ScriptedRunner { exe, args in
            XCTAssertFalse(args.contains("status"), "ran \(exe) \(args)")
            return (0, "/x\n")
        }
        guard case .status(let s) = await Git.status(dir.appendingPathComponent("sub"), runner: runner) else { return XCTFail() }
        XCTAssertEqual(s.branch, "feature/x")
        XCTAssertFalse(s.countsKnown)
        // A worktree's .git file points at the real git dir; an include could bring filters in too.
        let wt = makeTempDir(), gitDir = makeTempDir()
        touch(gitDir, "HEAD", "0123abcd\n")
        touch(gitDir, "config", "[include]\n\tpath = ../x\n")
        touch(wt, ".git", "gitdir: \(gitDir.path)\n")
        guard case .status(let w) = await Git.status(wt, runner: runner) else { return XCTFail() }
        XCTAssertEqual(w.branch, "HEAD")
        XCTAssertFalse(w.countsKnown)
    }

    func testRepoConfigThatRunsProgramsNeverRunsStatus() async throws {
        let dir = makeTempDir()
        touch(dir, ".git/HEAD", "ref: refs/heads/main\n")
        let unsafe: [(Int32, String)] = [
            (0, "local\0filter.evil.clean\n./run-me\0"),
            (0, "worktree\0filter.x.process\nrun\0"),
            (0, "local\0include.path\n../cfg\0"),
            (0, "local\0includeIf.gitdir:/x/.path\n../cfg\0"),
            (0, "garbage\0without a scope\0"),
            (128, ""),
        ]
        for answer in unsafe {
            let runner = ScriptedRunner { exe, args in
                if exe == "xcode-select" { return (0, "/x\n") }
                XCTAssertFalse(args.contains("status") || args.contains("describe"), "ran \(args) for \(answer)")
                XCTAssertEqual(Array(args.prefix(5)), ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", dir.path])
                XCTAssertTrue(args.contains("--show-scope") && args.contains("-z"))
                return answer
            }
            guard case .status(let s) = await Git.status(dir, runner: runner) else { return XCTFail("\(answer)") }
            XCTAssertEqual(s.branch, "main")
            XCTAssertFalse(s.countsKnown, "\(answer)")
        }
    }

    /// Real git decides what its config holds: same-line headers, config.worktree, worktrees and includes.
    func testRealGitConfigTricksNeverRunAFilter() async throws {
        let git = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let git else { throw XCTSkip("git is missing") }
        let runner = ProcessRunner()
        #if os(macOS)
        guard (try? await runner.run("xcode-select", ["-p"], timeout: 5))?.status == 0 else { throw XCTSkip("no developer tools") }
        #endif
        func g(_ dir: URL, _ args: String...) async throws {
            _ = try await runner.run(git, ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args, timeout: 20)
        }
        func repo() async throws -> URL {
            let dir = makeTempDir()
            try await g(dir, "init", "-q", "-b", "main")
            touch(dir, ".gitattributes", "* filter=evil\n")
            touch(dir, "a.txt", "1")
            try await g(dir, "add", ".")
            try await g(dir, "commit", "-q", "-m", "first")
            touch(dir, "a.txt", "2") // stat-changed, so status would run the clean filter
            return dir
        }
        func append(_ url: URL, _ text: String) throws {
            let h = try FileHandle(forWritingTo: url); try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8)); try h.close()
        }
        let marker = makeTempDir().appendingPathComponent("pwned")
        let clean = "clean = touch \(marker.path)\n"
        func assertBranchOnly(_ dir: URL, _ what: String) async {
            guard case .status(let s) = await Git.status(dir, runner: runner) else { return XCTFail(what) }
            XCTAssertFalse(s.countsKnown, what)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "\(what) ran the filter")
        }

        let sameLine = try await repo()
        try append(sameLine.appendingPathComponent(".git/config"), "[core] [filter \"evil\"]\n\t\(clean)")
        await assertBranchOnly(sameLine, "same-line header")

        let included = try await repo()
        touch(included, "cfg", "[filter \"evil\"]\n\t\(clean)")
        try append(included.appendingPathComponent(".git/config"), "[include]\n\tpath = ../cfg\n")
        await assertBranchOnly(included, "include.path")

        let main = try await repo()
        let wt = makeTempDir().appendingPathComponent("wt")
        try await g(main, "worktree", "add", "-q", wt.path)
        touch(wt, "a.txt", "3")
        try await g(main, "config", "filter.evil.clean", "touch \(marker.path)")
        await assertBranchOnly(wt, "worktree using the common config")

        let perWorktree = try await repo()
        try await g(perWorktree, "config", "extensions.worktreeConfig", "true")
        touch(perWorktree, ".git/config.worktree", "[filter \"evil\"]\n\t\(clean)")
        await assertBranchOnly(perWorktree, "config.worktree")
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
        let listing = try await runner.run(git, ["-C", dir.path, "config", "--list", "--show-scope", "-z"], timeout: 10).stdout
        XCTAssertTrue(s.countsKnown, listing.replacingOccurrences(of: "\0", with: " | "))
        XCTAssertEqual(s.branch, "trunk")
        XCTAssertNil(s.tag)
        XCTAssertEqual([s.changed, s.added, s.deleted], [1, 1, 1])
        let after = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "status must not rewrite the index")
        let none = await Git.status(makeTempDir(), runner: runner)
        XCTAssertEqual(none, .notRepo)
    }
}
