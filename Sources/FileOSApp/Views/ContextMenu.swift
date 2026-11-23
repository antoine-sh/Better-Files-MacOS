import SwiftUI
import AppKit
import FileOSCore

/// F3.10: the right-click menu for items, or (with no ids) for the folder's background.
// shortcut: Peek, Quick Look, Add to Workspace and Pin to Drop Shelf join
// this menu with their features (Tasks 7–11)
struct FileContextMenu: View {
    let ids: Set<String>
    @Environment(AppModel.self) private var model
    /// The pane this menu belongs to; it becomes active before any action runs.
    @Environment(PaneModel.self) private var owner: PaneModel?

    private var urls: [URL] { ids.sorted().map { (p: String) -> URL in URL(fileURLWithPath: p) } }

    var body: some View {
        if ids.isEmpty { background } else { items }
    }

    @ViewBuilder private var items: some View {
        Group {
            Button("Open", action: { act { model.openSelection(ids) } })
            OpenWithMenu(urls: urls)
            Divider()
            Button(urls.count == 1 ? "Rename…" : "Rename \(urls.count) Items…", action: { act { model.beginRename(urls) } })
            Button("Duplicate", action: { act { model.duplicate(urls) } })
            Button("Make Alias", action: { act { model.makeAlias(urls) } })
            Divider()
        }
        Group {
            Button("Copy", action: { act { model.copy(urls) } })
            Button("Cut", action: { act { model.copy(urls, cut: true) } })
            pasteInto
            copyToOther
            Button("Copy Path", action: { act { model.copyPath(urls) } })
            Divider()
        }
        FolderSymbolItems(urls: urls)
        Group {
            Button("Show in Finder", action: { act { model.showInFinder(urls) } })
            Button("Add to Sidebar", action: { act { model.addToSidebar(urls) } })
            Button("AirDrop…", action: { act { model.airDrop(urls) } })
                .disabled(!model.canAirDrop(urls))
            Divider()
            Button("Move to Trash", action: { act { model.trash(urls) } })
        }
    }

    /// F8.2: "Copy to “Invoices 2026”" with several panes.
    @ViewBuilder private var copyToOther: some View {
        if let owner, let other = model.otherPane(of: owner) {
            Button("Copy to “\(model.displayName(other.currentFolder))”", action: { act { send(urls) } })
        }
    }

    private func send(_ urls: [URL]) {
        Task { await model.transferToOtherPane(.copy, urls) }
    }

    private func act(_ action: () -> Void) {
        if let owner { model.activate(owner) }
        action()
    }

    /// "Paste into “folder”" when one folder is chosen (F5.1).
    @ViewBuilder private var pasteInto: some View {
        if urls.count == 1, let folder = urls.first, AppModel.isBrowsableFolder(folder) {
            Button("Paste into “\(folder.lastPathComponent)”", action: { act { paste(into: folder) } })
        }
    }

    @ViewBuilder private var background: some View {
        Button("New Folder", action: { act { model.newFolder() } })
        Button("Paste", action: { act { paste(into: nil) } })
        Divider()
        Button("Copy Path", action: { act { model.copyPath([]) } })
        Button("Show in Finder", action: { act { model.showInFinder([]) } })
        Button("Add to Sidebar", action: { act { model.addToSidebar([]) } })
        if (owner ?? model.pane).url == model.trashURL {
            Divider()
            Button("Empty Trash…", action: { act { model.askEmptyTrash() } })
        }
    }

    private func paste(into folder: URL?) {
        Task { await model.paste(into: folder) }
    }
}

/// Choose Symbol… / Back to Automatic Symbol when every chosen item is a folder (F13.2).
private struct FolderSymbolItems: View {
    let urls: [URL]
    @Environment(AppModel.self) private var model

    var body: some View {
        if !urls.isEmpty, urls.allSatisfy({ (u: URL) -> Bool in AppModel.isBrowsableFolder(u) }) {
            Button("Choose Symbol…", action: { model.chooseSymbol(urls) })
            if urls.contains(where: { (u: URL) -> Bool in model.hasChosenSymbol(u) }) {
                Button("Back to Automatic Symbol", action: { model.setSymbol(nil, for: urls) })
            }
            Divider()
        }
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
