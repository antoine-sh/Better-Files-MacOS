import Foundation

public enum Rename {
    public enum BatchRule: Sendable {
        case replace(find: String, with: String)
        case add(text: String, before: Bool)
        case number(name: String, start: Int)
    }

    public struct BatchRow: Sendable {
        public var from: String, to: String
        public var error: String?
        public init(from: String, to: String, error: String? = nil) { self.from = from; self.to = to; self.error = error }
    }

    public static func validate(_ name: String) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Name can't be empty" }
        if name.contains("/") || name.contains(":") { return "Names can't contain / or :" }
        if name == "." || name == ".." { return "Names can't be “.” or “..”" }
        if name.utf8.count > 255 { return "Name is too long" }
        return nil
    }

    /// A leading dot is allowed (".env") but hides the item, so a single rename asks first, as Finder does.
    public static func hidesItem(_ name: String) -> Bool { name.hasPrefix(".") }

    /// Extensions include the dot; nil when they match case-insensitively.
    public static func extensionChange(from: String, to: String) -> (from: String, to: String)? {
        let a = splitExtension(from).ext, b = splitExtension(to).ext
        return a.lowercased() == b.lowercased() ? nil : (a, b)
    }

    public static func plan(_ names: [String], rule: BatchRule, existing: Set<String>) -> [BatchRow] {
        var rows = names.enumerated().map { i, from -> BatchRow in
            if isDownloading(from) { return BatchRow(from: from, to: from, error: "Still downloading") }
            let (base, ext) = splitExtension(from)
            let nb: String
            switch rule {
            case .replace(let find, let with): nb = find.isEmpty ? base : base.replacingOccurrences(of: find, with: with)
            case .add(let text, let before): nb = before ? text + base : base + text
            case .number(let name, let start):
                let n = String(start + i)
                nb = "\(name) \(String(repeating: "0", count: max(0, 2 - n.count)))\(n)"
            }
            let to = nb + ext
            let error = to == from ? nil : validate(to) ?? (hidesItem(to) ? "Names can't start with a dot" : nil)
            return BatchRow(from: from, to: to, error: error)
        }
        var counts: [String: Int] = [:]
        for r in rows { counts[r.to.lowercased(), default: 0] += 1 }
        let taken = Set(existing.map { $0.lowercased() })
        for i in rows.indices where rows[i].error == nil {
            let to = rows[i].to.lowercased()
            if counts[to]! > 1 { rows[i].error = "Duplicate name" }
            // A case-only change of the same file isn't a clash with itself.
            else if to != rows[i].from.lowercased(), taken.contains(to) { rows[i].error = "Already in this folder" }
        }
        return rows
    }

    /// Skips rows with an error; keeps going past individual failures.
    public static func apply(_ rows: [BatchRow], in dir: URL)
        -> (renamed: Int, failed: [(String, String)], undo: @Sendable () async -> RestoreResult) {
        var done: [Move] = []
        var failed: [(String, String)] = []
        for r in rows where r.error == nil && r.from != r.to {
            let from = dir.appendingPathComponent(r.from)
            do { done.append(Move(from: from, to: try FileOps.rename(from, to: r.to))) }
            catch { failed.append((r.from, error.localizedDescription)) }
        }
        let moves = done
        return (moves.count, failed, {
            var res = RestoreResult()
            for m in moves.reversed() { // FileOps.rename (not restore) so case-only renames undo on case-insensitive volumes
                do { _ = try FileOps.rename(m.to, to: m.from.lastPathComponent); res.restored.append(m.from) }
                catch { res.failed.append((m.from, error.localizedDescription)) }
            }
            return res
        })
    }
}
