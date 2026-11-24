import SwiftUI
import FileOSCore

/// F2.1: the files with a Finder tag, read-only, in the rows ⌘K uses. Double-click opens.
struct TagPage: View {
    let title: String
    @Environment(AppModel.self) private var model
    @State private var selection: Set<URL> = []

    var body: some View {
        List(model.tagged, id: \.self, selection: $selection) { (url: URL) in
            PaletteRowView(row: .hit(SearchHit(url: url, name: url.lastPathComponent, isDirectory: false, kind: nil, line: nil)))
                .tag(url)
        }
        .contextMenu(forSelectionType: URL.self) { (urls: Set<URL>) in
            Button("Show in Finder", action: { model.showInFinder(Array(urls)) })
        } primaryAction: { (urls: Set<URL>) in
            open(urls)
        }
        .overlay { note }
        .navigationTitle(title)
    }

    @ViewBuilder private var note: some View {
        if model.loadingTag {
            ProgressView()
        } else if model.tagged.isEmpty {
            Text(title == "All Tags" ? "No tagged files" : "No files tagged \(title)").foregroundStyle(.secondary)
        }
    }

    private func open(_ urls: Set<URL>) {
        for url in urls { model.openItem(url) }
    }
}
