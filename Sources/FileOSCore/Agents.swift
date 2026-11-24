import Foundation
#if canImport(Glibc)
import Glibc
#endif

public enum Agent: String, CaseIterable, Sendable, Codable {
    case claude, codex, cursor, gemini, copilot, antigravity, opencode

    public var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini CLI"
        case .copilot: return "Copilot"
        case .antigravity: return "Antigravity"
        case .opencode: return "OpenCode"
        }
    }

    /// What "Start an Agent Here" copies for pasting in the terminal (FileOS never runs it).
    public var command: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .cursor: return "cursor-agent"
        case .gemini: return "gemini"
        case .copilot: return "copilot"
        case .antigravity: return "antigravity ."
        case .opencode: return "opencode"
        }
    }
}

public struct AgentFiles: Sendable, Equatable {
    public let agent: Agent
    public let files: [String]
}

public struct MCPServer: Sendable, Equatable, Identifiable {
    public let name: String
    /// The command line, or the URL for a remote server.
    public let detail: String
    public var id: String { name }
}

public struct ListeningPort: Sendable, Equatable, Identifiable {
    public let port: Int
    public let pid: Int32
    public let command: String
    public var id: String { "\(port):\(pid)" }
}

public struct SetupPlanItem: Sendable, Equatable, Identifiable {
    public let path: String
    /// "new" or "already there".
    public let state: String
    public var id: String { path }
}

public enum SetupError: Error, LocalizedError, Equatable {
    case outsideProject(String)
    public var errorDescription: String? {
        switch self {
        case .outsideProject(let p): return "“\(p)” would be written outside the project, through a link"
        }
    }
}

/// One file FileOS wrote, and what it held before (nil: it didn't exist), so undo can put it back.
public struct SetupWrite: Sendable, Equatable {
    public let url: URL
    public let previous: Data?
    public let written: Data
}

/// F14.4. Reads agent setup files, MCP configs, listening ports and Claude Code logs. Writes only the setup
/// files the user saves or copies, each undoable.
public enum Agents {
    // Folders in a list are scanned for files inside them (e.g. Claude's commands).
    public static let files: [Agent: [String]] = [
        .claude: ["CLAUDE.md", "CLAUDE.local.md", ".mcp.json", ".claude/settings.json", ".claude/settings.local.json",
                  ".claude/commands", ".claude/agents"],
        .codex: ["AGENTS.md", ".codex/config.toml"],
        .cursor: [".cursorrules", ".cursor/rules", ".cursor/mcp.json"],
        .gemini: ["GEMINI.md", ".gemini/settings.json"],
        .copilot: [".github/copilot-instructions.md", ".github/instructions"],
        .antigravity: [".agent/rules", ".agent/workflows"],
        .opencode: ["opencode.json", ".opencode"],
    ]

    /// Personal files never copied to another project.
    public static let personal: Set<String> = ["CLAUDE.local.md", "settings.local.json"]

    private static let maxFilesPerFolder = 200

    /// The setup paths present in `dir`, per agent, in `Agent.allCases` order.
    public static func scanProject(_ dir: URL) -> [AgentFiles] {
        Agent.allCases.compactMap { agent in
            let found = (files[agent] ?? []).filter { exists(dir.appendingPathComponent($0)) }
            return found.isEmpty ? nil : AgentFiles(agent: agent, files: found)
        }
    }

