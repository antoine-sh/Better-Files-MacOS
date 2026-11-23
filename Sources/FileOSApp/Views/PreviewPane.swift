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

    private var entry: Entry? {
        let parent: URL = url.deletingLastPathComponent()
        let name: String = url.lastPathComponent
        // shortcut: lists the parent to describe one item; fine for a preview of one selection
        return (try? FileOps.listDirectory(parent, showHidden: true))?.first { (e: Entry) -> Bool in e.name == name }
    }

    var body: some View {
        if let entry {
            ScrollView { details(entry).padding(16) }
        } else {
            Text("Nothing to preview").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
            if entry.isDirectory { FolderTree(url: entry.url) }
        }
    }

    @ViewBuilder private func title(_ entry: Entry) -> some View {
        if pane.renaming == entry.id {
            RenameField(url: entry.url)
        } else {
            Text(entry.name)
                .font(.headline)
                .textSelection(.enabled)
                .onTapGesture(count: 2) { model.beginRename([entry.url]) }
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

/// A folder's contents two levels deep, capped so huge folders stay quick.
private struct FolderTree: View {
    let url: URL
    static let cap = 40

    private struct Line: Identifiable {
        let id: String
        let name: String
        let depth: Int
        let isDirectory: Bool
    }

    private var lines: [Line] {
        var out: [Line] = []
        let top: [Entry] = Arrange.sorted((try? FileOps.listDirectory(url)) ?? [], FolderPrefs())
        for entry in top.prefix(Self.cap) {
            out.append(Line(id: entry.id, name: entry.name, depth: 0, isDirectory: entry.isDirectory))
            guard entry.isDirectory, !entry.isSymlink else { continue }
            let inner: [Entry] = Arrange.sorted((try? FileOps.listDirectory(entry.url)) ?? [], FolderPrefs())
            for child in inner.prefix(Self.cap) {
                out.append(Line(id: child.id, name: child.name, depth: 1, isDirectory: child.isDirectory))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Contents").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(lines) { (line: Line) in
                Label(line.name, systemImage: line.isDirectory ? "folder" : "doc")
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.leading, CGFloat(line.depth) * 14)
            }
        }
    }
}
