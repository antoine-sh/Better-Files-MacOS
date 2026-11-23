import Foundation

/// F9.4: where each loose file of a folder would go, and what stays put.
public struct TidyPlan: Sendable {
    public var moves: [(from: URL, to: URL, kind: FileKind)]
    public var left: [(name: String, reason: String)]
    public var byKind: [FileKind: (count: Int, bytes: Int64, destination: URL)]
    /// Installers go to the Trash instead of their folder.
    public var installersToTrash: Bool

    /// Files that would move with `skip` unticked.
    public func count(skipping skip: Set<FileKind>) -> Int { moves.filter { !skip.contains($0.kind) }.count }
}

/// A Tidy that failed and could not put everything back.
public struct TidyError: Error, LocalizedError {
    public let reason: String
    public let notRestored: [(url: URL, reason: String)]
    public var errorDescription: String? {
        let names = notRestored.map { "“\($0.url.lastPathComponent)”" }.joined(separator: ", ")
        return "\(reason). Couldn't put back \(names)"
    }
}

public enum Tidy {
    public static let stillDownloading = "Still downloading"
    public static let justAdded = "Added in the last 2 minutes"

    /// Loose files only (no folders, packages, links or hidden files). Screenshots go with Images unless
    /// `screenshotsToPictures` (e.g. Pictures/Screenshots) is given. Existing kind folders are reused.
    public static func plan(_ dir: URL, now: Date, screenshotsToPictures: URL? = nil,
                            installersToTrash: Bool = false) throws -> TidyPlan {
        var plan = TidyPlan(moves: [], left: [], byKind: [:], installersToTrash: installersToTrash)
        let entries = try FileOps.listDirectory(dir).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for entry in entries where !entry.isDirectory && !entry.isSymlink {
            if isDownloading(entry.name) { plan.left.append((entry.name, stillDownloading)); continue }
            // A download keeps the server's date as its modification date; the date it arrived is `added`.
            if now.timeIntervalSince(max(entry.modified, entry.added)) < 120 { plan.left.append((entry.name, justAdded)); continue }
            let kind = entry.kind ?? .other
            let folder: URL
            switch kind {
            case .screenshots: folder = screenshotsToPictures ?? dir.appendingPathComponent(FileKind.images.rawValue)
            default: folder = dir.appendingPathComponent(kind.rawValue)
            }
            let to = folder.appendingPathComponent(FileOps.uniqueName(in: folder, for: entry.name))
            plan.moves.append((entry.url, to, kind))
            let old = plan.byKind[kind] ?? (0, 0, folder)
            plan.byKind[kind] = (old.count + 1, old.bytes + entry.size, folder)
        }
        return plan
    }

