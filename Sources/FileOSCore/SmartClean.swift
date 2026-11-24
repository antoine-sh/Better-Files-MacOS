import Foundation

/// F10: Free Up Space suggestions. Scanning only reads (regular files, no links followed, bounded);
/// nothing moves until the user clicks "Move N to Trash".
public struct CleanItem: Sendable, Hashable, Identifiable {
    public var url: URL
    public var bytes: Int64
    public var ticked: Bool
    public var note: String?
    /// Duplicates: the copy that stays. The spare may go only while that copy is still there and the same.
    public var keep: URL?
    public var id: String { url.path }

    public init(url: URL, bytes: Int64, ticked: Bool, note: String? = nil, keep: URL? = nil) {
        self.url = url; self.bytes = bytes; self.ticked = ticked; self.note = note; self.keep = keep
    }

    /// Checked again just before trashing: the disk may have changed since the scan.
    public var stillSafeToTrash: Bool {
        guard let keep else { return true }
        return !SmartClean.sameFile(keep, url) && SmartClean.identical(keep, url)
    }
}

public enum CardID: String, CaseIterable, Sendable {
    case devCaches, duplicates, installers, mailAttachments, appLeftovers, bigFiles, unusedApps, screenRecordings, oldDownloads

    public var title: String {
        switch self {
        case .devCaches: return "Developer caches"
        case .duplicates: return "Duplicates"
        case .installers: return "Installers for installed apps"
        case .mailAttachments: return "Mail attachments"
        case .appLeftovers: return "App leftovers"
        case .bigFiles: return "Big files"
        case .unusedApps: return "Unused apps"
        case .screenRecordings: return "Screen recordings"
        case .oldDownloads: return "Old downloads"
        }
    }

    public var reason: String {
        switch self {
        case .devCaches: return "Rebuilt by the tools when they need them"
        case .duplicates: return "One copy of each is always kept"
        case .installers: return "The app is already installed"
        case .mailAttachments: return "Mail downloads them again when you open the message"
        case .appLeftovers: return "From apps that are no longer installed, untouched for 3 months"
        case .bigFiles: return "Over 500 MB and untouched for 6 months"
        case .unusedApps: return "Not opened in 6 months"
        case .screenRecordings: return "Older than 30 days"
        case .oldDownloads: return "In Downloads for over 90 days"
        }
    }

    public var group: CleanCard.Group { self == .devCaches || self == .duplicates || self == .installers ? .safe : .yourCall }
}

public struct CleanCard: Identifiable, Sendable {
    public enum Group: Sendable { case safe, yourCall }
    public let id: CardID
    public var title: String
    public var reason: String
    public var group: Group
    public var items: [CleanItem]

    public init(id: CardID, items: [CleanItem]) {
        self.id = id; title = id.title; reason = id.reason; group = id.group
        // "Your call" items are never ticked for the user.
        self.items = group == .yourCall ? items.map { var i = $0; i.ticked = false; return i } : items
    }

    /// Duplicates' "Tick These Too": ticks the spares left unticked. Kept copies are never items, so one copy
    /// of each set always stays.
    public mutating func tickTheseToo() {
        guard id == .duplicates else { return }
        for i in items.indices { items[i].ticked = true }
    }
}

public enum SmartClean {
    public static let devCachePaths = [
        "Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/iOS DeviceSupport",
        "Library/Developer/CoreSimulator/Caches", ".npm/_cacache", "Library/Caches/Homebrew", "Library/Caches/pip",
        "Library/Caches/Yarn", "Library/Caches/CocoaPods",
    ]
    static let day: TimeInterval = 86_400

