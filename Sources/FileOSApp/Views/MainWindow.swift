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
        .modifier(FileDialogs(model: model))
    }

    private var sidebar: some View {
        SidebarView().navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
    }

    @ViewBuilder private var detail: some View {
        if model.page == .browser {
            BrowserView(pane: model.pane)
        } else {
            PlaceholderPage(title: model.page.title)
        }
    }
}

struct BrowserView: View {
    @Bindable var pane: PaneModel
    @Environment(AppModel.self) private var model

    var body: some View {
        column
            .navigationTitle(model.displayName(pane.url))
            .toolbar { navigationButtons }
            .toolbar { ViewToolbar(pane: pane, model: model) }
            .modifier(FilterField(pane: pane, model: model))
    }

    private var column: some View {
        VStack(spacing: 0) {
            PathBarView(pane: pane)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusBar(pane: pane)
        }
    }

    private var navigationButtons: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            IconButton(symbol: "chevron.left", label: "Back", help: "Back (⌘[)", disabled: !pane.canGoBack, action: { back() })
            IconButton(symbol: "chevron.right", label: "Forward", help: "Forward (⌘])", disabled: !pane.canGoForward, action: { forward() })
        }
    }

    private func back() { pane.back() }
    private func forward() { pane.forward() }

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
}

extension BrowserView {
    @ViewBuilder fileprivate var files: some View {
        switch pane.view {
        case .list: FileListView(pane: pane)
        case .icons: IconGridView(pane: pane)
        case .columns: ColumnBrowserView(pane: pane)
        }
    }

    @ViewBuilder fileprivate var previewPane: some View {
        if model.showPreview, pane.view != .columns {
            Divider()
            PreviewPane(pane: pane).frame(width: 260)
        }
    }
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
            ViewModePicker(pane: pane, model: model)
            SortMenu(pane: pane, model: model)
            GroupMenu(pane: pane, model: model)
            IconButton(symbol: "sidebar.right", label: "Preview", help: "Show Preview (⇧⌘P)", disabled: false,
                       action: { model.togglePreview() })
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

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.clashPrompt) { (prompt: ClashPrompt) in
                ClashDialog(prompt: prompt).environment(model)
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
            .alert(extensionTitle, isPresented: $model.showExtensionAlert) {
                Button(keepTitle, action: { model.resolveExtension(keep: true) })
                Button(useTitle, action: { model.resolveExtension(keep: false) })
            }
    }

    private var extensionTitle: String { model.extensionPrompt.map { (p: ExtensionPrompt) -> String in AppModel.extensionTitle(p) } ?? "" }
    private var keepTitle: String { "Keep \(model.extensionPrompt?.from ?? "")" }
    private var useTitle: String { "Use \(model.extensionPrompt?.to ?? "")" }
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
