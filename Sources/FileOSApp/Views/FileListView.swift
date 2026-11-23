import SwiftUI
import FileOSCore

/// List view (F3.1): sortable Name, Date Modified, Size, Kind. Double-click or ⌘↓ opens.
struct FileListView: View {
    @Bindable var pane: PaneModel
    @Environment(AppModel.self) private var model

    var body: some View {
        Table(pane.visibleEntries, selection: $pane.selection, sortOrder: $pane.sort) {
            TableColumn("Name", value: \Entry.name, comparator: String.StandardComparator.localizedStandard) { entry in
                Label {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                        .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                }
                .opacity(entry.isHidden ? 0.6 : 1)
            }
            .width(min: 180, ideal: 320)
            TableColumn("Date Modified", value: \Entry.modified) { entry in
                Text(entry.modified, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Size", value: \Entry.size) { entry in
                Text(entry.isDirectory ? "--" : formatBytes(entry.size)).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Kind", value: \Entry.kindName) { entry in
                Text(entry.kindName).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 140)
        }
        .contextMenu(forSelectionType: Entry.ID.self) { _ in
            EmptyView() // shortcut: the full context menu (F3.10) arrives with file operations
        } primaryAction: { ids in
            model.openSelection(ids)
        }
        .overlay {
            if pane.visibleEntries.isEmpty {
                Text(pane.filter.isEmpty ? "This folder is empty" : "No items match “\(pane.filter)”")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
