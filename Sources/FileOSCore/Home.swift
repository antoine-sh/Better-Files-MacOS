import Foundation

/// F16.1: the Home page greeting.
public enum Greeting {
    public static func text(hour: Int) -> String {
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }
}

/// F16.1: the parts Customize shows or hides, stored as `home.widgets` (id → shown; missing means shown).
public enum HomePart: String, CaseIterable, Codable, Sendable {
    case worldClock, today, diskSpace, downloadsInbox, photoFrame, pinnedFolder, recentFiles

    public var title: String {
        switch self {
        case .worldClock: return "World Clock"
        case .today: return "Today"
        case .diskSpace: return "Disk Space"
        case .downloadsInbox: return "Downloads Inbox"
        case .photoFrame: return "Photo Frame"
        case .pinnedFolder: return "Pinned Folder"
        case .recentFiles: return "Recent Files"
        }
    }

    public func isShown(in map: [String: Bool]) -> Bool { map[rawValue] ?? true }
}

/// Recently changed items directly inside some folders (no recursion), newest first.
public enum Recents {
    // shortcut: modification date, not Date Added or the system's "last opened"; use Spotlight's kMDItemLastUsedDate if asked
    public static func latest(in dirs: [URL], limit: Int, includeFolders: Bool) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        var found: [(url: URL, date: Date)] = []
        for dir in dirs {
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                     options: [.skipsHiddenFiles])) ?? []
            for url in urls {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true && !includeFolders { continue }
                found.append((url, values?.contentModificationDate ?? .distantPast))
            }
        }
        return found.sorted { $0.date > $1.date }.prefix(limit).map(\.url)
    }
}

/// F5.15: the quick actions (⌘. or a 0.5 s press). Settings > Quick Actions stores the chosen order as `quickActions`.
public enum QuickAction: String, CaseIterable, Codable, Sendable {
    case open, peek, rename, duplicate, copyPath, showInFinder, airDrop, addToHolding, pinToDropShelf, addToQuickAccess, trash

    public static let defaults: [QuickAction] = [.open, .peek, .rename, .copyPath, .addToHolding, .trash]

    public var title: String {
        switch self {
        case .open: return "Open"
        case .peek: return "Peek"
        case .rename: return "Rename…"
        case .duplicate: return "Duplicate"
        case .copyPath: return "Copy Path"
        case .showInFinder: return "Show in Finder"
        case .airDrop: return "AirDrop…"
        case .addToHolding: return "Add to Holding"
        case .pinToDropShelf: return "Pin to Drop Shelf"
        case .addToQuickAccess: return "Add to Quick Access"
        case .trash: return "Move to Trash"
        }
    }

    public var symbol: String {
        switch self {
        case .open: return "arrow.up.forward.app"
        case .peek: return "eye"
        case .rename: return "pencil"
        case .duplicate: return "plus.square.on.square"
        case .copyPath: return "link"
        case .showInFinder: return "magnifyingglass"
        case .airDrop: return "airplayaudio"
        case .addToHolding: return "tray.and.arrow.down"
        case .pinToDropShelf: return "pin"
        case .addToQuickAccess: return "star"
        case .trash: return "trash"
        }
    }

    /// The stored order (nil: never set), without unknown ids or repeats, at most six.
    public static func ordered(_ stored: [String]?) -> [QuickAction] {
        guard let stored else { return defaults }
        var out: [QuickAction] = []
        for id in stored {
            guard let action = QuickAction(rawValue: id), !out.contains(action) else { continue }
            out.append(action)
        }
        return Array(out.prefix(6))
    }
}

/// F15.1: the line under the Drop Shelf after a drop.
public enum DropShelfText {
    public static func result(names: [String], folder: String, copied: Bool) -> String {
        let what = names.count == 1 ? "“\(names[0])”" : "\(names.count) items"
        return "Just now: \(copied ? "Copied" : "Moved") \(what) to \(folder)"
    }
}

extension KeyCombo {
    /// A global shortcut (the Drop Shelf's) must include ⌘, ⌥ or ⌃, or it would take a key from every app.
    public var canBeGlobal: Bool { command || option || control }
}
