import Foundation

/// A folder, file or link listed in a workspace (F11.2). Only a reference: nothing is copied or moved.
public struct WorkspaceItem: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case folder, file, link }
    public var id: UUID
    public var kind: Kind
    public var path: String?
    public var url: String?
    public var pinned: Bool

    public init(id: UUID = UUID(), kind: Kind, path: String? = nil, url: String? = nil, pinned: Bool = false) {
        self.id = id; self.kind = kind; self.path = path; self.url = url; self.pinned = pinned
    }

    public static func file(_ path: String, isFolder: Bool) -> WorkspaceItem {
        WorkspaceItem(kind: isFolder ? .folder : .file, path: path)
    }

    public static func link(_ url: String) -> WorkspaceItem { WorkspaceItem(kind: .link, url: url) }

    /// What "the same item" means when adding: the same path, or the same address.
    var key: String { kind == .link ? "url:\(url ?? "")" : "path:\(path ?? "")" }

    public var name: String {
        if kind == .link { return url.flatMap { URL(string: $0)?.host } ?? url ?? "" }
        return ((path ?? "") as NSString).lastPathComponent
    }
}

public struct Workspace: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var description: String
    public var color: String
    public var items: [WorkspaceItem]
    public var archived: Bool
    public var created: Date

    public init(id: UUID = UUID(), name: String, description: String = "", color: String = "blue",
                items: [WorkspaceItem] = [], archived: Bool = false, created: Date = Date()) {
        self.id = id; self.name = name; self.description = description; self.color = color
        self.items = items; self.archived = archived; self.created = created
    }

    public var pinned: [WorkspaceItem] { items.filter(\.pinned) }
}

public enum WorkspaceError: Error, Equatable, LocalizedError {
    case tooManyPins, emptyName

    public var errorDescription: String? {
        switch self {
        case .tooManyPins: return "You can pin up to six files"
        case .emptyName: return "Give the workspace a name"
        }
    }
}

/// F11.4: why an item can't be opened.
public enum ItemStatus: Equatable, Sendable {
    case ok, disconnected(String), missing

    public var text: String? {
        switch self {
        case .ok: return nil
        case .disconnected(let volume): return "“\(volume)” isn't connected"
        case .missing: return "Can't find it"
        }
    }
}

/// F11.3 page tabs.
public enum WorkspaceTab: String, CaseIterable, Sendable {
    case overview = "Overview", folders = "Folders", images = "Images", documents = "Documents", links = "Links"

    public func matches(_ item: WorkspaceItem) -> Bool {
        switch self {
        case .overview: return true
        case .folders: return item.kind == .folder
        case .links: return item.kind == .link
        case .images, .documents:
            guard item.kind == .file else { return false }
            let kind = FileKind.of(item.name)
            if self == .images { return kind == .images || kind == .screenshots }
            return kind == .documents || kind == .pdfs
        }
    }
}

/// Pure edits on the workspace list: each returns a new array, so undo is putting the previous one back.
public enum Workspaces {
    public static let maxPins = 6
    /// The sample workspace's fixed id, so "Remove Sample" and its tips can find it.
    public static let sampleID = UUID(uuidString: "A0C3E000-0000-4000-8000-000000000001")!
    public static let sampleTips = [
        "Nothing is copied or moved: a workspace only lists folders, files and links from anywhere.",
        "Drag things onto the workspace in the sidebar, or right-click a file > Add to Workspace.",
        "Copy a link and press ⌘V here to add it.",
        "Pin up to six items, then open them with ⌃⌥1–6.",
        "Open your first nine workspaces with ⌃1–⌃9.",
    ]

    public static func create(_ list: [Workspace], name: String, description: String, color: String,
                              now: Date = Date()) throws -> ([Workspace], Workspace) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceError.emptyName }
        let w = Workspace(name: trimmed, description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                          color: color, created: now)
        return (list + [w], w)
    }

    /// Adds the items not already listed (by path or address), in order.
    public static func add(_ list: [Workspace], to id: UUID, items: [WorkspaceItem]) -> [Workspace] {
        change(list, id) { w in
            var seen = Set(w.items.map(\.key))
            for item in items where seen.insert(item.key).inserted { w.items.append(item) }
        }
    }

    public static func remove(_ list: [Workspace], from id: UUID, items ids: Set<UUID>) -> [Workspace] {
        change(list, id) { w in w.items.removeAll { ids.contains($0.id) } }
    }

    public static func pin(_ list: [Workspace], in id: UUID, item: UUID, _ pinned: Bool) throws -> [Workspace] {
        guard let w = list.first(where: { $0.id == id }), let i = w.items.firstIndex(where: { $0.id == item }) else { return list }
        if pinned, !w.items[i].pinned, w.pinned.count >= maxPins { throw WorkspaceError.tooManyPins }
        return change(list, id) { $0.items[i].pinned = pinned }
    }

    /// Locate…: points a missing item at where it is now.
    public static func relocate(_ list: [Workspace], in id: UUID, item: UUID, to path: String, isFolder: Bool) -> [Workspace] {
        change(list, id) { w in
            guard let i = w.items.firstIndex(where: { $0.id == item }) else { return }
            w.items[i].path = path
            w.items[i].kind = isFolder ? .folder : .file
        }
    }

    public static func archive(_ list: [Workspace], _ id: UUID) -> [Workspace] { change(list, id) { $0.archived = true } }
    public static func restore(_ list: [Workspace], _ id: UUID) -> [Workspace] { change(list, id) { $0.archived = false } }
    public static func delete(_ list: [Workspace], _ id: UUID) -> [Workspace] { list.filter { $0.id != id } }

    public static func edit(_ list: [Workspace], _ id: UUID, name: String, description: String, color: String) -> [Workspace] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return change(list, id) { w in
            if !trimmed.isEmpty { w.name = trimmed }
            w.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
            w.color = color
        }
    }

    /// "Acme Project": a few real home folders and a link, with `sampleTips` shown above them.
    public static func sample(home: URL) -> Workspace {
        let items: [WorkspaceItem] = [
            .file(home.appendingPathComponent("Documents").path, isFolder: true),
            .file(home.appendingPathComponent("Desktop").path, isFolder: true),
            .file(home.appendingPathComponent("Downloads").path, isFolder: true),
            .link("https://www.apple.com/macos/"),
        ]
        return Workspace(id: sampleID, name: "Acme Project", description: "A sample workspace. Remove it any time.",
                         color: "orange", items: items)
    }

    public static func status(of item: WorkspaceItem, fileExists: (String) -> Bool,
                              volumeMounted: (String) -> Bool) -> ItemStatus {
        guard item.kind != .link, let path = item.path else { return .ok }
        if fileExists(path) { return .ok }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Volumes", !volumeMounted("/Volumes/\(parts[1])") {
            return .disconnected(String(parts[1]))
        }
        return .missing
    }

    private static func change(_ list: [Workspace], _ id: UUID, _ edit: (inout Workspace) -> Void) -> [Workspace] {
        var out = list
        if let i = out.firstIndex(where: { $0.id == id }) { edit(&out[i]) }
        return out
    }
}
