import SwiftUI
import FileOSCore

/// F1.1: sidebar | toolbar, path bar, file area, status bar. Tool pages replace the browser.
struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .overlay(alignment: .bottom) { ToastsView() }
        .overlay(alignment: .bottomTrailing) { TransferQueueView(queue: model.transfers) }
        .overlay { SearchOverlay() }
        .overlay { PeekOverlay() }
        .modifier(FileDialogs(model: model, queue: model.transfers))
        .modifier(SmartDialogs(model: model))
        .modifier(LibraryDialogs(model: model))
        .modifier(DevDialogs(model: model, agents: model.agents))
        .onChange(of: model.page) { (old: Page, new: Page) in model.pageChanged(from: old, to: new) }
    }

    private var sidebar: some View {
        SidebarView().navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
    }

    @ViewBuilder private var detail: some View {
        if model.page == .browser {
            BrowserView(pane: model.pane)
        } else if model.page == .markdown, let doc = model.markdown {
            MarkdownPage(doc: doc)
        } else if model.page == .freeUpSpace {
            FreeUpSpaceView(clean: model.clean)
        } else if model.page == .bookmarks {
            BookmarksPage()
        } else if model.page == .installed {
            InstalledView(installed: model.installed)
        } else if model.page == .agents {
            AgentsView(agents: model.agents)
        } else if model.page == .aboutMac {
            AboutMacView(hideNames: model.hideNames)
        } else if case .workspace(let id) = model.page {
            WorkspacePage(id: id).id(id) // fresh tab, view and search per workspace
        } else {
            PlaceholderPage(title: model.page.title)
        }
    }
}

/// The browser: the layout's panes under one toolbar that acts on the active pane.
struct BrowserView: View {
    @Bindable var pane: PaneModel
    @Environment(AppModel.self) private var model

    var body: some View {
        PaneLayoutView()
            .navigationTitle(model.displayName(pane.url))
            .toolbar { navigationButtons }
            .toolbar { ViewToolbar(pane: pane, model: model) }
            .modifier(FilterField(pane: pane, model: model))
    }

    private var navigationButtons: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            IconButton(symbol: "chevron.left", label: "Back", help: "Back (⌘[)", disabled: !pane.canGoBack, action: { back() })
            IconButton(symbol: "chevron.right", label: "Forward", help: "Forward (⌘])", disabled: !pane.canGoForward, action: { forward() })
        }
    }

    private func back() { pane.back() }
    private func forward() { pane.forward() }
}

/// ⌘F (F3.7) focuses the filter field.
private struct FilterField: ViewModifier {
    @Bindable var pane: PaneModel
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content.searchable(text: $pane.filter, isPresented: $model.filterShown, placement: .toolbar,
                           prompt: Text("Filter this folder"))
    }
}

/// View mode, sort, group, preview and (in the Trash) Empty Trash.
private struct ViewToolbar: ToolbarContent {
    let pane: PaneModel
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            IconButton(symbol: "magnifyingglass", label: "Search", help: "Search everything (⌘K)", disabled: false,
                       action: { model.openSearch() })
            OpenInMenu(urls: nil)
            DualPaneMenu(model: model)
            ViewModePicker(pane: pane, model: model)
            SortMenu(pane: pane, model: model)
            GroupMenu(pane: pane, model: model)
            IconButton(symbol: "sidebar.right", label: "Preview", help: "Show Preview (⇧⌘P)", disabled: false,
                       action: { model.togglePreview() })
            IconButton(symbol: "chart.pie", label: "Insights", help: "Insights (⌥⌘I)", disabled: false,
                       action: { model.toggleInsights() })
            EmptyTrashButton(pane: pane, model: model)
        }
    }
}

private struct ViewModePicker: View {
    let pane: PaneModel
    let model: AppModel
    @State private var mode: ViewMode = .list

