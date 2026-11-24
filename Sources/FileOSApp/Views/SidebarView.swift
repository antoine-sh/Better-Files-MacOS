import SwiftUI
import FileOSCore

enum SidebarItem: Hashable, Sendable {
    case folder(URL), page(Page), bookmarks(BookmarkPlace)
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    // Plain @State instead of Binding(get:set:): Swift 6.1's IRGen crashed on the
    // isolation thunk for a Binding<SidebarItem?> built from closures.
    @State private var selection: SidebarItem?
    @State private var workspacesOpen = true
    @State private var bookmarksOpen = true
    @State private var favoritesOpen = true
    @State private var toolsOpen = true
    @State private var locationsOpen = false // F2.1: Locations always starts folded

    var body: some View {
        List(selection: $selection) {
            SidebarRow(title: "Home", symbol: "house.fill", item: .page(.home)) // F16.1
            WorkspacesSection(open: $workspacesOpen)
            BookmarksSection(open: $bookmarksOpen)
            favorites
            tools
            locations
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { DiskLine() }
        .onAppear { loadState() }
        .onChange(of: selection) { applySelection() }
        .onChange(of: model.page) { syncSelection() }
        .onChange(of: model.pane.url) { syncSelection() }
        .onChange(of: model.bookmarkPlace) { syncSelection() }
        .onChange(of: workspacesOpen) { model.setExpanded("Workspaces", workspacesOpen) }
        .onChange(of: bookmarksOpen) { model.setExpanded("Bookmarks", bookmarksOpen) }
        .onChange(of: favoritesOpen) { model.setExpanded("Favorites", favoritesOpen) }
        .onChange(of: toolsOpen) { model.setExpanded("Tools", toolsOpen) }
    }

    private var favorites: some View {
        Section("Favorites", isExpanded: $favoritesOpen) {
            ForEach(model.standardFavorites, id: \.self) { (url: URL) in
                FolderRow(title: url.lastPathComponent, symbol: Self.symbol(for: url.lastPathComponent), url: url)
            }
            ForEach(model.favorites, id: \.self) { (url: URL) in
                FolderRow(title: url.lastPathComponent, symbol: "folder", url: url)
                    .contextMenu { Button("Remove from Sidebar", action: { model.removeFromSidebar(url) }) }
            }
        }
    }

    private var tools: some View {
        Section("Tools", isExpanded: $toolsOpen) {
            SidebarRow(title: "Free Up Space", symbol: "sparkles", item: .page(.freeUpSpace))
            SidebarRow(title: "Installed", symbol: "shippingbox", item: .page(.installed))
            SidebarRow(title: "AI Agents", symbol: "cpu", item: .page(.agents))
        }
    }

    private var locations: some View {
        Section("Locations", isExpanded: $locationsOpen) {
            FolderRow(title: model.home.lastPathComponent, symbol: "house", url: model.home)
            FolderRow(title: model.displayName(Self.root), symbol: "internaldrive", url: Self.root)
            ForEach(model.volumes, id: \.self) { (url: URL) in VolumeRow(url: url) }
            SidebarRow(title: "Trash", symbol: "trash", item: .folder(model.trashURL)) // F2.3: takes no drops
        }
    }

    private static let root = FileOps.canonical(URL(fileURLWithPath: "/"))

    private func currentItem() -> SidebarItem {
        if model.page == .browser { return .folder(model.pane.url) }
        if model.page == .bookmarks { return .bookmarks(model.bookmarkPlace) }
        return .page(model.page)
    }

    private func loadState() {
        workspacesOpen = model.isExpanded("Workspaces")
        bookmarksOpen = model.isExpanded("Bookmarks")
        favoritesOpen = model.isExpanded("Favorites")
        toolsOpen = model.isExpanded("Tools")
        syncSelection()
    }

    private func syncSelection() {
        let current: SidebarItem = currentItem()
        if selection != current { selection = current }
    }

    private func applySelection() {
        guard let item = selection, item != currentItem() else { return }
        switch item {
        case .folder(let url): model.open(url)
        case .page(let page): model.page = page
        case .bookmarks(let place):
            model.bookmarkPlace = place
            model.page = .bookmarks
        }
    }

    static func symbol(for name: String) -> String {
        switch name {
        case "Desktop": return "menubar.dock.rectangle"
        case "Documents": return "doc"
        case "Downloads": return "arrow.down.circle"
        case "Pictures": return "photo"
        default: return "folder"
        }
    }
}

/// F2.1 Workspaces (+ / ⌥⌘N). Drops add the items; nothing moves (F2.3).
private struct WorkspacesSection: View {
    @Binding var open: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        Section(isExpanded: $open) {
            ForEach(model.workspaces) { (w: Workspace) in WorkspaceRow(workspace: w) }
        } header: {
            HStack {
                Text("Workspaces")
                Spacer()
                Button(action: { model.newWorkspace() }) { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New Workspace (⌥⌘N)")
                    .accessibilityLabel("New Workspace")
            }
        }
    }
}

private struct WorkspaceRow: View {
    let workspace: Workspace
    @Environment(AppModel.self) private var model

