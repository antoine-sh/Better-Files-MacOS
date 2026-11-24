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
        guard repoRoot(dir) != nil else { return .notRepo }
        #if os(macOS)
        // /usr/bin/git is a stub that offers to install the developer tools; ask xcode-select first.
        guard let dev = try? await runner.run("xcode-select", ["-p"], timeout: 5), dev.status == 0 else { return .gitMissing }
        #endif
        let base = ["--no-optional-locks", "-C", dir.path]
        let out: (status: Int32, stdout: String)
        do {
            out = try await runner.run("git", base + ["status", "--porcelain=v1", "-b"], timeout: 10)
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

    /// Parses `git status --porcelain=v1 -b`.
    public static func parse(_ porcelain: String, tag: String?) -> GitStatus {
        var s = GitStatus(branch: "HEAD", tag: tag)
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("## ") {
                s.branch = branchName(String(line.dropFirst(3)))
                continue
            }
            guard line.count > 3 else { continue }
            let code = String(line.prefix(2))
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
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
