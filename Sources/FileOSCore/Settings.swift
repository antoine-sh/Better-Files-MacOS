import Foundation

/// The app's own settings (F17), stored as one value under "settings". State that earlier features already
/// keep under their own keys (shortcuts, quick actions, Open In defaults, Drop Shelf pins, Holding, Home
/// widgets, hidden files, view, sort and group) stays there; Settings reads and writes those keys.
public struct AppSettings: Codable, Equatable, Sendable {
    public enum Appearance: String, Codable, CaseIterable, Sendable { case light, dark, system }
    public enum FolderStyle: String, Codable, CaseIterable, Sendable { case glass, plain, flat, finder }
    public enum SidebarSize: String, Codable, CaseIterable, Sendable { case small, medium, large }
    public enum Motion: String, Codable, CaseIterable, Sendable {
        case none, quiet, glide, zoom

        /// Reduce Motion turns any movement into a fade.
        public func transition(reduceMotion: Bool) -> Transition {
            switch self {
            case .none: return .none
            case .quiet: return .fade
            case .glide: return reduceMotion ? .fade : .slide
            case .zoom: return reduceMotion ? .fade : .zoom
            }
        }
    }
    /// What a folder change looks like.
    public enum Transition: Equatable, Sendable {
        case none, fade, slide, zoom

        public var seconds: Double {
            switch self {
            case .none: return 0
            case .fade: return 0.15
            case .slide: return 0.25
            case .zoom: return 0.3
            }
        }
    }
    /// The folder-open sound; `.off` is the default (F17.4).
    public enum Sound: String, Codable, CaseIterable, Sendable { case off, soft, click, wood, mac }

    public var appearance: Appearance = .system
    /// "mac" (the Mac's accent colour), one of `accents`, or "#RRGGBB".
    public var accent = "mac"
    public var folderStyle: FolderStyle = .glass
    /// "accent" or a folder colour name ("blue", "teal" …).
    public var folderColor = "accent"
    public var sidebarSize: SidebarSize = .medium
    public var motion: Motion = .quiet
    public var sound: Sound = .off
    /// ⌫ alone moves the selection to the Trash (otherwise only ⌘⌫ does).
    public var backspaceTrashes = false
    /// F1.7: reopen the last folders, layout and active pane.
    public var startInLastFolder = true
    /// Empty: ~/Downloads.
    public var downloadsPath = ""
    /// Show the Drop Shelf when a file drag starts (F15.1).
    public var dropShelfOnDrag = true
    public var menuBar = true
    /// Optional toolbar buttons (F1.2, Settings > Window > Toolbar).
    public var toolbarNewFolder = false
    public var toolbarTrash = false
    public var welcomed = false
    /// The release whose What's New was last shown (F1.10).
    public var whatsNewSeen = ""

    public static let accents = ["mac", "purple", "blue", "pink", "red", "orange", "yellow", "green", "graphite"]

    public init() {}

    /// Field by field: a missing, unknown or damaged value takes its default, so old and newer files keep working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        appearance = c.value(.appearance, d.appearance)
        accent = c.value(.accent, d.accent)
        folderStyle = c.value(.folderStyle, d.folderStyle)
        folderColor = c.value(.folderColor, d.folderColor)
        sidebarSize = c.value(.sidebarSize, d.sidebarSize)
        motion = c.value(.motion, d.motion)
        sound = c.value(.sound, d.sound)
        backspaceTrashes = c.value(.backspaceTrashes, d.backspaceTrashes)
        startInLastFolder = c.value(.startInLastFolder, d.startInLastFolder)
        downloadsPath = c.value(.downloadsPath, d.downloadsPath)
        dropShelfOnDrag = c.value(.dropShelfOnDrag, d.dropShelfOnDrag)
        menuBar = c.value(.menuBar, d.menuBar)
        toolbarNewFolder = c.value(.toolbarNewFolder, d.toolbarNewFolder)
        toolbarTrash = c.value(.toolbarTrash, d.toolbarTrash)
        welcomed = c.value(.welcomed, d.welcomed)
        whatsNewSeen = c.value(.whatsNewSeen, d.whatsNewSeen)
    }

    /// "#RRGGBB" as 0…1 components; nil for anything else.
    public static func rgb(hex: String) -> (r: Double, g: Double, b: Double)? {
        guard hex.hasPrefix("#"), hex.count == 7, let n = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((n >> 16) & 0xFF) / 255, Double((n >> 8) & 0xFF) / 255, Double(n & 0xFF) / 255)
    }
}

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

/// F17.1: the settings search box keeps rows whose section or title contain every word typed.
public enum SettingsSearch {
    public static func matches(_ query: String, section: String, row: String) -> Bool {
        let words = query.split(separator: " ")
        let text = "\(section) \(row)"
        return words.allSatisfy { text.localizedCaseInsensitiveContains($0) }
    }

    public static func visible(_ query: String, section: String, rows: [String]) -> Bool {
        rows.contains { matches(query, section: section, row: $0) }
    }
}

/// F1.5, without the license step (F1.8 is skipped).
public enum WelcomeStep: String, CaseIterable, Sendable {
    case demo, tour, moveToApplications, fullDiskAccess, makeYours

    public static func steps(offerMove: Bool) -> [WelcomeStep] {
        allCases.filter { offerMove || $0 != .moveToApplications }
    }

    /// Only an app bundle outside /Applications is offered "Move and Reopen" (a bare `swift run` binary can't move).
    public static func offersMove(bundlePath: String) -> Bool {
        bundlePath.hasSuffix(".app") && !bundlePath.hasPrefix("/Applications/")
    }
}

/// F1.10.
public enum Release {
    public static let version = "1.0"
    public static let notes = [
        "Settings: appearance, accent colour, folder style, motion and sound.",
        "Change any shortcut in Settings > Shortcuts.",
        "FileOS reopens your folders and layout where you left them.",
    ]

    /// After an update only: a new user sees the welcome instead.
    public static func showsWhatsNew(_ settings: AppSettings) -> Bool {
        settings.welcomed && settings.whatsNewSeen != version
    }
}

extension KeyCombo {
    /// A removed shortcut (⌫ in Settings > Shortcuts): no key, never matches, never conflicts.
    public static let none = KeyCombo(key: "")
    public var isNone: Bool { key.isEmpty }
}

extension Shortcuts {
    private static let titles = ["goICloud": "Go iCloud Drive", "viewF3": "View (F3)"]

    /// "pinnedWorkspace3" → "Pinned Workspace 3", for Settings > Shortcuts.
    public static func title(_ id: String) -> String {
        if let fixed = titles[id] { return fixed }
        var out = ""
        var previous: Character?
        for c in id {
            if c.isUppercase || (c.isNumber && previous?.isLowercase == true) { out.append(" ") }
            out.append(out.isEmpty ? Character(c.uppercased()) : c)
            previous = c
        }
        return out
    }
}