    var body: some View {
        Label {
            Text(workspace.name).foregroundStyle(workspace.archived ? Color.secondary : Color.primary)
        } icon: {
            Image(systemName: workspace.archived ? "archivebox" : "circle.fill")
                .foregroundStyle(workspaceColor(workspace.color))
        }
        .tag(SidebarItem.page(.workspace(workspace.id)))
        .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in
            model.addToWorkspace(workspace.id, urls)
            return true
        }
        .contextMenu { WorkspaceRowMenu(workspace: workspace) }
    }
}

private struct WorkspaceRowMenu: View {
    let workspace: Workspace
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Edit Workspace…", action: { model.editWorkspace(workspace.id) })
        if workspace.archived {
            Button("Restore", action: { model.restoreWorkspace(workspace.id) })
        } else {
            Button("Archive", action: { model.archiveWorkspace(workspace.id) })
        }
        Button("Delete…", action: { model.askDeleteWorkspace(workspace.id) })
    }
}

/// F2.1 Bookmarks: All Bookmarks, Favourites, Unsorted, collections. Dropped links are saved (F2.3).
private struct BookmarksSection: View {
    @Binding var open: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Bookmarks", isExpanded: $open) {
            BookmarkPlaceRow(title: "All Bookmarks", symbol: "bookmark", place: .all, collection: nil)
            BookmarkPlaceRow(title: "Favourites", symbol: "star", place: .favourites, collection: nil)
            BookmarkPlaceRow(title: "Unsorted", symbol: "tray", place: .unsorted, collection: nil)
            ForEach(model.bookmarkState.collections) { (c: BookmarkCollection) in
                BookmarkPlaceRow(title: c.name, symbol: c.icon, place: .collection(c.id), collection: c.id)
                    .contextMenu { Button("Delete Collection…", action: { model.askDeleteCollection(c.id) }) }
            }
        }
    }
}

private struct BookmarkPlaceRow: View {
    let title: String
    let symbol: String
    let place: BookmarkPlace
    let collection: UUID?
    @Environment(AppModel.self) private var model

    var body: some View {
        Label(title, systemImage: symbol)
            .tag(SidebarItem.bookmarks(place))
            .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in
                model.saveLinks(urls, collection: collection)
                return true
            }
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let item: SidebarItem

    var body: some View {
        Label(title, systemImage: symbol).tag(item)
    }
}

/// A favourite or location: opens the folder; drops move there (same disk) or copy (other disk, ⌥), F2.3.
private struct FolderRow: View {
    let title: String
    let symbol: String
    let url: URL
    @Environment(AppModel.self) private var model

    var body: some View {
        Label(title, systemImage: symbol)
            .tag(SidebarItem.folder(url))
            .modifier(FolderDrop(url: url))
    }
}

private struct FolderDrop: ViewModifier {
    let url: URL
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in
            let files: [URL] = urls.filter { (u: URL) -> Bool in u.isFileURL }
            guard !files.isEmpty else { return false }
            let folder: URL = url
            Task { await model.drop(files, into: folder) }
            return true
        }
    }
}

/// A connected drive with its ⏏ button and Eject in the right-click menu (F2.6).
private struct VolumeRow: View {
    let url: URL
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Label(model.displayName(url), systemImage: "externaldrive")
            Spacer()
            Button(action: { eject() }) { Image(systemName: "eject") }
                .buttonStyle(.borderless)
                .help("Eject")
                .accessibilityLabel("Eject \(model.displayName(url))")
        }
        .tag(SidebarItem.folder(url))
        .modifier(FolderDrop(url: url))
        .contextMenu { Button("Eject", action: { eject() }) }
    }

    private func eject() { model.eject(url) }
}

/// F2.4: Mac name, disk bar (orange at 90% full or more), free space. Click opens About This Mac.
struct DiskLine: View {
    @Environment(AppModel.self) private var model

    private var disk: (total: Int64, free: Int64) { FileOps.diskInfo(for: model.home) }
    private var macName: String { model.macName }

    static func usedFraction(total: Int64, free: Int64) -> Double {
        guard total > 0 else { return 0 }
        return Double(total - free) / Double(total)
    }

    var body: some View {
        Button(action: { showAbout() }) { content(disk) }
            .buttonStyle(.plain)
            .help(Self.hoverText(disk))
            .accessibilityLabel(Self.accessibilityText(macName, disk))
    }

    private func showAbout() { model.page = .aboutMac }

    private func content(_ disk: (total: Int64, free: Int64)) -> some View {
        let used: Double = Self.usedFraction(total: disk.total, free: disk.free)
        let tint: Color = used >= 0.9 ? Color.orange : Color.accentColor
        let freeText: String = "\(formatBytes(disk.free)) available"
        return VStack(alignment: .leading, spacing: 4) {
            Text(macName).font(.caption.weight(.semibold))
            ProgressView(value: used).tint(tint)
            Text(freeText).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    static func hoverText(_ disk: (total: Int64, free: Int64)) -> String {
        let used: String = formatBytes(disk.total - disk.free)
        let total: String = formatBytes(disk.total)
        return "\(used) used of \(total)"
    }

    static func accessibilityText(_ name: String, _ disk: (total: Int64, free: Int64)) -> String {
        let free: String = formatBytes(disk.free)
        return "\(name), \(free) available. Show About This Mac"
    }
}
