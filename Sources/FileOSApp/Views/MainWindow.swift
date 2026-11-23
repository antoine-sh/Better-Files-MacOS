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
            .searchable(text: $pane.filter, placement: .toolbar, prompt: Text("Filter this folder"))
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
            FileListView(pane: pane)
        case .locked(let folder):
            LockedFolderView(folder: folder, pane: pane)
        case .unavailable(let message):
            FolderErrorView(message: message, pane: pane)
        }
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
