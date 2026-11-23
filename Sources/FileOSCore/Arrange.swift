import Foundation

public enum SortKey: String, Codable, CaseIterable, Sendable { case name, kind, modified, added, size }
public enum Grouping: String, Codable, CaseIterable, Sendable { case none, kind, date }

/// F3.4: how one folder is sorted and grouped (view-only; nothing moves). Persisted per folder.
public struct FolderPrefs: Codable, Equatable, Sendable {
    public var sortKey: SortKey
    public var ascending: Bool
    public var filesFirst: Bool
    public var group: Grouping

    public init(sortKey: SortKey = .name, ascending: Bool = true, filesFirst: Bool = false, group: Grouping = .none) {
        self.sortKey = sortKey; self.ascending = ascending; self.filesFirst = filesFirst; self.group = group
    }
}

public enum Arrange {
    public static func sorted(_ entries: [Entry], _ prefs: FolderPrefs) -> [Entry] {
        entries.sorted { a, b in
            if prefs.filesFirst, a.isDirectory != b.isDirectory { return !a.isDirectory }
            let order = compare(a, b, prefs.sortKey)
            let resolved = order == .orderedSame ? compare(a, b, .name) : order
            return prefs.ascending ? resolved == .orderedAscending : resolved == .orderedDescending
        }
    }

    private static func compare(_ a: Entry, _ b: Entry, _ key: SortKey) -> ComparisonResult {
        func cmp<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult { x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame }
        switch key {
        case .name: return a.name.localizedStandardCompare(b.name)
        case .modified: return cmp(a.modified, b.modified)
        case .added: return cmp(a.added, b.added)
        case .size: return cmp(a.isDirectory ? -1 : a.size, b.isDirectory ? -1 : b.size)
        case .kind:
            let ka = a.isDirectory ? "" : splitExtension(a.name).ext.lowercased()
            let kb = b.isDirectory ? "" : splitExtension(b.name).ext.lowercased()
            return cmp(ka, kb)
        }
    }

    /// Splits already-sorted entries into titled groups, keeping their order inside each group.
    /// `.none` gives one group titled "" (or none for an empty folder).
    public static func groups(_ entries: [Entry], by grouping: Grouping, now: Date,
                              calendar: Calendar = .current) -> [(title: String, entries: [Entry])] {
        let titles: [String]
        let title: (Entry) -> String
        switch grouping {
        case .none:
            return entries.isEmpty ? [] : [("", entries)]
        case .kind:
            titles = ["Folders"] + FileKind.allCases.map(\.rawValue)
            title = { $0.isDirectory ? "Folders" : ($0.kind ?? .other).rawValue }
        case .date:
            titles = ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "Earlier"]
            let today = calendar.startOfDay(for: now)
            title = { entry in
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: entry.added), to: today).day ?? 0
                switch days {
                case ...0: return "Today"
                case 1: return "Yesterday"
                case 2..<7: return "Previous 7 Days"
                case 7..<30: return "Previous 30 Days"
                default: return "Earlier"
                }
            }
        }
        let buckets = Dictionary(grouping: entries, by: title)
        return titles.compactMap { t in buckets[t].map { (t, $0) } }
    }
}
