import Foundation

/// One ⌘K result (F7.1). `line` is the first matching line when searching contents (F7.2).
public struct SearchHit: Sendable, Hashable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let kind: FileKind?
    public let line: (number: Int, text: String)?

    public init(url: URL, name: String, isDirectory: Bool, kind: FileKind?, line: (number: Int, text: String)?) {
        self.url = url; self.name = name; self.isDirectory = isDirectory; self.kind = kind; self.line = line
    }

    public static func == (a: SearchHit, b: SearchHit) -> Bool { a.url == b.url && a.line?.number == b.line?.number }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(line?.number)
    }
}

public enum SearchChip: String, CaseIterable, Sendable {
    case all = "All", workspaces = "Workspaces", folders = "Folders", images = "Images", videos = "Videos"
    case music = "Music", documents = "Documents", bookmarks = "Bookmarks"

    func admits(isDirectory: Bool, kind: FileKind?) -> Bool {
        switch self {
        case .all: return true
        case .workspaces, .bookmarks: return false // matched from the store by the app, not on disk
        case .folders: return isDirectory
        case .images: return kind == .images || kind == .screenshots
        case .videos: return kind == .videos
        case .music: return kind == .audio
        case .documents: return kind == .pdfs || kind == .documents
        }
    }
}

private let skippedFolders: Set<String> = ["node_modules", ".git"]
private let maxContentBytes = 2_000_000

/// Finder-hidden folders (like ~/Library) that have no leading dot.
private func isFlaggedHidden(_ url: URL) -> Bool {
    #if os(macOS)
    return (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true
    #else
    return false
    #endif
}

/// The first line containing `query` (1-based), for UTF-8 text files of at most 2 MB.
private func matchingLine(_ url: URL, size: Int64, query: String) -> (number: Int, text: String)? {
    guard size <= maxContentBytes, let data = try? Data(contentsOf: url), !data.contains(0),
          let text = String(data: data, encoding: .utf8) else { return nil }
    var number = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        number += 1
        if line.range(of: query, options: .caseInsensitive) != nil {
            return (number, String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)))
        }
    }
    return nil
}

/// Breadth-first name search (case-insensitive) under `roots`, at most `maxDepth` levels down and `limit` hits.
/// Skips node_modules, .git and hidden folders and never follows symlinks, so loops and huge trees stay bounded.
/// Folders come first, then files in `FileKind.allCases` order; shallower hits first within each.
public func search(roots: [URL], query: String, contents: Bool = false, chip: SearchChip = .all, limit: Int = 200,
                   maxDepth: Int = 6, isCancelled: @Sendable () -> Bool = { false }) -> [SearchHit] {
    let needle = query.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty, chip != .workspaces, chip != .bookmarks else { return [] }
    var hits: [SearchHit] = []
    var queue: [(url: URL, depth: Int)] = roots.map { ($0, 0) }
    var next = 0
    scan: while next < queue.count {
        if isCancelled() { return [] }
        let (dir, depth) = queue[next]
        next += 1
        guard let entries = try? FileOps.listDirectory(dir) else { continue }
        for entry in entries.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            if entry.isDirectory {
                if skippedFolders.contains(entry.name) || isFlaggedHidden(entry.url) { continue }
                if !entry.isSymlink && depth + 1 < maxDepth { queue.append((entry.url, depth + 1)) }
            }
            guard chip.admits(isDirectory: entry.isDirectory, kind: entry.kind) else { continue }
            let nameMatches = entry.name.range(of: needle, options: .caseInsensitive) != nil
            var line: (number: Int, text: String)?
            if contents, !entry.isDirectory, entry.kind == .documents || entry.kind == .other {
                // shortcut: PDFs need PDFKit for their text; only plain-text files are read here
                line = matchingLine(entry.url, size: entry.size, query: needle)
            }
            guard nameMatches || line != nil else { continue }
            hits.append(SearchHit(url: entry.url, name: entry.name, isDirectory: entry.isDirectory, kind: entry.kind, line: line))
            if hits.count >= limit { break scan }
        }
    }
    if isCancelled() { return [] }
    let order = Dictionary(uniqueKeysWithValues: FileKind.allCases.enumerated().map { ($1, $0 + 1) })
    func rank(_ h: SearchHit) -> Int { h.isDirectory ? 0 : order[h.kind ?? .other] ?? order.count }
    return hits.enumerated().sorted { a, b in
        rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset
    }.map(\.element)
}
