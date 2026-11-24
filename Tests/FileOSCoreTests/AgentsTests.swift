import XCTest
@testable import FileOSCore

final class AgentsTests: XCTestCase {
    func testScanProject() {
        let dir = makeTempDir()
        touch(dir, "CLAUDE.md")
        touch(dir, ".cursorrules")
        touch(dir, "README.md")
        let found = Agents.scanProject(dir)
        XCTAssertEqual(found.map(\.agent), [.claude, .cursor])
        XCTAssertEqual(found.map(\.files), [["CLAUDE.md"], [".cursorrules"]])
    }

    func testFileLists() {
        XCTAssertEqual(Set(Agents.files.keys), Set(Agent.allCases))
        XCTAssertTrue(Agents.files[.claude]!.contains(".mcp.json"))
        XCTAssertTrue(Agents.files[.codex]!.contains("AGENTS.md"))
        XCTAssertTrue(Agents.files[.gemini]!.contains("GEMINI.md"))
    }

    func testCopySetupPlanSkipsPersonalFiles() throws {
        let from = makeTempDir(), to = makeTempDir()
        touch(from, "CLAUDE.md", "mine")
        touch(from, "CLAUDE.local.md", "secret")
        touch(from, ".claude/settings.json", "{}")
        touch(from, ".claude/settings.local.json", "{\"token\":1}")
        touch(from, ".claude/commands/review.md", "r")
        touch(to, "CLAUDE.md", "theirs")
        let plan = Agents.copySetupPlan(from: from, to: to, agent: .claude)
        XCTAssertEqual(plan.map(\.path), [".claude/commands/review.md", ".claude/settings.json", "CLAUDE.md"])
        XCTAssertEqual(plan.map(\.state), ["new", "new", "already there"])

        // Without "Replace Them" nothing already there is touched; undo removes only what was made.
        let trash = makeTempDir()
        let writes = try Agents.copySetup(plan, from: from, to: to, replace: false)
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(try String(contentsOf: to.appendingPathComponent("CLAUDE.md"), encoding: .utf8), "theirs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: to.appendingPathComponent("CLAUDE.local.md").path))
        let undone = Agents.undo(writes, trashDir: trash)
        XCTAssertTrue(undone.failed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: to.appendingPathComponent(".claude/settings.json").path))

        // "Replace Them": undo puts their version back.
        let replaced = try Agents.copySetup(plan, from: from, to: to, replace: true)
        XCTAssertEqual(try String(contentsOf: to.appendingPathComponent("CLAUDE.md"), encoding: .utf8), "mine")
        _ = Agents.undo(replaced, trashDir: trash)
        XCTAssertEqual(try String(contentsOf: to.appendingPathComponent("CLAUDE.md"), encoding: .utf8), "theirs")
    }