    /// Applications folders searched for installed and unused apps.
    public static func applicationDirs(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), home.appendingPathComponent("Applications")]
    }

    /// App name (no ".app") → bundle, from the top level of `dirs`.
    public static func installedApps(in dirs: [URL]) -> [String: URL] {
        var out: [String: URL] = [:]
        for dir in dirs {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".app") {
                out[String(name.dropLast(4))] = dir.appendingPathComponent(name)
            }
        }
        return out
    }

    /// All nine cards in `CardID` order; an item shows in the first card that lists it only.
    /// Stops early (with what it has) when the task is cancelled.
    public static func scan(home: URL, now: Date, isAppRunning: (String) -> Bool,
                            applications: [URL]? = nil) -> [CleanCard] {
        let apps = installedApps(in: applications ?? applicationDirs(home: home))
        let roots = ["Downloads", "Desktop", "Documents", "Movies"].map { home.appendingPathComponent($0) }
        let found = walk(roots, maxDepth: 4)
        let downloads = home.appendingPathComponent("Downloads").path + "/"
        let desktop = home.appendingPathComponent("Desktop").path + "/"
        let documents = home.appendingPathComponent("Documents").path + "/"
        let inDownloadsOrDesktop = { (f: FileRecord) -> Bool in f.url.path.hasPrefix(downloads) || f.url.path.hasPrefix(desktop) }
        let candidates = found.files.filter { $0.size >= 1024 && (inDownloadsOrDesktop($0) || $0.url.path.hasPrefix(documents)) }
        let dupes = duplicates(candidates, inDownloadsOrDesktop: inDownloadsOrDesktop)
        var seen: Set<String> = []
        var cards: [CleanCard] = []
        for id in CardID.allCases {
            if Task.isCancelled { break }
            let all = id == .duplicates ? dupes.items
                : card(id, home: home, now: now, found: found, apps: apps, isAppRunning: isAppRunning, inDownloadsOrDesktop: inDownloadsOrDesktop)
            let items = all.filter { seen.insert($0.url.path).inserted }
            cards.append(CleanCard(id: id, items: items))
            // The copy each duplicate set keeps is never offered by a later card.
            if id == .duplicates { seen.formUnion(dupes.kept.map(\.path)) }
        }
        return cards
    }

    private static func card(_ id: CardID, home: URL, now: Date, found: (files: [FileRecord], nodeModules: [FileRecord]),
                             apps: [String: URL], isAppRunning: (String) -> Bool,
                             inDownloadsOrDesktop: (FileRecord) -> Bool) -> [CleanItem] {
        let files = found.files
        switch id {
        case .devCaches:
            let xcodeRunning = isAppRunning("Xcode")
            let caches: [CleanItem] = devCachePaths.compactMap { rel in
                if xcodeRunning && rel.hasPrefix("Library/Developer") { return nil }
                let url = home.appendingPathComponent(rel)
                guard isRealDirectory(url) else { return nil }
                return CleanItem(url: url, bytes: FileOps.directorySize(url).bytes, ticked: true)
            }
            // Stale node_modules are listed apart and left unticked: the project may still need them.
            let stale = found.nodeModules.filter { now.timeIntervalSince($0.modified) > 180 * day }.map {
                CleanItem(url: $0.url, bytes: FileOps.directorySize($0.url, maxEntries: 50_000).bytes, ticked: false, note: staleNodeModulesNote)
            }
            return caches + stale
        case .duplicates:
            return []
        case .installers:
            return files.compactMap { f in
                guard inDownloadsOrDesktop(f), FileKind.of(f.url.lastPathComponent) == .installers, wasDownloaded(f.url),
                      now.timeIntervalSince(f.modified) > 7 * day,
                      let app = Tidy.installerApp(f.url.lastPathComponent, Set(apps.keys)), let bundle = apps[app] else { return nil }
                let appDate = (try? FileManager.default.attributesOfItem(atPath: bundle.path))?[.modificationDate] as? Date
                if let appDate, f.modified > appDate { return nil } // newer than the app: maybe an update not yet installed
                return CleanItem(url: f.url, bytes: f.size, ticked: true, note: "\(app) is installed")
            }
        case .mailAttachments:
            let dirs = ["Library/Containers/com.apple.mail/Data/Library/Mail Downloads", "Library/Mail Downloads"]
            return dirs.flatMap { topLevel(home.appendingPathComponent($0)) }.map(item)
        case .appLeftovers:
            // shortcut: matches Application Support folder names against installed app names by letters;
            // read bundle IDs from Containers when false positives show up
            let keys = apps.keys.map(letters)
            return topLevel(home.appendingPathComponent("Library/Application Support")).filter { e in
                let name = letters(e.name)
                return e.isDirectory && name.count >= 3 && !e.name.hasPrefix("com.apple") && !systemSupport.contains(e.name)
                    && !keys.contains(where: { $0.hasPrefix(name) || name.hasPrefix($0) })
                    && untouched(e.url, since: now.addingTimeInterval(-90 * day))
            }.map(item)
        case .bigFiles:
            return files.filter { $0.size > 500_000_000 && now.timeIntervalSince($0.modified) > 180 * day }
                .map { CleanItem(url: $0.url, bytes: $0.size, ticked: false) }
        case .unusedApps:
            // Built-in apps (on the sealed system volume) can't be trashed: they only count as installed.
            return apps.values.filter { !$0.path.hasPrefix("/System/") }.sorted { $0.path < $1.path }.compactMap { bundle in
                let used = (try? bundle.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
                guard let used, now.timeIntervalSince(used) > 180 * day,
                      !isAppRunning(bundle.deletingPathExtension().lastPathComponent) else { return nil }
                return CleanItem(url: bundle, bytes: FileOps.directorySize(bundle, maxEntries: 50_000).bytes, ticked: false)
            }
        case .screenRecordings:
            return files.filter { f in
                let name = f.url.lastPathComponent
                return name.hasPrefix("Screen Recording ") && FileKind.of(name) == .videos && now.timeIntervalSince(f.modified) > 30 * day
            }.map { CleanItem(url: $0.url, bytes: $0.size, ticked: false) }
        case .oldDownloads:
            return topLevel(home.appendingPathComponent("Downloads"))
                .filter { now.timeIntervalSince(max($0.added, $0.modified)) > 90 * day }
                .map(item)
        }
    }

    /// macOS's own data in Application Support (Contacts, iPhone backups …), never an app's leftovers.
    // shortcut: a fixed list of the folders macOS makes; read bundle IDs from Containers if others show up
    static let systemSupport: Set<String> = [
        "AddressBook", "MobileSync", "CallHistoryDB", "CallHistoryTransactions", "Knowledge", "CrashReporter",
        "CloudDocs", "FileProvider", "SyncServices", "Dock", "DiskImages", "Animoji", "iLifeMediaBrowser", "icdd",
        "accountsd", "networkserviceproxy", "familycircled", "identityservicesd", "Mail", "Safari", "Photos",
        "Messages", "FaceTime", "Calendars", "Notes", "Reminders", "Shortcuts", "Siri", "Wallpaper", "Bluetooth",
    ]

    /// Nothing inside `dir` changed since `since` (a folder's own date misses changes deeper down). A tree too
    /// big to look through counts as touched, so it's never offered on a guess.
    static func untouched(_ dir: URL, since: Date, maxEntries: Int = 20_000) -> Bool {
        var stack = [dir], looked = 0
        while let d = stack.popLast() {
            guard let a = try? FileManager.default.attributesOfItem(atPath: d.path),
                  (a[.modificationDate] as? Date ?? .distantFuture) < since else { return false }
            guard a[.type] as? FileAttributeType == .typeDirectory else { continue }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: d.path) else { return false } // unknown counts as touched
            for name in names {
                looked += 1
                if looked > maxEntries { return false }
                let url = d.appendingPathComponent(name)
                let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
                if type != .typeSymbolicLink { stack.append(url) }
            }
        }
        return true
    }

    static func linkCount(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.referenceCount] as? NSNumber)?.intValue ?? 1
    }

    /// The same file on disk (a hard link), so trashing one frees nothing.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        guard let x = try? FileManager.default.attributesOfItem(atPath: a.path),
              let y = try? FileManager.default.attributesOfItem(atPath: b.path) else { return false }
        return (x[.systemFileNumber] as? NSNumber) == (y[.systemFileNumber] as? NSNumber)
            && (x[.systemNumber] as? NSNumber) == (y[.systemNumber] as? NSNumber)
    }

    public static let staleNodeModulesNote = "Stale node_modules, untouched for 6 months"

    /// Byte-identical files of the same size. Keeps the oldest of each set (on a tie, the one not named like a
    /// copy, then the one outside Downloads/Desktop); a spare is ticked only when it is in Downloads/Desktop or
    /// named like a copy. `kept` lists each set's kept file.
    static func duplicates(_ files: [FileRecord], inDownloadsOrDesktop: (FileRecord) -> Bool) -> (items: [CleanItem], kept: [URL]) {
        var out: [CleanItem] = []
        var kept: [URL] = []
        func copyNamed(_ f: FileRecord) -> Bool { Tidy.isLikelyCopyName(f.url.lastPathComponent) }
        for (_, sameSize) in Dictionary(grouping: files, by: \.size) where sameSize.count > 1 {
            var sets: [[FileRecord]] = []
            for f in sameSize.sorted(by: { $0.url.path < $1.url.path }) {
                if Task.isCancelled { return (out, kept) }
                if sets.contains(where: { $0.contains { sameFile($0.url, f.url) } }) { continue } // a hard link frees nothing
                if let i = sets.firstIndex(where: { identical($0[0].url, f.url) }) { sets[i].append(f) } else { sets.append([f]) }
            }
            for set in sets where set.count > 1 {
                let keep = set.min { a, b in
                    if a.oldest != b.oldest { return a.oldest < b.oldest }
                    if copyNamed(a) != copyNamed(b) { return !copyNamed(a) }
                    if inDownloadsOrDesktop(a) != inDownloadsOrDesktop(b) { return !inDownloadsOrDesktop(a) }
                    return a.url.path < b.url.path
                }!
                kept.append(keep.url)
                // A spare with another hard link frees nothing when trashed.
                for f in set where f.url != keep.url && linkCount(f.url) <= 1 {
                    let note = "Same as “\(keep.url.lastPathComponent)” in \(keep.url.deletingLastPathComponent().lastPathComponent)"
                    out.append(CleanItem(url: f.url, bytes: f.size, ticked: inDownloadsOrDesktop(f) || copyNamed(f), note: note, keep: keep.url))
                }
            }
        }
        return (out.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.url.path < $1.url.path }, kept)
    }

    /// Same bytes. Any open or read failure counts as different, so an unreadable file is never offered as a spare.
    static func identical(_ a: URL, _ b: URL,
                          read: (FileHandle) throws -> Data? = { try $0.read(upToCount: 65_536) }) -> Bool {
        guard let x = try? FileHandle(forReadingFrom: a), let y = try? FileHandle(forReadingFrom: b) else { return false }
        defer { try? x.close(); try? y.close() }
        do {
            while true {
                let p = try read(x) ?? Data(), q = try read(y) ?? Data()
                if p != q { return false }
                if p.isEmpty { return true }
            }
        } catch {
            return false
        }
    }

    /// F10.3 "downloaded": macOS marks downloads with a quarantine attribute. Elsewhere every file counts.
    static func wasDownloaded(_ url: URL) -> Bool {
        #if os(macOS)
        return getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
        #else
        return true
        #endif
    }

    /// `trash` is nil when the Trash can't be listed (no Full Disk Access), never a misleading zero.
    public static func diskSummary(home: URL) -> (free: Int64, total: Int64, used: Int64, trash: Int64?) {
        let disk = FileOps.diskInfo(for: home)
        let trash = (try? FileOps.trashSummary(home.appendingPathComponent(".Trash")))?.bytes
        return (disk.free, disk.total, max(0, disk.total - disk.free), trash)
    }

    // shortcut: F10.1's breakdown (Your files, Apps, macOS & system, Snapshots & system data) needs volume
    // usage APIs outside Foundation; only free, total, used and the Trash are shown until the app adds them
    // MARK: Reading the disk

    struct FileRecord: Sendable {
        let url: URL
        let size: Int64
        let created: Date
        let modified: Date
        var oldest: Date { min(created, modified) }
    }

    private static func letters(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter }) }

    private static func isRealDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    /// Regular, non-hidden files under `roots` to `maxDepth` levels, plus the node_modules folders met (not
    /// entered). Skips links, hidden folders and packages; at most `maxEntries` names are looked at.
    static func walk(_ roots: [URL], maxDepth: Int, maxEntries: Int = 100_000) -> (files: [FileRecord], nodeModules: [FileRecord]) {
        var files: [FileRecord] = [], nodeModules: [FileRecord] = []
        var looked = 0
        var stack: [(URL, Int)] = roots.reversed().map { ($0, 1) }
        while let (dir, depth) = stack.popLast(), looked < maxEntries, !Task.isCancelled {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                looked += 1
                if looked > maxEntries { break }
                let url = dir.appendingPathComponent(name)
                guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
                let record = FileRecord(url: url, size: (a[.size] as? NSNumber)?.int64Value ?? 0,
                                        created: a[.creationDate] as? Date ?? .distantFuture,
                                        modified: a[.modificationDate] as? Date ?? .distantFuture)
                switch a[.type] as? FileAttributeType {
                case .typeDirectory:
                    if name == "node_modules" { nodeModules.append(record) }
                    else if depth < maxDepth, !isPackage(url) { stack.append((url, depth + 1)) }
                case .typeRegular: files.append(record)
                default: break
                }
            }
        }
        return (files, nodeModules)
    }

    private static func isPackage(_ url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return true }
        // Linux has no package registry; these are the bundles the scanned folders usually hold.
        let ext = url.pathExtension.lowercased()
        return ["app", "bundle", "framework", "photoslibrary", "xcodeproj", "xcworkspace", "pages", "numbers", "key"].contains(ext)
    }

    /// The items directly in `dir` (not hidden, no links).
    private static func topLevel(_ dir: URL) -> [Entry] {
        ((try? FileOps.listDirectory(dir)) ?? []).filter { !$0.isSymlink }.sorted { $0.name < $1.name }
    }

    private static func bytes(_ e: Entry) -> Int64 { e.isDirectory ? FileOps.directorySize(e.url, maxEntries: 50_000).bytes : e.size }

    private static func item(_ e: Entry) -> CleanItem { CleanItem(url: e.url, bytes: bytes(e), ticked: false) }
}