    /// Moves the plan's files (installers to the Trash when the plan says so). All or nothing: on a failure
    /// what already moved goes back and the error is thrown. The undo puts files back and removes the
    /// folders this created once they are empty.
    public static func apply(_ plan: TidyPlan, skip: Set<FileKind>, trashDir: URL?) throws
        -> (moved: Int, undo: @Sendable () async -> RestoreResult) {
        var moves: [Move] = []
        var created: [URL] = []
        do {
            for m in plan.moves where !skip.contains(m.kind) {
                if m.kind == .installers && plan.installersToTrash {
                    moves += try FileOps.trash([m.from], trashDir: trashDir)
                    continue
                }
                let folder = m.to.deletingLastPathComponent()
                if !exists(folder) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    created.append(folder)
                }
                // Names are picked again: the folder may have changed since the plan was shown.
                let to = folder.appendingPathComponent(FileOps.uniqueName(in: folder, for: m.to.lastPathComponent))
                try FileOps.move(m.from, to: to)
                moves.append(Move(from: m.from, to: to))
            }
        } catch {
            let rollback = undo(moves, created)
            if rollback.failed.isEmpty { throw error }
            throw TidyError(reason: error.localizedDescription, notRestored: rollback.failed)
        }
        let done = moves, folders = created
        return (moves.count, { undo(done, folders) })
    }

    private static func undo(_ moves: [Move], _ created: [URL]) -> RestoreResult {
        let result = FileOps.restore(moves)
        for folder in created.reversed() {
            // Finder may have dropped a .DS_Store in it; that alone still counts as empty.
            if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
               names.allSatisfy({ $0 == ".DS_Store" }) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        return result
    }

    public static let dateLabels = ["Today", "Yesterday", "Earlier this week", "Earlier this month", "Older"]

    /// F9.2, by date added; keeps the entries' order inside each group and drops empty groups.
    public static func groupByDate(_ entries: [Entry], now: Date, calendar: Calendar) -> [(label: String, items: [Entry])] {
        let today = calendar.startOfDay(for: now)
        let label: (Entry) -> String = { entry in
            let day = calendar.startOfDay(for: entry.added)
            let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            if days <= 0 { return "Today" }
            if days == 1 { return "Yesterday" }
            if calendar.isDate(day, equalTo: today, toGranularity: .weekOfYear) { return "Earlier this week" }
            if calendar.isDate(day, equalTo: today, toGranularity: .month) { return "Earlier this month" }
            return "Older"
        }
        let buckets = Dictionary(grouping: entries, by: label)
        return dateLabels.compactMap { l in buckets[l].map { (l, $0) } }
    }

    /// F9.1: files by kind, biggest group first; still-downloading files last in their own group (`kind` nil).
    public static func groupByKind(_ entries: [Entry]) -> [(kind: FileKind?, items: [Entry], bytes: Int64)] {
        let files = entries.filter { !$0.isDirectory }
        let downloading = files.filter { isDownloading($0.name) }
        let buckets = Dictionary(grouping: files.filter { !isDownloading($0.name) }) { $0.kind ?? .other }
        var out: [(kind: FileKind?, items: [Entry], bytes: Int64)] = buckets
            .map { (kind: $0.key, items: $0.value, bytes: $0.value.reduce(0) { $0 + $1.size }) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.kind!.rawValue < $1.kind!.rawValue }
        if !downloading.isEmpty { out.append((nil, downloading, downloading.reduce(0) { $0 + $1.size })) }
        return out
    }

    /// F9.3. `installedApps` are app names without ".app" ("Google Chrome").
    public static func suggestions(_ entries: [Entry], installedApps: Set<String>, now: Date)
        -> (installers: [Entry], duplicates: [Entry], older: [Entry]) {
        let files = entries.filter { !$0.isDirectory && !isDownloading($0.name) }
        let installers = files.filter { $0.kind == .installers && installerApp($0.name, installedApps) != nil }
        let duplicates = files.filter { isLikelyCopyName($0.name) }
        let older = files.filter { now.timeIntervalSince($0.added) > 90 * 86_400 }
        return (installers, duplicates, older)
    }

    /// "invoice (1).pdf", "notes copy.txt", "notes copy 2.txt".
    public static func isLikelyCopyName(_ name: String) -> Bool {
        let base = splitExtension(name).base
        if base.hasSuffix(")"), let open = base.lastIndex(of: "("), open > base.startIndex,
           base[base.index(before: open)] == " " {
            let digits = base[base.index(after: open)..<base.index(before: base.endIndex)]
            // Up to 3 digits: "Photo (2019).jpg" is a year, not a copy.
            if (1...3).contains(digits.count) && digits.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        }
        if base.hasSuffix(" copy") && base.count > 5 { return true }
        if let range = base.range(of: " copy ", options: .backwards), range.lowerBound > base.startIndex {
            let digits = base[range.upperBound...]
            return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
        }
        return false
    }

    /// The installed app an installer is for: "Firefox 128.0.dmg" and "googlechrome.dmg" match "Firefox"
    /// and "Google Chrome" by their letters.
    /// The app name must end at a word break: "Arc" doesn't match "ArcGIS.dmg".
    public static func installerApp(_ name: String, _ apps: Set<String>) -> String? {
        let installer = Array(splitExtension(name).base.lowercased())
        // Longest first, so "Google Chrome Canary" beats "Google Chrome".
        return apps.sorted { $0.count > $1.count }.first { app in
            let key = Array(app.lowercased().filter { $0.isLetter })
            guard key.count >= 3 else { return false }
            var matched = 0, i = 0
            while i < installer.count, matched < key.count {
                if installer[i].isLetter {
                    if installer[i] != key[matched] { return false }
                    matched += 1
                }
                i += 1
            }
            return matched == key.count && (i == installer.count || !installer[i].isLetter)
        }
    }
}
