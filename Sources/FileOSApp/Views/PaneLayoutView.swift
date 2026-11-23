import SwiftUI
import AppKit
import FileOSCore

/// F8.3: up to four panes. The raw value is the ⌥⌘ number.
enum PaneLayout: Int, Codable, CaseIterable, Sendable {
    case one = 1, sideBySide, stacked, threeColumns, oneBigTwoSmall, four

    var title: String {
        ["One Pane", "Side by Side", "Stacked", "Three Columns", "One Big Two Small", "Four"][rawValue - 1]
    }
    var paneCount: Int { [1, 2, 2, 3, 3, 4][rawValue - 1] }
    var shortcutID: String { "layout\(rawValue)" }
}

/// A named layout ("Month end") with each pane's folder, stored under "layouts".
struct SavedLayout: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var layout: PaneLayout
    var folders: [String]
    var id: String { name }
}

// MARK: - Panes (F8.1–F8.3)

extension AppModel {
    /// ⌘D.
    func toggleDualPane() { setLayout(panes.count > 1 ? .one : .sideBySide) }

    /// Clicking or selecting in a pane makes it the one menus and keys act on.
    func activate(_ p: PaneModel) {
        guard let index = panes.firstIndex(where: { (x: PaneModel) -> Bool in x === p }), index != activePane else { return }
        activePane = index
        editingPath = false
        pathError = nil
    }

    /// Tab with no modifiers (F8.1), seen by a local key monitor because list tables keep Tab for themselves.
    /// Left alone while typing in a field, in ⌘K, renaming, or in a sheet.
    func handlePaneKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 48 else { return false } // kVK_Tab
        let mods: NSEvent.ModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard mods.isEmpty, panes.count > 1, page == .browser, !showSearch, !editingPath, !showBatchRename,
              clashPrompt == nil, pane.renaming == nil, !TextEditing.isActive,
              !(event.window?.firstResponder is NSText), event.window?.sheetParent == nil else { return false }
        switchPane()
        return true
    }

    func installPaneKeyMonitor() {
        guard paneKeyMonitor == nil else { return }
        paneKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] (event: NSEvent) -> NSEvent? in
            guard let self else { return event }
            return self.handlePaneKey(event) ? nil : event
        }
    }

    /// Tab.
    func switchPane() {
        guard panes.count > 1 else { return }
        activePane = (activePane + 1) % panes.count
        editingPath = false
        pathError = nil
    }

    /// ⌘U: the active pane and the next one trade places; the active pane stays active.
    func swapPanes() {
        guard panes.count > 1 else { return }
        let other: Int = (activePane + 1) % panes.count
        panes.swapAt(activePane, other)
        activePane = other
    }

    func otherPane(of p: PaneModel) -> PaneModel? {
        guard panes.count > 1, let index = panes.firstIndex(where: { (x: PaneModel) -> Bool in x === p }) else { return nil }
        return panes[(index + 1) % panes.count]
    }

    var otherPane: PaneModel? { otherPane(of: pane) }

    /// F5 / F6 and the bar buttons: the selection to the next pane's folder.
    func transferToOtherPane(_ mode: TransferMode, _ urls: [URL]? = nil) async {
        let sources: [URL] = urls ?? targets
        guard let other = otherPane, !sources.isEmpty else { return }
        await runTransfer(sources, to: other.currentFolder, mode: mode)
    }

    func applyLayout(_ saved: SavedLayout) {
        setLayout(saved.layout)
        for (p, path) in zip(panes, saved.folders) { p.navigate(to: URL(fileURLWithPath: path)) }
    }

    /// Saves the current panes under `name`, replacing a layout of the same name; undoable.
    func saveLayout(named raw: String) {
        let name: String = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let previous: [SavedLayout] = savedLayouts
        let folders: [String] = panes.map { (p: PaneModel) -> String in p.url.path }
        var list: [SavedLayout] = previous.filter { (s: SavedLayout) -> Bool in s.name != name }
        list.insert(SavedLayout(name: name, layout: layout, folders: folders), at: 0)
        setSavedLayouts(list)
        undo.push("Save Layout") {
            await self.setSavedLayouts(previous)
            return RestoreResult()
        }
        toast("Saved layout “\(name)”", undoable: true)
    }

}

// MARK: - Views

