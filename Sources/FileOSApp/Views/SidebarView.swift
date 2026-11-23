import SwiftUI
import FileOSCore

enum SidebarItem: Hashable {
    case folder(URL), page(Page)
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: selection) {
            favorites
            tools
            locations
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { DiskLine() }
    }

    private var favorites: some View {
        Section("Favorites", isExpanded: expanded("Favorites")) {
            ForEach(favoriteURLs, id: \.self) { (url: URL) in
                SidebarRow(title: url.lastPathComponent, symbol: Self.symbol(for: url.lastPathComponent),
                           item: .folder(url))
            }
        }
    }

    private var tools: some View {
        Section("Tools", isExpanded: expanded("Tools")) {
            SidebarRow(title: "Free Up Space", symbol: "sparkles", item: .page(.freeUpSpace))
            SidebarRow(title: "Installed", symbol: "shippingbox", item: .page(.installed))
            SidebarRow(title: "AI Agents", symbol: "cpu", item: .page(.agents))
        }
    }

    private var locations: some View {
        Section("Locations", isExpanded: locationsExpanded) {
            SidebarRow(title: model.home.lastPathComponent, symbol: "house", item: .folder(model.home))
            SidebarRow(title: model.displayName(Self.root), symbol: "internaldrive", item: .folder(Self.root))
            ForEach(model.volumes, id: \.self) { (url: URL) in
                SidebarRow(title: model.displayName(url), symbol: "externaldrive", item: .folder(url))
            }
            SidebarRow(title: "Trash", symbol: "trash", item: .folder(model.trashURL))
        }
    }

    private static let root = FileOps.canonical(URL(fileURLWithPath: "/"))

    private var favoriteURLs: [URL] {
        var urls: [URL] = model.standardFavorites
        urls.append(contentsOf: model.favorites)
        return urls
    }

    private var selection: Binding<SidebarItem?> {
        Binding<SidebarItem?>(get: currentItem, set: activate)
    }

    private func currentItem() -> SidebarItem? {
        if model.page == .browser { return .folder(model.pane.url) }
        return .page(model.page)
    }

    private func activate(_ item: SidebarItem?) {
        switch item {
        case .folder(let url)?: model.open(url)
        case .page(let page)?: model.page = page
        case nil: break
        }
    }

    private var locationsExpanded: Binding<Bool> {
        Binding<Bool>(get: { model.locationsExpanded }, set: { (value: Bool) in model.locationsExpanded = value })
    }

    private func expanded(_ section: String) -> Binding<Bool> {
        Binding<Bool>(get: { model.isExpanded(section) }, set: { (value: Bool) in model.setExpanded(section, value) })
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

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let item: SidebarItem

    var body: some View {
        Label(title, systemImage: symbol).tag(item)
    }
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
        Button(action: showAbout) { content(disk) }
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
