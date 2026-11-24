import SwiftUI
import AppKit
import FileOSCore

// F5.15: ⌘. or a 0.5 s press on an item shows up to six actions, in the order set in Settings > Quick Actions.

extension AppModel {
    /// ⌘. acts on the selection; a long press on the pressed item (or the selection it belongs to).
    func showQuickActions(for urls: [URL]? = nil) {
        let list: [URL] = urls ?? targets
        guard !list.isEmpty, !quickActions.isEmpty else { return }
        quickActionTargets = list
        showQuickActions = true
    }

    func isQuickActionAvailable(_ action: QuickAction) -> Bool {
        switch action {
        case .airDrop: return canAirDrop(quickActionTargets)
        case .pinToDropShelf, .addToQuickAccess:
            return quickActionTargets.contains { (u: URL) -> Bool in Self.isBrowsableFolder(u) }
        default: return true
        }
    }

    func performQuickAction(_ action: QuickAction) {
        let urls: [URL] = quickActionTargets
        showQuickActions = false
        quickActionTargets = []
        guard !urls.isEmpty else { return }
        switch action {
        case .open: openSelection(Set(urls.map { (u: URL) -> String in u.path }))
        case .peek:
            pane.selection = Set(urls.map { (u: URL) -> String in u.path })
            peekSelection()
        case .rename: beginRename(urls)
        case .duplicate: duplicate(urls)
        case .copyPath: copyPath(urls)
        case .showInFinder: showInFinder(urls)
        case .airDrop: airDrop(urls)
        case .addToHolding:
            addToHolding(urls)
            toast("Added \(Self.items(urls.count)) to Holding", undoable: false)
        case .pinToDropShelf: pinToShelf(urls)
        case .addToQuickAccess: addToQuickAccess(urls)
        case .trash: trash(urls)
        }
    }
}

/// The actions card over the window; 1–6 pick, Esc closes.
struct QuickActionsOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.showQuickActions {
            ZStack {
                Color.black.opacity(0.12)
                    .onTapGesture { close() }
                    .accessibilityHidden(true)
                QuickActionsCard()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(radius: 12)
            }
        }
    }

    private func close() { model.showQuickActions = false }
}

private struct QuickActionsCard: View {
    @Environment(AppModel.self) private var model
    private let columns: [GridItem] = Array(repeating: GridItem(.fixed(120), spacing: 8), count: 3)

    private var title: String {
        let urls: [URL] = model.quickActionTargets
        return urls.count == 1 ? urls[0].lastPathComponent : AppModel.items(urls.count)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(model.quickActions.enumerated()), id: \.element) { (pair: (offset: Int, element: QuickAction)) in
                    QuickActionButton(action: pair.element, number: pair.offset + 1)
                }
            }
            Button("Cancel", action: { model.showQuickActions = false })
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }
}

private struct QuickActionButton: View {
    let action: QuickAction
    let number: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(action: { model.performQuickAction(action) }) {
            VStack(spacing: 4) {
                Image(systemName: action.symbol).font(.title2)
                Text(action.title).font(.caption).lineLimit(1)
            }
            .frame(width: 112, height: 56)
        }
        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [])
        .disabled(!model.isQuickActionAvailable(action))
        .help("\(action.title) (\(number))")
    }
}

/// The 0.5 s press, alongside the item's own click and drag gestures.
// shortcut: icon and column views only; list rows are NSTableView cells, where an extra gesture breaks row
// selection, so the list uses ⌘. — add an NSTableView-level press monitor if users ask
struct QuickActionPress: ViewModifier {
    let id: String
    let pane: PaneModel
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { (_: Bool) in press() })
    }

    private func press() {
        let ids: Set<String> = pane.selection.contains(id) ? pane.selection : [id]
        model.activate(pane)
        model.showQuickActions(for: ids.sorted().map { (p: String) -> URL in URL(fileURLWithPath: p) })
    }
}