/// The panes of the current layout; the active one is underlined (F8.1) and has keyboard focus.
struct PaneLayoutView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Int?

    var body: some View {
        layout
            .onAppear { model.installPaneKeyMonitor() }
            .onChange(of: model.activePane) { focused = model.activePane }
            .onChange(of: focused) { (_: Int?, now: Int?) in
                if let now, now < model.panes.count { model.activate(model.panes[now]) }
            }
    }

    @ViewBuilder private var layout: some View {
        switch model.layout {
        case .one: cell(0)
        case .sideBySide: HStack(spacing: 0) { cell(0); Divider(); cell(1) }
        case .stacked: VStack(spacing: 0) { cell(0); Divider(); cell(1) }
        case .threeColumns: HStack(spacing: 0) { cell(0); Divider(); cell(1); Divider(); cell(2) }
        case .oneBigTwoSmall: HStack(spacing: 0) { cell(0); Divider(); smallPair }
        case .four: VStack(spacing: 0) { pair(0); Divider(); pair(2) }
        }
    }

    private var smallPair: some View {
        VStack(spacing: 0) { cell(1); Divider(); cell(2) }
    }

    private func pair(_ first: Int) -> some View {
        HStack(spacing: 0) { cell(first); Divider(); cell(first + 1) }
    }

    @ViewBuilder private func cell(_ index: Int) -> some View {
        if index < model.panes.count {
            let pane: PaneModel = model.panes[index]
            PaneView(pane: pane, index: index, focus: $focused).id(ObjectIdentifier(pane))
        }
    }
}

/// One pane: path bar, files, the transfer bar and status bar.
struct PaneView: View {
    @Bindable var pane: PaneModel
    let index: Int
    var focus: FocusState<Int?>.Binding
    @Environment(AppModel.self) private var model

    private var isActive: Bool { model.pane === pane }
    private var several: Bool { model.panes.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            PathBarView(pane: pane)
            underline
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
                .focused(focus, equals: index)
            TransferButtons(pane: pane)
            Divider()
            StatusBar(pane: pane)
        }
        .environment(pane)
        .simultaneousGesture(TapGesture().onEnded { activate() })
        .onChange(of: pane.selection) { (old: Set<String>, new: Set<String>) in
            if !new.isSubset(of: old) { activate() } // a reload only shrinks the selection
        }
    }

    @ViewBuilder private var underline: some View {
        if several && isActive {
            Rectangle().fill(Color.accentColor).frame(height: 2).accessibilityLabel("Active pane")
        } else {
            Divider()
        }
    }

    private func activate() { model.activate(pane) }

    @ViewBuilder private var content: some View {
        switch FolderState(error: pane.error) {
        case .contents:
            HStack(spacing: 0) {
                files.frame(maxWidth: .infinity, maxHeight: .infinity)
                previewPane
            }
        case .locked(let folder):
            LockedFolderView(folder: folder, pane: pane)
        case .unavailable(let message):
            FolderErrorView(message: message, pane: pane)
        }
    }

    @ViewBuilder private var files: some View {
        switch pane.view {
        case .list: FileListView(pane: pane)
        case .icons: IconGridView(pane: pane)
        case .columns: ColumnBrowserView(pane: pane)
        }
    }

    /// Hidden with several panes (F8.3).
    @ViewBuilder private var previewPane: some View {
        if model.showPreview, !several, pane.view != .columns {
            Divider()
            PreviewPane(pane: pane).frame(width: 260)
        }
    }
}

/// F8.2: "Copy to “Invoices 2026”" / "Move" under the active pane when it has a selection.
private struct TransferButtons: View {
    let pane: PaneModel
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.pane === pane, let other = model.otherPane, !model.targets.isEmpty {
            HStack {
                Spacer()
                Button("Copy to “\(model.displayName(other.currentFolder))”", action: { send(.copy) })
                    .help("Copy to the other pane (F5)")
                Button("Move", action: { send(.move) })
                    .help("Move to the other pane (F6)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func send(_ mode: TransferMode) {
        Task { await model.transferToOtherPane(mode) }
    }
}

/// The Dual Pane toolbar button: click toggles two panes; its menu lists saved layouts first (F8.3).
struct DualPaneMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            ForEach(model.savedLayouts) { (saved: SavedLayout) in
                Button(saved.name, action: { model.applyLayout(saved) })
            }
            if !model.savedLayouts.isEmpty { Divider() }
            ForEach(PaneLayout.allCases, id: \.self) { (layout: PaneLayout) in
                Button(title(layout), action: { model.setLayout(layout) })
            }
            Divider()
            Button("Save Layout…", action: { model.showSaveLayout = true })
        } label: {
            Image(systemName: "rectangle.split.2x1")
        } primaryAction: {
            model.toggleDualPane()
        }
        .help("Dual Pane (⌘D)")
        .accessibilityLabel("Dual Pane")
    }

    private func title(_ layout: PaneLayout) -> String {
        model.layout == layout ? "✓ \(layout.title)" : layout.title
    }
}
