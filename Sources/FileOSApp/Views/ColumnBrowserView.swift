import SwiftUI
import AppKit
import FileOSCore

/// Columns view (F3.1): ↑↓ move (⇧ extends), → enters, ← leaves, Return renames; the last column
/// previews the selected file.
struct ColumnBrowserView: View {
    let pane: PaneModel
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(pane.columnDirs.indices, id: \.self) { (index: Int) in
                    BrowserColumn(pane: pane, index: index)
                        .frame(width: 230)
                    Divider()
                }
                preview
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return]) { (press: KeyPress) -> KeyPress.Result in
            key(press)
        }
        .onExitCommand { model.cancelCut() }
    }

    @ViewBuilder private var preview: some View {
        if let url = pane.columnPreview {
            PreviewInfo(url: url, pane: pane).frame(width: 280)
        }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard pane.renaming == nil else { return .ignored }
        let extend: Bool = press.modifiers.contains(.shift)
        switch press.key {
        case .upArrow: pane.columnMove(by: -1, extend: extend)
        case .downArrow: pane.columnMove(by: 1, extend: extend)
        case .rightArrow: pane.columnStep(into: true)
        case .leftArrow: pane.columnStep(into: false)
        case .return: model.beginRename()
        default: return .ignored
        }
        return .handled
    }
}

private struct BrowserColumn: View {
    let pane: PaneModel
    let index: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        let entries: [Entry] = pane.columnEntries(index)
        let folder: URL = pane.columnDirs[index]
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { (entry: Entry) in
                    row(entry)
                }
            }
            .padding(.vertical, 4)
        }
        .contextMenu { FileContextMenu(ids: []) }
        .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in
            drop(urls, into: folder)
            return true
        }
    }

    private func row(_ entry: Entry) -> some View {
        ColumnRow(entry: entry, selected: pane.selection.contains(entry.id), opened: isOpened(entry),
                  dimmed: model.isCut(entry.id) || entry.isHidden, renaming: pane.renaming == entry.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.openSelection([entry.id]) }
            .onTapGesture { click(entry) }
            .contextMenu { FileContextMenu(ids: pane.selection.contains(entry.id) ? pane.selection : [entry.id]) }
            .draggable(entry.url)
            .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in
                guard entry.isDirectory else { return false }
                drop(urls, into: entry.url)
                return true
            }
    }

    /// The folder whose contents fill the next column.
    private func isOpened(_ entry: Entry) -> Bool {
        index + 1 < pane.columnDirs.count && pane.columnDirs[index + 1].path == entry.id
    }

    private func click(_ entry: Entry) {
        let flags: NSEvent.ModifierFlags = NSEvent.modifierFlags
        pane.columnClick(entry, column: index, command: flags.contains(.command), shift: flags.contains(.shift))
    }

    private func drop(_ urls: [URL], into folder: URL) {
        Task { await model.drop(urls, into: folder) }
    }
}

private struct ColumnRow: View {
    let entry: Entry
    let selected: Bool
    let opened: Bool
    let dimmed: Bool
    let renaming: Bool

    var body: some View {
        HStack(spacing: 6) {
            FileIcon(url: entry.url, side: 16)
            name
            Spacer(minLength: 4)
            if entry.isDirectory {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(highlight, in: RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 4)
        .opacity(dimmed ? 0.5 : 1)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var highlight: Color {
        if selected { return Color.accentColor.opacity(0.3) }
        if opened { return Color.secondary.opacity(0.15) }
        return Color.clear
    }

    @ViewBuilder private var name: some View {
        if renaming {
            RenameField(url: entry.url)
        } else {
            Text(entry.name).lineLimit(1).truncationMode(.middle)
        }
    }
}
