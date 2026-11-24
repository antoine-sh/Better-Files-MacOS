import SwiftUI
import AppKit
import FileOSCore

/// The status item's icon. It is always on screen, so it is also where the app keeps a way to open a window
/// once every window is closed (F1.6).
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "folder.fill")
            .accessibilityLabel("FileOS")
            .onAppear { model.openMainWindow = { openWindow(id: AppMain.mainWindowID) } }
    }
}

/// F15.3: latest 5 downloads, Quick access (6 folders + 2 recents + 4 workspaces), Add Folder…, a Holding
/// drop zone, Open FileOS, Settings….
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var downloads: [URL] = []

    /// Folders visited lately that aren't already in Quick access.
    private var recentFolders: [URL] {
        var out: [URL] = []
        for url in (model.pane.history + [model.pane.url]).reversed()
        where !model.quickAccess.contains(url) && !out.contains(url) && url != model.home {
            out.append(url)
        }
        return Array(out.prefix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MenuSection(title: "Downloads") {
                if downloads.isEmpty { Text("Nothing downloaded yet").font(.caption).foregroundStyle(.secondary) }
                ForEach(downloads, id: \.self) { (url: URL) in
                    MenuRow(url: url, action: { reveal(url) }).onDrag { NSItemProvider(object: url as NSURL) }
                }
            }
            MenuSection(title: "Quick Access") { quickAccess }
            HoldingWell()
            Divider()
            HStack {
                Button("Open FileOS", action: { act { model.showMainWindow() } })
                Spacer()
                SettingsLink { Text("Settings…") }
            }
        }
        .padding(12)
        .frame(width: 300)
        .task { await loadDownloads() }
    }

    @ViewBuilder private var quickAccess: some View {
        ForEach(model.quickAccess.prefix(6), id: \.self) { (url: URL) in
            MenuRow(url: url, action: { act { model.openInFileOS(url) } })
                .contextMenu { Button("Remove from Quick Access", action: { model.removeFromQuickAccess([url]) }) }
        }
        ForEach(recentFolders, id: \.self) { (url: URL) in
            MenuRow(url: url, action: { act { model.openInFileOS(url) } })
        }
        ForEach(model.activeWorkspaces.prefix(4)) { (w: Workspace) in
            Button(action: { act { openWorkspace(w.id) } }) {
                Label(w.name, systemImage: "circle.fill").foregroundStyle(workspaceColor(w.color))
            }
            .buttonStyle(.plain)
        }
        Button("Add Folder…", action: { addFolder() })
    }

    private func act(_ action: () -> Void) {
        action()
        dismiss()
    }

    private func openWorkspace(_ id: UUID) {
        model.showMainWindow()
        model.page = .workspace(id)
    }

    /// A download opens its folder in FileOS with it selected.
    private func reveal(_ url: URL) {
        act {
            model.showMainWindow()
            model.page = .browser
            model.pane.navigate(to: url.deletingLastPathComponent(), select: url)
        }
    }

    private func addFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { model.addToQuickAccess(panel.urls) }
    }

    private func loadDownloads() async {
        let folder: URL = model.home.appendingPathComponent("Downloads")
        downloads = await Task.detached { () -> [URL] in Recents.latest(in: [folder], limit: 5, includeFolders: true) }.value
    }
}

private struct MenuSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

private struct MenuRow: View {
    let url: URL
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: { action() }) {
            HStack(spacing: 6) {
                FileIcon(url: url, side: 16)
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
