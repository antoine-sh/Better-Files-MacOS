import Foundation

/// F2.1 Locations above home: iCloud Drive (when set up), then each cloud drive in ~/Library/CloudStorage by name.
public enum CloudLocations {
    public static func list(home: URL) -> [URL] {
        let fm = FileManager.default
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let drives = ((try? fm.contentsOfDirectory(at: home.appendingPathComponent("Library/CloudStorage"),
                                                   includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter(PathBar.isDir)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return (fm.fileExists(atPath: icloud.path) ? [icloud] : []) + drives
    }
}

/// F2.1 Tags: files carrying a Finder tag, found with Spotlight.
public enum FinderTags {
    public static let colors = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]

    /// nil: every tagged file ("All Tags…"). A failed or timed-out search finds nothing.
    public static func files(tagged tag: String?, runner: CommandRunner) async -> [URL] {
        let name = (tag ?? "*").filter { $0 != "'" && $0 != "\\" } // stays inside the quoted query
        guard let out = try? await runner.run("mdfind", ["kMDItemUserTags == '\(name)'"], timeout: 10),
              out.status == 0 else { return [] }
        return out.stdout.split(separator: "\n").filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: String($0)) }
    }
}

/// F16.1: an emoji placed on Home; `x`/`y` are its centre in points from the page's top left.
public struct Sticker: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var emoji: String
    public var x: Double
    public var y: Double

    public init(id: UUID = UUID(), emoji: String, x: Double, y: Double) {
        self.id = id; self.emoji = emoji; self.x = x; self.y = y
    }

    public static let choices = ["⭐️", "❤️", "🌈", "🚀", "🎉", "🌿", "☕️", "🐱"]
}
