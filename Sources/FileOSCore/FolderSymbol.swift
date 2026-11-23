import Foundation

/// F13.1: the SF Symbol a folder shows when the user hasn't chosen one.
public enum FolderSymbol {
    public static let code = "chevron.left.forwardslash.chevron.right"
    public static let foldersOnly = "folder.fill"
    public static let empty = "folder"
    public static let mixed = "square.grid.2x2"
    public static let locked = "lock"

    public static func symbol(for kind: FileKind) -> String {
        switch kind {
        case .pdfs: return "doc.richtext"
        case .images: return "photo"
        case .screenshots: return "camera.viewfinder"
        case .videos: return "film"
        case .installers: return "shippingbox"
        case .archives: return "doc.zipper"
        case .audio: return "music.note"
        case .documents: return "doc.text"
        case .other: return "doc"
        }
    }

    private static let special: [(String, String)] = [
        ("Desktop", "menubar.dock.rectangle"), ("Documents", "doc"), ("Downloads", "arrow.down.circle"),
        ("Movies", "film"), ("Music", "music.note"), ("Pictures", "photo"), ("Applications", "app"),
    ]

    private static let words: [(Set<String>, String)] = [
        (["invoice", "invoices", "bill", "bills", "receipt", "receipts"], "receipt"),
        (["tax", "taxes", "budget", "budgets"], "dollarsign.circle"),
        (["school"], "graduationcap"),
        (["travel", "trip", "trips"], "airplane"),
        (["client", "clients", "work"], "briefcase"),
        (["backup", "backups", "archive", "archives"], "archivebox"),
        (["recipe", "recipes"], "fork.knife"),
    ]

    private static let projectMarkers: Set<String> = [".git", "package.json", "Package.swift", "Cargo.toml", "go.mod"]

    /// Reads one level of `dir` (at most `maxEntries` names), never following links.
    public static func automatic(for dir: URL, home: URL, maxEntries: Int = 500) -> String {
        let path = FileOps.canonical(dir).path
        let homePath = FileOps.canonical(home).path
        if path == homePath { return "house" }
        if path == "/Applications" { return "app" }
        for (name, symbol) in special where path == FileOps.canonical(home.appendingPathComponent(name)).path { return symbol }

        let nameWords = Set(dir.lastPathComponent.lowercased().split { !$0.isLetter }.map(String.init))
        for (set, symbol) in words where !set.isDisjoint(with: nameWords) { return symbol }

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return locked }
        if names.contains(where: { projectMarkers.contains($0) || $0.hasSuffix(".xcodeproj") }) { return code }

        var counts: [FileKind: Int] = [:]
        var files = 0, folders = 0
        for name in names.prefix(maxEntries) where !name.hasPrefix(".") {
            guard let type = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.type]
                    as? FileAttributeType else { continue }
            switch type {
            case .typeDirectory: folders += 1
            case .typeRegular:
                files += 1
                counts[FileKind.of(name), default: 0] += 1
            default: break
            }
        }
        if files == 0 { return folders > 0 ? foldersOnly : empty }
        let ranked = counts.sorted { $0.value > $1.value }
        // "Mostly <kind>" (≥ 3 files, ≥ 60%) and "more of one kind" both show the kind; a tie is mixed.
        if let top = ranked.first, ranked.count == 1 || top.value > ranked[1].value { return symbol(for: top.key) }
        return mixed
    }
}
