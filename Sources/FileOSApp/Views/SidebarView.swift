import SwiftUI
import FileOSCore

enum SidebarItem: Hashable {
    case folder(URL), page(Page)
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: selection) {
            Section("Favorites", isExpanded: expanded("Favorites")) {
                ForEach(model.standardFavorites + model.favorites, id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: Self.symbol(for: url.lastPathComponent))
                        .tag(SidebarItem.folder(url))
                }
            }
            Section("Tools", isExpanded: expanded("Tools")) {
                Label("Free Up Space", systemImage: "sparkles").tag(SidebarItem.page(.freeUpSpace))
                Label("Installed", systemImage: "shippingbox").tag(SidebarItem.page(.installed))
                Label("AI Agents", systemImage: "cpu").tag(SidebarItem.page(.agents))
            }
            Section("Locations", isExpanded: locationsExpanded) {
                Label(model.home.lastPathComponent, systemImage: "house").tag(SidebarItem.folder(model.home))
                Label(model.displayName(URL(fileURLWithPath: "/")), systemImage: "internaldrive")
                    .tag(SidebarItem.folder(URL(fileURLWithPath: "/")))
                ForEach(model.volumes, id: \.self) { url in
                    Label(model.displayName(url), systemImage: "externaldrive").tag(SidebarItem.folder(url))
                }
                Label("Trash", systemImage: "trash").tag(SidebarItem.folder(model.trashURL))
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { DiskLine() }
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { model.page == .browser ? .folder(model.pane.url) : .page(model.page) },
            set: { item in
                switch item {
                case .folder(let url)?: model.open(url)
                case .page(let page)?: model.page = page
                case nil: break
                }
            })
    }

    private var locationsExpanded: Binding<Bool> {
        Binding(get: { model.locationsExpanded }, set: { model.locationsExpanded = $0 })
    }

    private func expanded(_ section: String) -> Binding<Bool> {
        Binding(get: { model.isExpanded(section) }, set: { model.setExpanded(section, $0) })
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

/// F2.4: Mac name, disk bar (orange at 90% full or more), free space. Click opens About This Mac.
struct DiskLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let disk = FileOps.diskInfo(for: model.home)
        let used = disk.total > 0 ? Double(disk.total - disk.free) / Double(disk.total) : 0
        Button { model.page = .aboutMac } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.macName).font(.caption.weight(.semibold))
                ProgressView(value: used)
                    .tint(used >= 0.9 ? Color.orange : Color.accentColor)
                Text("\(formatBytes(disk.free)) available").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(formatBytes(disk.total - disk.free)) used of \(formatBytes(disk.total))")
        .accessibilityLabel("\(model.macName), \(formatBytes(disk.free)) available. Show About This Mac")
    }
}
