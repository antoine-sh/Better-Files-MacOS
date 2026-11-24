import Foundation

public struct GitFile: Sendable, Equatable {
    /// The two porcelain letters, trimmed ("M", "??", "D", "R" …).
    public let status: String
    public let path: String
}

public struct GitStatus: Sendable, Equatable {
    public var branch: String
    public var tag: String?
    public var changed = 0, added = 0, deleted = 0
    public var files: [GitFile] = []
    /// False when FileOS didn't run `status` (the repo's settings would run programs): branch only.
    public var countsKnown = true

    /// What the chip shows: the tag when HEAD is detached on one, else the branch.
    public var title: String { branch == "HEAD" ? (tag ?? branch) : branch }
}

public enum GitResult: Sendable, Equatable {
    case notRepo, gitMissing, status(GitStatus)
}

/// F14.1, read-only: only `status` and `describe`, with optional locks off so git never rewrites the index.
public enum Git {
    /// The nearest folder holding `.git` (a folder, or a file for worktrees), or nil.
    public static func repoRoot(_ dir: URL) -> URL? {
        var url = dir.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url }
            if url.path == "/" { return nil }
            url = url.deletingLastPathComponent()
        }
    }

    public static func status(_ dir: URL, runner: CommandRunner) async -> GitResult {
        // No .git above: not a repo, and no process is launched for every folder the user opens.
        guard let root = repoRoot(dir) else { return .notRepo }
        // A repo's own config can name programs that `status` runs (filter drivers, possibly via an
        // include). Such a repo, say one just unzipped, gets the branch read from HEAD and no counts.
        if let gitDir = gitDir(root), runsPrograms(gitDir) {
            var s = GitStatus(branch: headBranch(gitDir) ?? "HEAD", tag: nil)
            s.countsKnown = false
            return .status(s)
        }
        #if os(macOS)
        // /usr/bin/git is a stub that offers to install the developer tools; ask xcode-select first.
        guard let dev = try? await runner.run("xcode-select", ["-p"], timeout: 5), dev.status == 0 else { return .gitMissing }
        #endif
        // core.fsmonitor would run a hook program; submodules would bring their own configs.
        let base = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", dir.path]
        let out: (status: Int32, stdout: String)
        do {
            out = try await runner.run("git", base + ["status", "--porcelain=v1", "-b", "-z", "--ignore-submodules=all"], timeout: 10)
        } catch CommandError.notFound {
            return .gitMissing
        } catch {
            return .notRepo // timed out: show nothing rather than a wrong count
        }
        guard out.status == 0 else { return .notRepo }
        let tag = try? await runner.run("git", base + ["describe", "--tags", "--exact-match"], timeout: 5)
        let tagName = tag.flatMap { $0.status == 0 ? $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        return .status(parse(out.stdout, tag: tagName?.isEmpty == false ? tagName : nil))
    }

    /// `.git`, or the folder a worktree's `.git` file points at.
    static func gitDir(_ root: URL) -> URL? {
        let dotGit = root.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dotGit }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }

    /// Filter drivers or includes in the repo's local config (an unreadable config counts as unsafe).
    static func runsPrograms(_ gitDir: URL) -> Bool {
        let config = gitDir.appendingPathComponent("config")
        guard FileManager.default.fileExists(atPath: config.path) else { return false }
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return true }
        return text.split(separator: "\n").contains { line in
            let l = line.trimmingCharacters(in: .whitespaces).lowercased()
            return l.hasPrefix("[filter") || l.hasPrefix("[include")
        }
    }

    static func headBranch(_ gitDir: URL) -> String? {
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        let t = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("ref: refs/heads/") ? String(t.dropFirst("ref: refs/heads/".count)) : "HEAD"
    }

    /// Parses `git status --porcelain=v1 -b`, NUL-separated (`-z`, paths unquoted) or line by line.
    public static func parse(_ porcelain: String, tag: String?) -> GitStatus {
        var s = GitStatus(branch: "HEAD", tag: tag)
        let nul = porcelain.contains("\0")
        var entries = porcelain.split(separator: nul ? "\0" : "\n", omittingEmptySubsequences: true)[...]
        while let entry = entries.popFirst() {
            if entry.hasPrefix("## ") {
                s.branch = branchName(String(entry.dropFirst(3)))
                continue
            }
            guard entry.count > 3 else { continue }
            let code = String(entry.prefix(2))
            var path = String(entry.dropFirst(3))
            if nul {
                if code.contains("R") || code.contains("C") { _ = entries.popFirst() } // the old path follows
            } else {
                if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
                if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
            }
            if code == "??" || code.contains("A") { s.added += 1 } else if code.contains("D") { s.deleted += 1 } else { s.changed += 1 }
            s.files.append(GitFile(status: code.trimmingCharacters(in: .whitespaces), path: path))
        }
        return s
    }

    static func branchName(_ header: String) -> String {
        for prefix in ["No commits yet on ", "Initial commit on "] where header.hasPrefix(prefix) {
            return String(header.dropFirst(prefix.count))
        }
        if header.hasPrefix("HEAD (") { return "HEAD" }
        var name = header
        if let dots = name.range(of: "...") { name = String(name[..<dots.lowerBound]) }
        if let space = name.firstIndex(of: " ") { name = String(name[..<space]) }
        return name
    }
}