    /// The regular files a setup path stands for: itself, or the files inside it (not following links).
    public static func regularFiles(_ rel: String, in dir: URL) -> [String] {
        let url = dir.appendingPathComponent(rel)
        guard let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else { return [] }
        if type == .typeRegular { return [rel] }
        guard type == .typeDirectory else { return [] }
        var out: [String] = []
        var stack = [rel]
        while let d = stack.popLast(), out.count < maxFilesPerFolder {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(d).path)) ?? [] {
                let child = d + "/" + name
                switch (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(child).path))?[.type] as? FileAttributeType {
                case .typeRegular?: out.append(child)
                case .typeDirectory?: stack.append(child)
                default: break
                }
            }
        }
        return out.sorted()
    }

    /// `rel` under `root` resolves inside `root`: no symlink along the way (or at the end) leads out.
    static func staysInside(_ rel: String, root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        var url = root.appendingPathComponent(rel)
        if let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType,
           type == .typeSymbolicLink { return false }
        // The nearest part of the path that exists decides where a new file would land.
        while !exists(url), url.path.count > root.path.count { url = url.deletingLastPathComponent() }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == base || resolved.hasPrefix(base + "/")
    }

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    // MARK: Copy setup

    public static func copySetupPlan(from: URL, to: URL, agent: Agent) -> [SetupPlanItem] {
        let paths = (files[agent] ?? []).flatMap { regularFiles($0, in: from) }
            .filter { !personal.contains(($0 as NSString).lastPathComponent) && staysInside($0, root: from) }
        return Array(Set(paths)).sorted().map { SetupPlanItem(path: $0, state: exists(to.appendingPathComponent($0)) ? "already there" : "new") }
    }

    /// Copies the "new" items, and the "already there" ones only with `replace` ("Replace Them").
    /// On a failure the files already written are put back before it throws.
    public static func copySetup(_ plan: [SetupPlanItem], from: URL, to: URL, replace: Bool) throws -> [SetupWrite] {
        var writes: [SetupWrite] = []
        do {
            for item in plan where !personal.contains((item.path as NSString).lastPathComponent) {
                let dest = to.appendingPathComponent(item.path)
                // Never write through a symlinked folder (or file) out of the destination project.
                guard staysInside(item.path, root: to) else { throw SetupError.outsideProject(item.path) }
                if exists(dest) && !replace { continue } // also covers a file that appeared since the plan
                let data = try Data(contentsOf: from.appendingPathComponent(item.path))
                writes.append(try write(data, to: dest))
            }
        } catch {
            _ = undo(writes, trashDir: nil, removeNew: true)
            throw error
        }
        return writes
    }

    /// Atomic write (creating parent folders), remembering what the file held.
    public static func write(_ data: Data, to url: URL) throws -> SetupWrite {
        let previous: Data? = exists(url) ? try Data(contentsOf: url) : nil
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return SetupWrite(url: url, previous: previous, written: data)
    }

    /// Puts back what each file held; a file that didn't exist goes to the Trash. A file changed since is
    /// left alone and reported.
    public static func undo(_ writes: [SetupWrite], trashDir: URL?) -> RestoreResult {
        undo(writes, trashDir: trashDir, removeNew: false)
    }

    static func undo(_ writes: [SetupWrite], trashDir: URL?, removeNew: Bool) -> RestoreResult {
        var result = RestoreResult()
        for w in writes.reversed() {
            guard (try? Data(contentsOf: w.url)) == w.written else {
                result.failed.append((w.url, "it changed after FileOS wrote it"))
                continue
            }
            do {
                if let previous = w.previous {
                    try previous.write(to: w.url, options: .atomic)
                } else if removeNew {
                    try FileManager.default.removeItem(at: w.url) // rolling back our own half-finished copy
                } else {
                    _ = try FileOps.trash([w.url], trashDir: trashDir)
                }
                result.restored.append(w.url)
            } catch {
                result.failed.append((w.url, error.localizedDescription))
            }
        }
        return result
    }

    // MARK: Projects and MCP

    /// Folders Claude Code and Cursor have worked in that still exist.
    public static func projects(home: URL) -> [URL] {
        var paths: [String] = []
        if let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
           let projects = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["projects"] as? [String: Any] {
            paths += projects.keys
        }
        let storage = home.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage")
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? []).prefix(500) {
            guard let data = try? Data(contentsOf: storage.appendingPathComponent(name).appendingPathComponent("workspace.json")),
                  let folder = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["folder"] as? String,
                  let url = URL(string: folder), url.isFileURL else { continue }
            paths.append(url.path)
        }
        var seen: Set<String> = []
        return paths.filter { p in
            var dir: ObjCBool = false
            return seen.insert(p).inserted && FileManager.default.fileExists(atPath: p, isDirectory: &dir) && dir.boolValue
        }.sorted { ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
        .map { URL(fileURLWithPath: $0) }
    }

    /// `mcpServers` (Claude, Cursor) or `servers` (VS Code) in an MCP JSON file.
    public static func parseMCP(_ json: Data) -> [MCPServer] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return [] }
        return servers(root)
    }

    private static func servers(_ root: [String: Any]) -> [MCPServer] {
        let dict = (root["mcpServers"] ?? root["servers"]) as? [String: Any] ?? [:]
        return dict.compactMap { name, value in
            guard let v = value as? [String: Any] else { return nil }
            let line = ([v["command"] as? String].compactMap { $0 } + ((v["args"] as? [Any]) ?? []).map { "\($0)" }).joined(separator: " ")
            return MCPServer(name: name, detail: (v["url"] as? String) ?? line)
        }.sorted { $0.name < $1.name }
    }

    /// Claude Code's user-wide servers in ~/.claude.json.
    public static func userMCP(home: URL) -> [MCPServer] {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return servers(root)
    }

    // MARK: Ports

    public static func listeningPorts(runner: CommandRunner) async -> [ListeningPort] {
        guard let out = try? await runner.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"], timeout: 10) else { return [] }
        return parseLsof(out.stdout)
    }

    /// `lsof -nP -iTCP -sTCP:LISTEN`, one row per (port, pid).
    public static func parseLsof(_ output: String) -> [ListeningPort] {
        var seen: Set<String> = []
        var out: [ListeningPort] = []
        for line in output.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 9, cols.last == "(LISTEN)", let pid = Int32(cols[1]) else { continue }
            let address = cols[cols.count - 2]
            guard let colon = address.lastIndex(of: ":"), let port = Int(address[address.index(after: colon)...]) else { continue }
            let row = ListeningPort(port: port, pid: pid, command: String(cols[0]).replacingOccurrences(of: "\\x20", with: " "))
            if seen.insert(row.id).inserted { out.append(row) }
        }
        return out.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// Never PID 0/1 (and so no process group) or FileOS itself.
    public static func canStop(pid: Int32) -> Bool { pid > 1 && pid != getpid() }

    /// SIGINT, like Ctrl-C in the terminal that started it. The caller asks first.
    public static func stop(pid: Int32) -> Bool {
        guard canStop(pid: pid) else { return false }
        return kill(pid, SIGINT) == 0
    }

    // MARK: Claude Code usage

    static let maxLogFiles = 2_000

    /// Input + output tokens in ~/.claude/projects/**/*.jsonl for today, the last 7 days and the last 30 days.
    /// Bounded: files older than 30 days are skipped, the newest files are read first, and only the last
    /// `maxLogBytes` of each (logs are append-only, so that's the recent part) within `maxTotalBytes` overall.
    public static func claudeUsage(home: URL, now: Date, maxLogBytes: Int = 20 << 20,
                                   maxTotalBytes: Int = 300 << 20) -> (today: Int, week: Int, month: Int) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let weekStart = cal.date(byAdding: .day, value: -6, to: today) ?? today
        let monthStart = cal.date(byAdding: .day, value: -29, to: today) ?? today
        var totals = (today: 0, week: 0, month: 0)
        var seenIDs: Set<String> = []
        var budget = maxTotalBytes
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        for url in logFiles(home.appendingPathComponent(".claude/projects"), since: monthStart) {
            guard budget > 0, let data = tail(url, max: min(maxLogBytes, budget)) else { continue }
            budget -= data.count
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let message = obj["message"] as? [String: Any], let usage = message["usage"] as? [String: Any],
                      let stamp = obj["timestamp"] as? String,
                      let date = iso.date(from: stamp) ?? isoPlain.date(from: stamp), date >= monthStart, date <= now else { continue }
                // Claude Code logs one message in several lines with the same usage; count it once.
                if let id = message["id"] as? String, !seenIDs.insert(id).inserted { continue }
                let tokens = ((usage["input_tokens"] as? Int) ?? 0) + ((usage["output_tokens"] as? Int) ?? 0)
                totals.month += tokens
                if date >= weekStart { totals.week += tokens }
                if date >= today { totals.today += tokens }
            }
        }
        return totals
    }

    /// The last `max` bytes, starting after the first newline when the file was cut (no partial line).
    static func tail(_ url: URL, max: Int) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        let start = size > UInt64(max) ? size - UInt64(max) : 0
        guard (try? h.seek(toOffset: start)) != nil, let data = try? h.readToEnd() else { return nil }
        guard start > 0 else { return data }
        guard let nl = data.firstIndex(of: UInt8(ascii: "\n")) else { return Data() }
        return data[data.index(after: nl)...]
    }

    /// Newest first, so the byte budget goes to recent logs.
    private static func logFiles(_ root: URL, since: Date) -> [URL] {
        var out: [(url: URL, modified: Date)] = []
        var stack = [root]
        var visited = 0
        while let dir = stack.popLast(), visited < 20_000 {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                visited += 1
                let url = dir.appendingPathComponent(name)
                guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
                switch a[.type] as? FileAttributeType {
                case .typeDirectory?: stack.append(url)
                case .typeRegular? where name.hasSuffix(".jsonl"):
                    if let m = a[.modificationDate] as? Date, m >= since { out.append((url, m)) }
                default: break // symlinks aren't followed
                }
            }
        }
        return out.sorted { $0.modified > $1.modified }.prefix(maxLogFiles).map(\.url)
    }
}
