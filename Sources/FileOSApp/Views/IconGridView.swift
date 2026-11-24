import SwiftUI
import AppKit
import FileOSCore

/// Icons view (F3.1–F3.3): cards in a grid, sized Tiny…Large (⌘+ / ⌘−), grouped like the list.
struct IconGridView: View {
    let pane: PaneModel
    @Environment(AppModel.self) private var model
    @State private var perRow = 1

    private var size: IconSize { model.iconSize }
    private var cardWidth: CGFloat { max(72, size.side + 40) }
    private static let spacing: CGFloat = 12

    var body: some View {
        GeometryReader { (geo: GeometryProxy) in
            scroller
                .onAppear { measure(geo.size.width) }
                .onChange(of: geo.size.width) { (_: CGFloat, width: CGFloat) in measure(width) }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return]) { (press: KeyPress) -> KeyPress.Result in
            key(press)
        }
        .onExitCommand { model.cancelCut() }
        .contextMenu { FileContextMenu(ids: []) }
        .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in
            drop(urls, into: pane.url)
            return true
        }
        .overlay { emptyNote }
    }

    private var scroller: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth), spacing: Self.spacing)], alignment: .leading,
                      spacing: Self.spacing, pinnedViews: [.sectionHeaders]) {
                ForEach(pane.sections) { (section: RowSection) in
                    Section {
                        ForEach(section.rows) { (row: Row) in card(row) }
                    } header: {
                        SectionHeader(title: section.title)
                    }
                }
            }
            .padding(Self.spacing)
        }
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { clearSelection() })
    }

    private func card(_ row: Row) -> some View {
        IconCard(entry: row.entry, size: size, selected: pane.selection.contains(row.id),
                 dimmed: model.isCut(row.id) || row.entry.isHidden, renaming: pane.hostsRename(row.id, preview: false),
                 menuIDs: menuIDs(row.id))
            .frame(width: cardWidth)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.openSelection([row.id]) }
            // Simultaneous, so selecting doesn't wait out the double-click interval.
            .simultaneousGesture(TapGesture().onEnded { click(row.id) })
            .modifier(QuickActionPress(id: row.id, pane: pane))
            .contextMenu { FileContextMenu(ids: menuIDs(row.id)) }
            .draggable(row.entry.url)
            .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in
                guard row.entry.isDirectory else { return false }
                drop(urls, into: row.entry.url)
                return true
            }
    }

    /// The context menu acts on the selection when the clicked card is in it, else on that card alone.
    private func menuIDs(_ id: String) -> Set<String> { pane.selection.contains(id) ? pane.selection : [id] }

    private var order: [String] { pane.rows.map { (r: Row) -> String in r.id } }

    private func click(_ id: String) {
        let flags: NSEvent.ModifierFlags = NSEvent.modifierFlags
        pane.click(id, in: order, command: flags.contains(.command), shift: flags.contains(.shift))
    }

    private func clearSelection() { pane.selection = [] }

    private func measure(_ width: CGFloat) {
        perRow = max(1, Int((width - Self.spacing) / (cardWidth + Self.spacing)))
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard pane.renaming == nil else { return .ignored }
        let extend: Bool = press.modifiers.contains(.shift)
        switch press.key {
        case .leftArrow: pane.move(by: -1, in: order, extend: extend)
        case .rightArrow: pane.move(by: 1, in: order, extend: extend)
        case .upArrow: pane.move(by: -perRow, in: order, extend: extend)
        case .downArrow: pane.move(by: perRow, in: order, extend: extend)
        case .return: model.beginRename()
        default: return .ignored
        }
        return .handled
    }

    private func drop(_ urls: [URL], into folder: URL) {
        Task { await model.drop(urls, into: folder) }
    }

    @ViewBuilder private var emptyNote: some View {
        if pane.visibleEntries.isEmpty {
            Text(FileListView.emptyText(filter: pane.filter)).foregroundStyle(.secondary)
        }
    }
}

private struct SectionHeader: View {
    let title: String

    @ViewBuilder var body: some View {
        if !title.isEmpty {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .background(.bar)
        }
    }
}

/// One card: picture, name, and at Medium/Large the kind and size plus a ⋯ menu (F3.3).
private struct IconCard: View {
    let entry: Entry
    let size: IconSize
    let selected: Bool
    let dimmed: Bool
    let renaming: Bool
    let menuIDs: Set<String>

    var body: some View {
        VStack(spacing: 4) {
            ThumbnailView(entry: entry, side: size.side, preview: size.showsPreviews)
            name
            details
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) { moreMenu }
        .opacity(dimmed ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var name: some View {
        if renaming {
            RenameField(url: entry.url)
        } else {
            Text(entry.name)
                .font(size.rawValue < IconSize.small.rawValue ? .caption : .callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder private var details: some View {
        if size.showsPreviews {
            Text(detailText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var detailText: String {
        entry.isDirectory ? entry.kindName : "\(entry.kindName), \(formatBytes(entry.size))"
    }

    @ViewBuilder private var moreMenu: some View {
        if size.showsPreviews {
            Menu {
                FileContextMenu(ids: menuIDs)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
    }
}
