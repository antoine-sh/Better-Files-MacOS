import SwiftUI
import FileOSCore

/// ⌥⌘I (F3.12): the open folder's space by kind and the Smart Downloads suggestions (F9.3).
struct InsightsPanel: View {
    let pane: PaneModel
    @Environment(AppModel.self) private var model
    @State private var installedApps: Set<String> = []
    @State private var confirmInstallers = false

    private var groups: [(kind: FileKind?, items: [Entry], bytes: Int64)] { Tidy.groupByKind(pane.entries) }
    private var suggestions: (installers: [Entry], duplicates: [Entry], older: [Entry]) {
        Tidy.suggestions(pane.entries, installedApps: installedApps, now: Date())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Insights").font(.headline)
                SpaceByKind(groups: groups)
                Divider()
                suggestionList
                Button(model.tidyTitle, action: { model.beginTidy(pane.url) })
            }
            .padding(12)
        }
        .task { installedApps = await Self.loadInstalledApps(home: model.home) }
        .confirmationDialog(installersTitle, isPresented: $confirmInstallers) {
            Button("Move to Trash", role: .destructive, action: { trashInstallers() })
            Button("Cancel", role: .cancel, action: {})
        }
    }

    nonisolated private static func loadInstalledApps(home: URL) async -> Set<String> {
        Set(SmartClean.installedApps(in: SmartClean.applicationDirs(home: home)).keys)
    }

    @ViewBuilder private var suggestionList: some View {
        let s: (installers: [Entry], duplicates: [Entry], older: [Entry]) = suggestions
        if s.installers.isEmpty && s.duplicates.isEmpty && s.older.isEmpty {
            Text("No suggestions for this folder").foregroundStyle(.secondary)
        }
        if !s.installers.isEmpty {
            SuggestionRow(title: "Installers already installed", items: s.installers, button: "Move to Trash…",
                          action: { confirmInstallers = true })
        }
        if !s.duplicates.isEmpty {
            SuggestionRow(title: "Likely duplicates", items: s.duplicates, button: "Select", action: { select(s.duplicates) })
        }
        if !s.older.isEmpty {
            SuggestionRow(title: "Older than 90 days", items: s.older, button: "Select", action: { select(s.older) })
        }
    }

    private var installersTitle: String {
        "Move \(AppModel.items(suggestions.installers.count)) to the Trash?"
    }

    private func trashInstallers() {
        model.trash(suggestions.installers.map { (e: Entry) -> URL in e.url })
    }

    private func select(_ entries: [Entry]) {
        model.activate(pane)
        pane.selection = Set(entries.map { (e: Entry) -> String in e.id })
    }
}

private struct SpaceByKind: View {
    let groups: [(kind: FileKind?, items: [Entry], bytes: Int64)]

    private var total: Int64 { max(1, groups.reduce(0) { (sum: Int64, g: (kind: FileKind?, items: [Entry], bytes: Int64)) -> Int64 in sum + g.bytes }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Space by Kind").font(.subheadline.weight(.semibold))
            if groups.isEmpty { Text("No files").foregroundStyle(.secondary) }
            ForEach(groups.indices, id: \.self) { (i: Int) in
                row(groups[i])
            }
        }
    }

    private func row(_ g: (kind: FileKind?, items: [Entry], bytes: Int64)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(g.kind?.rawValue ?? "Downloading")
                Spacer()
                Text("\(AppModel.items(g.items.count)), \(formatBytes(g.bytes))").foregroundStyle(.secondary)
            }
            .font(.caption)
            ProgressView(value: Double(g.bytes), total: Double(total))
                .accessibilityLabel(g.kind?.rawValue ?? "Downloading")
        }
    }
}

private struct SuggestionRow: View {
    let title: String
    let items: [Entry]
    let button: String
    let action: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Button(button, action: { action() }).controlSize(.small)
            }
            ForEach(items.prefix(4)) { (e: Entry) in
                Text(e.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if items.count > 4 { Text("and \(items.count - 4) more").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