    func testSaveAndUndoNeverOverwritesALaterChange() throws {
        let dir = makeTempDir()
        let url = touch(dir, "AGENTS.md", "old")
        let w = try Agents.write(Data("new".utf8), to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
        try "elsewhere".write(to: url, atomically: true, encoding: .utf8)
        let r = Agents.undo([w], trashDir: makeTempDir())
        XCTAssertEqual(r.failed.count, 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "elsewhere")
    }

    func testParseMCP() {
        let json = #"{"mcpServers":{"github":{"command":"npx","args":["-y","@mcp/github"]},"docs":{"type":"http","url":"https://x.dev/mcp"}}}"#
        let servers = Agents.parseMCP(Data(json.utf8))
        XCTAssertEqual(servers.map(\.name), ["docs", "github"])
        XCTAssertEqual(servers.map(\.detail), ["https://x.dev/mcp", "npx -y @mcp/github"])
        XCTAssertTrue(Agents.parseMCP(Data("nope".utf8)).isEmpty)
    }

    func testLsofParse() {
        let out = """
        COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node      12345 me     23u  IPv4 0x1234567890      0t0  TCP 127.0.0.1:3000 (LISTEN)
        node      12345 me     24u  IPv6 0x1234567891      0t0  TCP [::1]:3000 (LISTEN)
        Python      777 me      4u  IPv4 0x1234567892      0t0  TCP *:8000 (LISTEN)
        garbage
        """
        let ports = Agents.parseLsof(out)
        XCTAssertEqual(ports.map(\.port), [3000, 8000])
        XCTAssertEqual(ports.map(\.pid), [12345, 777])
        XCTAssertEqual(ports.map(\.command), ["node", "Python"])
    }

    func testStopRefusesSystemAndSelf() {
        XCTAssertFalse(Agents.canStop(pid: 0))
        XCTAssertFalse(Agents.canStop(pid: 1))
        XCTAssertFalse(Agents.canStop(pid: getpid()))
        XCTAssertTrue(Agents.canStop(pid: 4242))
        XCTAssertFalse(Agents.stop(pid: 1))
    }

    func testClaudeUsage() throws {
        let home = makeTempDir()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let now = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        func line(_ daysAgo: Int, _ id: String, _ i: Int, _ o: Int) -> String {
            let d = now.addingTimeInterval(Double(-daysAgo) * 86_400)
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return #"{"type":"assistant","timestamp":"\#(f.string(from: d))","message":{"id":"\#(id)","usage":{"input_tokens":\#(i),"output_tokens":\#(o),"cache_read_input_tokens":999}}}"#
        }
        let text = [line(0, "a", 10, 5), line(0, "a", 10, 5), "{broken", line(3, "b", 100, 0), line(20, "c", 1000, 0),
                    line(45, "d", 9999, 0), #"{"type":"user","message":{"content":"hi"}}"#].joined(separator: "\n")
        touch(home, ".claude/projects/-Users-me-app/s1.jsonl", text)
        touch(home, ".claude/projects/-Users-me-app/notes.txt", line(0, "z", 7, 7))
        let u = Agents.claudeUsage(home: home, now: now)
        XCTAssertEqual(u.today, 15)
        XCTAssertEqual(u.week, 115)
        XCTAssertEqual(u.month, 1115)
        XCTAssertEqual(Agents.claudeUsage(home: makeTempDir(), now: now).month, 0)
    }

    func testUsageReadsTheEndOfALargeLogNewestFirst() throws {
        let home = makeTempDir()
        let stamp = ISO8601DateFormatter().string(from: Date())
        let old = String(repeating: #"{"type":"assistant","note":"padding"}"# + "\n", count: 200)
        let today = #"{"timestamp":"\#(stamp)","message":{"id":"t","usage":{"input_tokens":3,"output_tokens":4}}}"#
        touch(home, ".claude/projects/p/big.jsonl", old + today + "\n")
        let u = Agents.claudeUsage(home: home, now: Date(), maxLogBytes: 1_000, maxTotalBytes: 1_000)
        XCTAssertEqual(u.today, 7)
        // An older file walked first can't spend the budget meant for the newest.
        touch(home, ".claude/projects/a/older.jsonl", old, modified: Date().addingTimeInterval(-86_400))
        XCTAssertEqual(Agents.claudeUsage(home: home, now: Date(), maxLogBytes: 1_000, maxTotalBytes: 1_000).today, 7)
    }

    func testCopySetupRefusesASymlinkedDestination() throws {
        let from = makeTempDir(), to = makeTempDir(), elsewhere = makeTempDir()
        touch(from, ".claude/settings.json", "{}")
        touch(from, "CLAUDE.md", "x")
        try FileManager.default.createSymbolicLink(at: to.appendingPathComponent(".claude"), withDestinationURL: elsewhere)
        let plan = Agents.copySetupPlan(from: from, to: to, agent: .claude)
        XCTAssertThrowsError(try Agents.copySetup(plan, from: from, to: to, replace: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("settings.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: to.appendingPathComponent("CLAUDE.md").path), "rolled back")
        // A symlinked folder in the source isn't followed either.
        let src = makeTempDir(), secret = makeTempDir()
        touch(secret, "x.md", "secret")
        try FileManager.default.createSymbolicLink(at: src.appendingPathComponent(".claude"), withDestinationURL: secret)
        XCTAssertTrue(Agents.copySetupPlan(from: src, to: to, agent: .claude).isEmpty)
    }

    func testProjectsFromClaudeConfig() throws {
        let home = makeTempDir(), proj = makeTempDir()
        touch(home, ".claude.json", #"{"projects":{"\#(proj.path)":{},"/no/such/place":{}},"mcpServers":{"g":{"command":"x"}}}"#)
        XCTAssertEqual(Agents.projects(home: home).map(\.path), [proj.path])
        XCTAssertEqual(Agents.userMCP(home: home).map(\.name), ["g"])
    }
}
