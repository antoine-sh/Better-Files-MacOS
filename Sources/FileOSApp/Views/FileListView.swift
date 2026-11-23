import SwiftUI
import FileOSCore

/// List view (F3.1): sortable Name, Date Modified, Size, Kind. Double-click or ⌘↓ opens.
struct FileListView: View {
    @Bindable var pane: PaneModel
    @Environment(AppModel.self) private var model
    static let nameOrder: String.StandardComparator = .localizedStandard

    var body: some View {
        table
            .contextMenu(forSelectionType: String.self) { (ids: Set<String>) in
                menu(ids)
            } primaryAction: { (ids: Set<String>) in
                open(ids)
            }
            .overlay { emptyNote }
    }

    private var table: some View {
        Table(pane.visibleEntries, selection: $pane.selection, sortOrder: $pane.sort) {
            TableColumn("Name", value: \Entry.name, comparator: Self.nameOrder) { (entry: Entry) in NameCell(entry: entry) }
                .width(min: 180, ideal: 320)
            TableColumn("Date Modified", value: \Entry.modified) { (entry: Entry) in DetailCell(text: Self.dateText(entry)) }
                .width(min: 120, ideal: 170)
            TableColumn("Size", value: \Entry.size) { (entry: Entry) in DetailCell(text: Self.sizeText(entry)) }
                .width(min: 60, ideal: 90)
            TableColumn("Kind", value: \Entry.kindName) { (entry: Entry) in DetailCell(text: entry.kindName) }
                .width(min: 80, ideal: 140)
        }
    }

    // shortcut: the full context menu (F3.10) arrives with file operations
    private func menu(_ ids: Set<String>) -> some View { EmptyView() }

    private func open(_ ids: Set<String>) { model.openSelection(ids) }

    @ViewBuilder private var emptyNote: some View {
        if pane.visibleEntries.isEmpty {
            Text(Self.emptyText(filter: pane.filter)).foregroundStyle(.secondary)
        }
    }

    static func emptyText(filter: String) -> String {
        if filter.isEmpty { return "This folder is empty" }
        return "No items match “\(filter)”"
    }

    static func dateText(_ entry: Entry) -> String {
        entry.modified.formatted(date: .abbreviated, time: .shortened)
    }

    static func sizeText(_ entry: Entry) -> String {
        if entry.isDirectory { return "--" }
        return formatBytes(entry.size)
    }
}

private struct NameCell: View {
    let entry: Entry

    var body: some View {
        Label {
            Text(entry.name).lineLimit(1).truncationMode(.middle)
        } icon: {
            icon
        }
        .opacity(entry.isHidden ? 0.6 : 1)
    }

    private var icon: some View {
        let color: Color = entry.isDirectory ? Color.accentColor : Color.secondary
        let symbol: String = entry.isDirectory ? "folder.fill" : "doc"
        return Image(systemName: symbol).foregroundStyle(color)
    }
}

private struct DetailCell: View {
    let text: String
    var body: some View { Text(text).foregroundStyle(.secondary) }
}
