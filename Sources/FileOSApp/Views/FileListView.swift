import SwiftUI
import AppKit
import FileOSCore

/// List view (F3.1): sortable Name, Date Modified, Size, Kind; folders expand in place (› or → / ←);
/// grouped into sections when the folder is grouped (F3.4). Double-click or ⌘↓ opens.
struct FileListView: View {
    @Bindable var pane: PaneModel
    @Environment(AppModel.self) private var model
    static let nameOrder: String.StandardComparator = .localizedStandard

    var body: some View {
        table
            .contextMenu(forSelectionType: String.self) { (ids: Set<String>) in
                FileContextMenu(ids: ids)
            } primaryAction: { (ids: Set<String>) in
                open(ids)
            }
            .onChange(of: pane.sort) { pane.tableSortChanged() }
            .onKeyPress(.return) { rename() }
            .onKeyPress(.rightArrow) { expand(true) }
            .onKeyPress(.leftArrow) { expand(false) }
            .onExitCommand { model.cancelCut() }
            .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in
                drop(urls)
                return true
            }
            .overlay { emptyNote }
    }

    @ViewBuilder private var table: some View {
        if pane.prefs.group == .none {
            Table(pane.rows, selection: $pane.selection, sortOrder: $pane.sort) { columns }
        } else {
            groupedTable
        }
    }

    private var groupedTable: some View {
        Table(of: Row.self, selection: $pane.selection, sortOrder: $pane.sort) {
            columns
        } rows: {
            ForEach(pane.sections) { (section: RowSection) in
                Section(section.title) {
                    ForEach(section.rows) { (row: Row) in TableRow(row) }
                }
            }
        }
    }

    @TableColumnBuilder<Row, KeyPathComparator<Row>>
    private var columns: some TableColumnContent<Row, KeyPathComparator<Row>> {
        TableColumn("Name", value: \Row.entry.name, comparator: Self.nameOrder) { (row: Row) in NameCell(row: row, pane: pane) }
            .width(min: 180, ideal: 320)
        TableColumn("Date Modified", value: \Row.entry.modified) { (row: Row) in DetailCell(text: Self.dateText(row.entry)) }
            .width(min: 120, ideal: 170)
        TableColumn("Size", value: \Row.entry.size) { (row: Row) in DetailCell(text: Self.sizeText(row.entry)) }
            .width(min: 60, ideal: 90)
        TableColumn("Kind", value: \Row.kindName) { (row: Row) in DetailCell(text: row.kindName) }
            .width(min: 80, ideal: 140)
    }

    private func open(_ ids: Set<String>) { model.openSelection(ids) }

    private func rename() -> KeyPress.Result {
        guard pane.renaming == nil, !pane.selection.isEmpty else { return .ignored }
        model.beginRename()
        return .handled
    }

    private func expand(_ open: Bool) -> KeyPress.Result {
        guard pane.renaming == nil, !pane.selection.isEmpty else { return .ignored }
        pane.expandSelection(open)
        return .handled
    }

    private func drop(_ urls: [URL]) {
        let folder: URL = pane.url
        Task { await model.drop(urls, into: folder) }
    }

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
    let row: Row
    let pane: PaneModel
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            disclosure
            FileIcon(url: row.entry.url, side: model.iconSize.listIcon)
            name
        }
        .padding(.leading, CGFloat(row.depth) * 16)
        .opacity(dimmed ? 0.5 : 1)
        .draggable(row.entry.url)
    }

    private var dimmed: Bool { row.entry.isHidden || model.isCut(row.id) }

    @ViewBuilder private var disclosure: some View {
        if row.entry.isDirectory {
            Button(action: { toggle() }) {
                Image(systemName: pane.expanded.contains(row.id) ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pane.expanded.contains(row.id) ? "Collapse" : "Expand")
        } else {
            Color.clear.frame(width: 12, height: 1)
        }
    }

    @ViewBuilder private var name: some View {
        if pane.renaming == row.id {
            RenameField(url: row.entry.url)
        } else {
            Text(row.entry.name).lineLimit(1).truncationMode(.middle)
        }
    }

    private func toggle() { pane.toggleExpanded(row.entry) }
}

private struct DetailCell: View {
    let text: String
    var body: some View { Text(text).foregroundStyle(.secondary) }
}

/// The system icon for a file or folder (Finder's), at a fixed size.
struct FileIcon: View {
    let url: URL
    let side: CGFloat

    var body: some View {
        Image(nsImage: Thumbnails.icon(url))
            .resizable()
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

/// Inline rename (F5.6): the name is selected without its extension; Return commits, Esc cancels.
struct RenameField: View {
    let url: URL
    @Environment(AppModel.self) private var model
    @State private var text: String
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool

    init(url: URL) {
        self.url = url
        _text = State(initialValue: url.lastPathComponent)
    }

    var body: some View {
        TextField("Name", text: $text, selection: $selection)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { commit() }
            .onExitCommand { cancel() }
            .onAppear { start() }
            .onChange(of: focused) { (_: Bool, now: Bool) in
                if !now { commit() }
            }
    }

    private func start() {
        focused = true
        let base: String = splitExtension(text).base
        let end: String.Index = text.index(text.startIndex, offsetBy: base.count)
        selection = TextSelection(range: text.startIndex..<end)
    }

    private func commit() { model.commitRename(url, to: text) }
    private func cancel() { model.cancelRename() }
}
