import Foundation

public enum PathBar {
    public static let commands: [String: String] = [
        "terminal": "terminal", "code": "vscode", "cursor": "cursor", "xed": "xcode", "zed": "zed",
        "subl": "sublime", "iterm": "iterm", "warp": "warp", "ghostty": "ghostty", "nova": "nova",
        "bbedit": "bbedit", "idea": "idea", "pycharm": "pycharm", "webstorm": "webstorm",
        "goland": "goland", "clion": "clion", "rider": "rider", "phpstorm": "phpstorm",
        "rubymine": "rubymine", "windsurf": "windsurf",
    ]

    public enum Parsed: Equatable, Sendable { case command(appID: String, target: URL), path(String) }
    public enum Resolved: Equatable, Sendable {
        case folder(URL), file(URL, dir: URL), missing(name: String, parent: URL, suggestion: String?)
    }

    static func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    static func children(_ dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    static func expand(_ s: String, cwd: URL, home: URL) -> URL {
        if s == "~" { return home }
        if s.hasPrefix("~/") { return home.appendingPathComponent(String(s.dropFirst(2))) }
        if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
        return cwd.appendingPathComponent(s)
    }

    public static func parse(_ input: String, cwd: URL, home: URL) -> Parsed {
        let text = input.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard let word = parts.first, let app = commands[word.lowercased()] else { return .path(text) }
        if parts.count == 1 && isDir(cwd.appendingPathComponent(word)) { return .path(text) }
        let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "."
        return .command(appID: app, target: expand(rest, cwd: cwd, home: home).standardizedFileURL)
    }

    public static func resolve(_ raw: String, cwd: URL, home: URL) -> Resolved {
        let text = raw.trimmingCharacters(in: .whitespaces)
        var url = expand(text, cwd: cwd, home: home)
        if !text.contains("/") && text != "~" {
            // Bare name: a child of cwd or home, case-insensitively.
            for base in [cwd, home] {
                if let hit = children(base).first(where: { $0.lowercased() == text.lowercased() }) {
                    url = base.appendingPathComponent(hit); break
                }
            }
        }
        url = url.standardizedFileURL
        if isDir(url) { return .folder(url) }
        if FileManager.default.fileExists(atPath: url.path) { return .file(url, dir: url.deletingLastPathComponent()) }
        let parent = url.deletingLastPathComponent(), name = url.lastPathComponent
        var best: (Int, String)?
        for base in [parent, home] {
            for c in children(base) where isDir(base.appendingPathComponent(c)) {
                let d = levenshtein(name.lowercased(), c.lowercased())
                if d <= 2, best == nil || d < best!.0 { best = (d, base.appendingPathComponent(c).path) }
            }
        }
        return .missing(name: name, parent: parent, suggestion: best.map { display($0.1, home: home) })
    }

    static func display(_ path: String, home: URL) -> String {
        path == home.path ? "~" : path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }

    public static func complete(_ input: String, cwd: URL, home: URL) -> [String] {
        let slash = input.lastIndex(of: "/")
        let dirPart = slash.map { String(input[...$0]) } ?? ""
        let prefix = slash.map { String(input[input.index(after: $0)...]) } ?? input
        let dir = dirPart.isEmpty ? cwd : expand(dirPart, cwd: cwd, home: home)
        return children(dir)
            .filter { (prefix.hasPrefix(".") || !$0.hasPrefix(".")) && $0.lowercased().hasPrefix(prefix.lowercased()) && isDir(dir.appendingPathComponent($0)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .prefix(20).map { dirPart + $0 }
    }

    public static func missingMessage(name: String, parent: URL) -> String {
        "There's no folder called “\(name)” in \(parent.lastPathComponent)"
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var prev = row[0]; row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }
}
