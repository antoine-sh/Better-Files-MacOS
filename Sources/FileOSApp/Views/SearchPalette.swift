import SwiftUI
import AppKit
import FileOSCore

/// A workspace, bookmark or saved layout matched by name (F7.1).
struct NamedMatch: Hashable {
    enum Kind: String { case workspace = "Workspace", bookmark = "Bookmark", layout = "Layout" }
    let kind: Kind
    let name: String
    /// Workspace id, bookmark address or layout name.
    let target: String
}

enum PaletteRow: Identifiable, Hashable {
    case named(NamedMatch)
    case hit(SearchHit)

    var id: String {
        switch self {
        case .named(let n): return "\(n.kind.rawValue):\(n.target)"
        case .hit(let h): return "\(h.url.path)#\(h.line?.number ?? 0)"
        }
    }
}

/// ⌘K state. The disk search runs off the main actor and is cancelled whenever the query changes.
@MainActor @Observable
final class SearchModel {
    var query = ""
    var chip: SearchChip = .all
    var contents = false
    var selection: String?
    private(set) var hits: [SearchHit] = []
    private(set) var named: [NamedMatch] = []
    private(set) var searching = false
    @ObservationIgnored private(set) var pending: Task<Void, Never>?

    /// Workspaces, then folders and files by kind, then bookmarks and saved layouts.
    var rows: [PaletteRow] {
        func of(_ kind: NamedMatch.Kind) -> [PaletteRow] {
            named.filter { (n: NamedMatch) -> Bool in n.kind == kind }.map { (n: NamedMatch) -> PaletteRow in .named(n) }
        }
        return of(.workspace) + hits.map { (h: SearchHit) -> PaletteRow in .hit(h) } + of(.bookmark) + of(.layout)
    }

    var selectedRow: PaletteRow? {
        let all: [PaletteRow] = rows
        return all.first { (r: PaletteRow) -> Bool in r.id == selection } ?? all.first
    }

    func refresh(roots: [URL], store: Store, layouts: [SavedLayout]) {
        pending?.cancel()
        let q: String = query.trimmingCharacters(in: .whitespaces)
        let wantContents: Bool = contents
        let wantChip: SearchChip = chip
        named = q.isEmpty ? [] : Self.namedMatches(q, chip: wantChip, store: store, layouts: layouts)
        guard !q.isEmpty else {
            hits = []
            searching = false
            return
        }
        searching = true
        pending = Task {
            try? await Task.sleep(for: .milliseconds(120)) // typing settles first
            if Task.isCancelled { return }
            let found: [SearchHit] = await Self.find(roots: roots, query: q, contents: wantContents, chip: wantChip)
            if Task.isCancelled { return }
            hits = found
            searching = false
        }
    }

    /// Runs on the global executor, inside the caller's task, so its cancellation stops the walk.
    nonisolated static func find(roots: [URL], query: String, contents: Bool, chip: SearchChip) async -> [SearchHit] {
        search(roots: roots, query: query, contents: contents, chip: chip, isCancelled: { Task.isCancelled })
    }

    static func namedMatches(_ q: String, chip: SearchChip, store: Store, layouts: [SavedLayout]) -> [NamedMatch] {
        func matches(_ s: String) -> Bool { s.range(of: q, options: .caseInsensitive) != nil }
        var out: [NamedMatch] = []
        if chip == .all || chip == .workspaces {
            for w in store.get("workspaces", default: [Workspace]()) where !w.archived && matches(w.name) {
                out.append(NamedMatch(kind: .workspace, name: w.name, target: w.id.uuidString))
            }
        }
        if chip == .all || chip == .bookmarks {
            for b in store.get("bookmarks", default: [Bookmark]()) where matches(b.title) || matches(b.url) || b.tags.contains(where: { (t: String) -> Bool in matches(t) }) {
                out.append(NamedMatch(kind: .bookmark, name: b.title, target: b.url))
            }
        }
        if chip == .all {
            for l in layouts where matches(l.name) { out.append(NamedMatch(kind: .layout, name: l.name, target: l.name)) }
        }
        return out
    }
}

extension AppModel {
    func openSearch() {
        showSearch = true
        runSearch()
    }

    func runSearch() { search.refresh(roots: [home], store: store, layouts: savedLayouts) }

    /// Return: folders open in the active pane, files in their app, workspaces/bookmarks/layouts open.
    func openPaletteRow(_ row: PaletteRow) {
        showSearch = false
        switch row {
        case .hit(let h):
            openItem(h.url)
        case .named(let n):
            switch n.kind {
            case .workspace:
                if let id = UUID(uuidString: n.target) { page = .workspace(id) }
            case .bookmark:
                if let url = URL(string: n.target) { _ = NSWorkspace.shared.open(url) }
            case .layout:
                if let saved = savedLayouts.first(where: { (s: SavedLayout) -> Bool in s.name == n.target }) { applyLayout(saved) }
            }
        }
    }

