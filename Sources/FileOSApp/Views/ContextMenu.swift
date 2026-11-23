import SwiftUI
import AppKit
import FileOSCore

/// F3.10: the right-click menu for items, or (with no ids) for the folder's background.
// shortcut: Peek, Quick Look, Choose Symbol…, Colour, Add to Workspace and Pin to Drop Shelf join
// this menu with their features (Tasks 7–11)
struct FileContextMenu: View {
    let ids: Set<String>
    @Environment(AppModel.self) private var model

    private var urls: [URL] { ids.sorted().map { (p: String) -> URL in URL(fileURLWithPath: p) } }

    var body: some View {
        if ids.isEmpty { background } else { items }
    }

    @ViewBuilder private var items: some View {
        Group {
            Button("Open", action: { model.openSelection(ids) })
            OpenWithMenu(urls: urls)
            Divider()
            Button(urls.count == 1 ? "Rename…" : "Rename \(urls.count) Items…", action: { model.beginRename(urls) })
            Button("Duplicate", action: { model.duplicate(urls) })
            Button("Make Alias", action: { model.makeAlias(urls) })
            Divider()
        }
        Group {
            Button("Copy", action: { model.copy(urls) })
            Button("Cut", action: { model.copy(urls, cut: true) })
            pasteInto
            Button("Copy Path", action: { model.copyPath(urls) })
            Divider()
        }
        Group {
            Button("Show in Finder", action: { model.showInFinder(urls) })
            Button("Add to Sidebar", action: { model.addToSidebar(urls) })
            Button("AirDrop…", action: { model.airDrop(urls) })
                .disabled(!model.canAirDrop(urls))
            Divider()
            Button("Move to Trash", action: { model.trash(urls) })
        }
    }

    /// "Paste into “folder”" when one folder is chosen (F5.1).
    @ViewBuilder private var pasteInto: some View {
        if urls.count == 1, let folder = urls.first, AppModel.isBrowsableFolder(folder) {
            Button("Paste into “\(folder.lastPathComponent)”", action: { paste(into: folder) })
        }
    }

    @ViewBuilder private var background: some View {
        Button("New Folder", action: { model.newFolder() })
        Button("Paste", action: { paste(into: nil) })
        Divider()
        Button("Copy Path", action: { model.copyPath([]) })
        Button("Show in Finder", action: { model.showInFinder([]) })
        Button("Add to Sidebar", action: { model.addToSidebar([]) })
        if model.pane.url == model.trashURL {
            Divider()
            Button("Empty Trash…", action: { model.askEmptyTrash() })
        }
    }

    private func paste(into folder: URL?) {
        Task { await model.paste(into: folder) }
    }
}

/// Apps that can open the first item, default first.
private struct OpenWithMenu: View {
    let urls: [URL]

    private var apps: [URL] {
        guard let first = urls.first else { return [] }
        return Array(NSWorkspace.shared.urlsForApplications(toOpen: first).prefix(12))
    }

    var body: some View {
        Menu("Open With") {
            ForEach(apps, id: \.self) { (app: URL) in
                Button(app.deletingPathExtension().lastPathComponent, action: { open(with: app) })
            }
        }
    }

    private func open(with app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(),
                                completionHandler: nil)
    }
}