    var body: some View {
        Picker("View", selection: $mode) {
            Label("List", systemImage: "list.bullet").tag(ViewMode.list)
            Label("Icons", systemImage: "square.grid.2x2").tag(ViewMode.icons)
            Label("Columns", systemImage: "rectangle.split.3x1").tag(ViewMode.columns)
        }
        .pickerStyle(.segmented)
        .help("View (⌘1, ⌘2, ⌘3)")
        .onAppear { mode = pane.view }
        .onChange(of: pane.view) { mode = pane.view }
        .onChange(of: mode) { if mode != pane.view { model.setView(mode) } }
    }
}

private struct SortMenu: View {
    let pane: PaneModel
    let model: AppModel

    static func name(_ key: SortKey) -> String {
        switch key {
        case .name: return "Name"
        case .kind: return "Kind"
        case .modified: return "Date Modified"
        case .added: return "Date Added"
        case .size: return "Size"
        }
    }

    var body: some View {
        Menu {
            ForEach(SortKey.allCases, id: \.self) { (key: SortKey) in
                Button(title(key), action: { model.setSort(key) })
            }
            Divider()
            Button(pane.prefs.filesFirst ? "✓ Files First" : "Files First", action: { model.toggleFilesFirst() })
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .help("Sort")
        .accessibilityLabel("Sort")
    }

    private func title(_ key: SortKey) -> String {
        guard pane.prefs.sortKey == key else { return Self.name(key) }
        return "\(Self.name(key)) \(pane.prefs.ascending ? "↑" : "↓")"
    }
}

private struct GroupMenu: View {
    let pane: PaneModel
    let model: AppModel

    var body: some View {
        Menu {
            Button(title("None", .none), action: { model.setGroup(.none) })
            Button(title("Kind", .kind), action: { model.setGroup(.kind) })
            Button(title("Date Added", .date), action: { model.setGroup(.date) })
        } label: {
            Image(systemName: "square.stack.3d.up")
        }
        .help("Group")
        .accessibilityLabel("Group")
    }

    private func title(_ name: String, _ grouping: Grouping) -> String {
        pane.prefs.group == grouping ? "✓ \(name)" : name
    }
}

private struct EmptyTrashButton: View {
    let pane: PaneModel
    let model: AppModel

    var body: some View {
        if pane.url == model.trashURL {
            Button("Empty Trash…", action: { model.askEmptyTrash() })
        }
    }
}

/// Window-level sheets and alerts for file operations.
struct FileDialogs: ViewModifier {
    @Bindable var model: AppModel
    @Bindable var queue: TransferQueue
    @State private var layoutName = ""

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $queue.showClash, onDismiss: { queue.clashSheetDismissed() }) {
                ClashSheet(queue: queue).environment(model)
            }
            .alert("Save Layout", isPresented: $model.showSaveLayout) {
                TextField("Name", text: $layoutName)
                Button("Save", action: { saveLayout() })
                Button("Cancel", role: .cancel, action: {})
            } message: {
                Text("Saved layouts are listed first in the Dual Pane menu and in ⌘K.")
            }
            .sheet(isPresented: $model.showBatchRename) {
                BatchRenameSheet(urls: model.batchRenameTargets).environment(model)
            }
            .alert("Empty the Trash?", isPresented: $model.showEmptyTrashAlert) {
                Button("Empty Trash", role: .destructive, action: { model.emptyTrash() })
                Button("Cancel", role: .cancel, action: {})
            } message: {
                Text(AppModel.emptyTrashMessage(count: model.emptyTrashSummary.count, bytes: model.emptyTrashSummary.bytes))
            }
            .alert(leaveTitle, isPresented: $model.showLeaveAlert) {
                Button("Save", action: { model.finishLeaving(save: true) })
                Button("Don't Save", role: .destructive, action: { model.finishLeaving(save: false) })
                Button("Cancel", role: .cancel, action: { model.leavingTo = nil })
            }
            .alert(extensionTitle, isPresented: $model.showExtensionAlert) {
                Button(keepTitle, action: { model.resolveExtension(keep: true) })
                Button(useTitle, action: { model.resolveExtension(keep: false) })
            }
    }

    private func saveLayout() {
        model.saveLayout(named: layoutName)
        layoutName = ""
    }

    private var leaveTitle: String { AppModel.leaveTitle(model.markdown?.name ?? "") }
    private var extensionTitle: String { model.extensionPrompt.map { (p: ExtensionPrompt) -> String in AppModel.extensionTitle(p) } ?? "" }
    private var keepTitle: String { "Keep \(model.extensionPrompt?.from ?? "")" }
    private var useTitle: String { "Use \(model.extensionPrompt?.to ?? "")" }
}

