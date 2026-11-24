import SwiftUI
import AppKit
import FileOSCore

/// ⇧⌘P (F3.11): details of the single selected item. Hidden in column view, whose last column is the preview.
struct PreviewPane: View {
    let pane: PaneModel

    var body: some View {
        if pane.selection.count == 1, let id = pane.selection.first {
            PreviewInfo(url: URL(fileURLWithPath: id), pane: pane)
        } else {
            Text(pane.selection.isEmpty ? "No selection" : "\(pane.selection.count) items selected")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Kind, size, dates, location, Open / Show in Finder, rename (double-click the name), and for
/// folders their contents two levels deep.
struct PreviewInfo: View {
    let url: URL
    let pane: PaneModel
    @Environment(AppModel.self) private var model
    @State private var entry: Entry?
    /// The key the current `entry` was read for; until it matches, the item is still being read.
    @State private var readFor: String?

    /// Read again when the item or its folder's listing changes.
    private var key: String { "\(url.path)|\(pane.generation)" }

    var body: some View {
        Group {
            if let entry {
                ScrollView { details(entry).padding(16) }
            } else if readFor == key {
                Text("Nothing to preview").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .task(id: key) { await read() }
    }

    private func read() async {
        let target: URL = url, wanted: String = key
        let found: Entry? = await Task.detached(priority: .userInitiated) { () -> Entry? in Self.describe(target) }.value
        guard !Task.isCancelled else { return }
        entry = found
        readFor = wanted
    }

    // shortcut: lists the parent to describe one item; fine for a preview of one selection
    nonisolated static func describe(_ url: URL) -> Entry? {
        let name: String = url.lastPathComponent
        return (try? FileOps.listDirectory(url.deletingLastPathComponent(), showHidden: true))?.first { (e: Entry) -> Bool in e.name == name }
    }

    private func details(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ThumbnailView(entry: entry, side: 160, preview: true)
                .frame(maxWidth: .infinity)
            title(entry)
            InfoGrid(entry: entry, location: model.displayPath(url.deletingLastPathComponent()))
            HStack {
                Button("Open", action: { model.openSelection([entry.id]) })
                Button("Show in Finder", action: { model.showInFinder([entry.url]) })
            }
            if entry.isDirectory { FolderTree(url: entry.url, refresh: pane.generation) }
        }
    }

    @ViewBuilder private func title(_ entry: Entry) -> some View {
        if pane.hostsRename(entry.id, preview: true) {
            RenameField(url: entry.url)
        } else {
            Text(entry.name)
                .font(.headline)
                .textSelection(.enabled)
                .onTapGesture(count: 2) { model.beginRename([entry.url], inPreview: true) }
                .help("Double-click to rename")
        }
    }
}

private struct InfoGrid: View {
    let entry: Entry
    let location: String

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            line("Kind", entry.kindName)
            line("Size", FileListView.sizeText(entry))
            line("Created", Self.date(entry.created))
            line("Modified", Self.date(entry.modified))
            line("Added", Self.date(entry.added))
            line("Location", location)
        }
        .font(.callout)
    }

    private func line(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(2).truncationMode(.middle)
        }
    }

    static func date(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }
}

private struct TreeLine: Identifiable, Sendable {
    let id: String
    let name: String
    let depth: Int
    let isDirectory: Bool
}

/// A folder's contents two levels deep, capped so huge folders stay quick; read off the main actor.
private struct FolderTree: View {
    let url: URL
    /// The pane's listing generation: a change in the open folder reads the tree again.
    let refresh: Int
    nonisolated static let cap = 40

    @State private var lines: [TreeLine] = []

    nonisolated static func read(_ url: URL) -> [TreeLine] {
        var out: [TreeLine] = []
        let top: [Entry] = Arrange.sorted((try? FileOps.listDirectory(url)) ?? [], FolderPrefs())
        for entry in top.prefix(cap) {
            out.append(TreeLine(id: entry.id, name: entry.name, depth: 0, isDirectory: entry.isDirectory))
            guard entry.isDirectory, !entry.isSymlink else { continue }
            let inner: [Entry] = Arrange.sorted((try? FileOps.listDirectory(entry.url)) ?? [], FolderPrefs())
            for child in inner.prefix(cap) {
                out.append(TreeLine(id: child.id, name: child.name, depth: 1, isDirectory: child.isDirectory))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Contents").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(lines) { (line: TreeLine) in
                Label(line.name, systemImage: line.isDirectory ? "folder" : "doc")
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.leading, CGFloat(line.depth) * 14)
            }
        }
        .task(id: "\(url.path)|\(refresh)") {
            let folder: URL = url
            let found: [TreeLine] = await Task.detached(priority: .utility) { () -> [TreeLine] in Self.read(folder) }.value
            if !Task.isCancelled { lines = found }
        }
    }
}
