import SwiftUI
import FileOSCore

/// F1.1: sidebar | toolbar, path bar, file area, status bar. Tool pages replace the browser.
struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            switch model.page {
            case .browser: BrowserView(pane: model.pane)
            default: PlaceholderPage(title: model.page.title)
            }
        }
        .overlay(alignment: .bottom) { ToastsView() }
    }
}

struct BrowserView: View {
    @Bindable var pane: PaneModel
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            PathBarView(pane: pane)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusBar(pane: pane)
        }
        .navigationTitle(model.displayName(pane.url))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { pane.back() } label: { Image(systemName: "chevron.left") }
                    .disabled(!pane.canGoBack)
                    .help("Back (⌘[)")
                    .accessibilityLabel("Back")
                Button { pane.forward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!pane.canGoForward)
                    .help("Forward (⌘])")
                    .accessibilityLabel("Forward")
            }
        }
        .searchable(text: $pane.filter, placement: .toolbar, prompt: "Filter this folder")
    }

    @ViewBuilder private var content: some View {
        switch FolderState(error: pane.error) {
        case .contents: FileListView(pane: pane)
        case .locked(let folder): LockedFolderView(folder: folder, pane: pane)
        case .unavailable(let message): FolderErrorView(message: message, pane: pane)
        }
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