    /// ⌥Return: the item selected in its folder.
    func revealPaletteRow(_ row: PaletteRow) {
        guard case .hit(let h) = row else { return openPaletteRow(row) }
        showSearch = false
        page = .browser
        pane.navigate(to: h.url.deletingLastPathComponent(), select: h.url)
    }
}

/// ⌘K floats over the window rather than in a sheet, so a clash sheet can still show while it is open.
struct SearchOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.showSearch {
            ZStack(alignment: .top) {
                Color.black.opacity(0.15)
                    .onTapGesture { model.showSearch = false }
                    .accessibilityHidden(true)
                SearchPalette(search: model.search)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 12)
                    .padding(.top, 60)
            }
        }
    }
}

/// ⌘K (F7.1–F7.3): "Search everything", chips, Contents, Return / ⌥Return / Space.
struct SearchPalette: View {
    @Bindable var search: SearchModel
    @Environment(AppModel.self) private var model
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field
            ChipBar(search: search)
            Divider()
            SearchResults(search: search)
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 640, height: 460)
        .onAppear { fieldFocused = true }
        .onChange(of: search.query) { model.runSearch() }
        .onChange(of: search.chip) { model.runSearch() }
        .onChange(of: search.contents) { model.runSearch() }
    }

    private var field: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search everything", text: $search.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .onKeyPress(keys: [.upArrow, .downArrow]) { (press: KeyPress) -> KeyPress.Result in
                    step(press.key == .upArrow ? -1 : 1)
                }
            if search.searching { ProgressView().controlSize(.small) }
            Toggle("Contents", isOn: $search.contents)
                .toggleStyle(.button)
                .help("Search inside documents and code")
        }
    }

    private var footer: some View {
        HStack {
            Text("\(search.rows.count) results").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: { model.showSearch = false }).keyboardShortcut(.cancelAction)
            Button("Peek", action: { peek() }).help("Peek (Space); ⌘Y opens Quick Look")
            Button("Show in Folder", action: { reveal() }).keyboardShortcut(.return, modifiers: .option)
            Button("Open", action: { open() }).keyboardShortcut(.defaultAction)
        }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        let ids: [String] = search.rows.map { (r: PaletteRow) -> String in r.id }
        guard !ids.isEmpty else { return .ignored }
        let current: Int = ids.firstIndex { (id: String) -> Bool in id == search.selectedRow?.id } ?? 0
        search.selection = ids[min(max(current + delta, 0), ids.count - 1)]
        return .handled
    }

    private func open() {
        if let row = search.selectedRow { model.openPaletteRow(row) }
    }

    private func reveal() {
        if let row = search.selectedRow { model.revealPaletteRow(row) }
    }

    private func peek() {
        if case .hit(let h) = search.selectedRow { model.peek.show([h.url]) }
    }
}

private struct ChipBar: View {
    @Bindable var search: SearchModel

    var body: some View {
        Picker("Show", selection: $search.chip) {
            ForEach(SearchChip.allCases, id: \.self) { (chip: SearchChip) in
                Text(chip.rawValue).tag(chip)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

private struct SearchResults: View {
    @Bindable var search: SearchModel
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: $search.selection) {
            ForEach(search.rows) { (row: PaletteRow) in
                PaletteRowView(row: row).tag(row.id)
            }
        }
        .contextMenu(forSelectionType: String.self) { (_: Set<String>) in
            EmptyView()
        } primaryAction: { (ids: Set<String>) in
            open(ids)
        }
        .onKeyPress(.space) { peek() }
        .overlay { emptyNote }
    }

    @ViewBuilder private var emptyNote: some View {
        if search.rows.isEmpty, !search.searching, !search.query.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("No results for “\(search.query)”").foregroundStyle(.secondary)
        }
    }

    private func open(_ ids: Set<String>) {
        guard let id = ids.first, let row = search.rows.first(where: { (r: PaletteRow) -> Bool in r.id == id }) else { return }
        model.openPaletteRow(row)
    }

    private func peek() -> KeyPress.Result {
        guard case .hit(let h) = search.selectedRow else { return .ignored }
        model.peek.show([h.url])
        return .handled
    }
}

private struct PaletteRowView: View {
    let row: PaletteRow

    var body: some View {
        switch row {
        case .hit(let h):
            HStack(spacing: 8) {
                FileIcon(url: h.url, side: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(h.name).lineLimit(1).truncationMode(.middle)
                    Text(detail(h)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        case .named(let n):
            HStack(spacing: 8) {
                Image(systemName: symbol(n.kind)).frame(width: 20)
                Text(n.name).lineLimit(1)
                Spacer()
                Text(n.kind.rawValue).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // shortcut: no picture thumbnails or video length in rows yet (F7.1); the file icon stands in
    private func detail(_ h: SearchHit) -> String {
        if let line = h.line { return "\(line.number): \(line.text)" }
        return h.url.deletingLastPathComponent().path
    }

    private func symbol(_ kind: NamedMatch.Kind) -> String {
        switch kind {
        case .workspace: return "square.stack"
        case .bookmark: return "bookmark"
        case .layout: return "rectangle.split.2x1"
        }
    }
}