/// Tidy (F9.4) and Choose Symbol… (F13.2).
struct SmartDialogs: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.showTidy, onDismiss: { model.tidy = nil }) {
                TidySheet().environment(model)
            }
            .sheet(isPresented: $model.showSymbolChooser) {
                SymbolChooser(urls: model.symbolTargets).environment(model)
            }
    }
}

/// Workspaces (F11) and Bookmarks (F12): New/Edit Workspace, delete confirmations, Add Link, New Collection.
struct LibraryDialogs: ViewModifier {
    @Bindable var model: AppModel
    @State private var linkText = ""

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.showWorkspaceSheet) {
                NewWorkspaceSheet().environment(model)
            }
            .sheet(isPresented: $model.showNewCollection) {
                NewCollectionSheet().environment(model)
            }
            .alert(deleteWorkspaceTitle, isPresented: $model.showDeleteWorkspace) {
                Button("Delete", role: .destructive, action: { deleteWorkspace() })
                Button("Cancel", role: .cancel, action: {})
            } message: {
                Text(AppModel.deleteWorkspaceMessage(workspaceName))
            }
            .alert(deleteCollectionTitle, isPresented: $model.showDeleteCollection) {
                Button("Delete", role: .destructive, action: { deleteCollection() })
                Button("Cancel", role: .cancel, action: {})
            } message: {
                Text(collectionMessage)
            }
            .alert("Add Link", isPresented: $model.showAddLink) {
                TextField("https://", text: $linkText)
                Button("Save", action: { saveLink() })
                Button("Cancel", role: .cancel, action: {})
            }
    }

    private var workspaceName: String { model.workspaceToDelete.flatMap { (id: UUID) -> String? in model.workspace(id)?.name } ?? "" }
    private var deleteWorkspaceTitle: String { "Delete “\(workspaceName)”?" }
    private var deleteCollectionTitle: String {
        let name: String = model.collectionToDelete.flatMap { (id: UUID) -> String? in model.collection(id)?.name } ?? ""
        return "Delete “\(name)”?"
    }
    private var collectionMessage: String {
        model.collectionToDelete.map { (id: UUID) -> String in model.deleteCollectionMessage(id) } ?? ""
    }

    private func deleteWorkspace() {
        if let id = model.workspaceToDelete { model.deleteWorkspace(id) }
        model.workspaceToDelete = nil
    }

    private func deleteCollection() {
        if let id = model.collectionToDelete { model.deleteCollection(id) }
        model.collectionToDelete = nil
    }

    private func saveLink() {
        let text: String = linkText
        linkText = ""
        model.saveLink(text, collection: model.page == .bookmarks ? model.placeCollection : nil)
    }
}

/// The clash question, if one is still open when the sheet builds.
private struct ClashSheet: View {
    let queue: TransferQueue

    var body: some View {
        if let prompt = queue.clashPrompt { ClashDialog(prompt: prompt) }
    }
}

/// Icon-only toolbar button with the accessibility label and tooltip it needs.
struct IconButton: View {
    let symbol: String
    let label: String
    let help: String
    let disabled: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: { action() }) { Image(systemName: symbol) }
            .disabled(disabled)
            .help(help)
            .accessibilityLabel(label)
    }
}

/// Tool pages are built by later tasks; until then the page shows its name.
struct PlaceholderPage: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.largeTitle.weight(.semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
    }
}
