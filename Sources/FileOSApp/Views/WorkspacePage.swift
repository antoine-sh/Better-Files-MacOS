import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FileOSCore

/// F11.3 views.
enum WorkspaceLayout: String, CaseIterable, Sendable {
    case list = "List", tiles = "Tiles", cards = "Cards", changed = "Changed Lately"
}

func workspaceColor(_ name: String) -> Color {
    switch name {
    case "purple": return .purple
    case "pink": return .pink
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "gray": return .gray
    default: return .blue
    }
}

/// F11.3: tabs, pinned row, "Search in …", four views, ⋯ menus; Add via the picker, a link, or a drop.
struct WorkspacePage: View {
    let id: UUID
    @Environment(AppModel.self) private var model
    @State private var tab: WorkspaceTab = .overview
    @State private var layout: WorkspaceLayout = .list
    @State private var query = ""
    @State private var importing = false
    @State private var addingLink = false
    @State private var linkText = ""
    /// Each item's status and date, worked out off the main actor when the items change, not on every redraw.
    @State private var facts: [UUID: ItemFacts] = [:]

    var body: some View {
        if let w = model.workspace(id) {
            page(w)
        } else {
            ContentUnavailableView("This workspace was deleted", systemImage: "square.dashed")
        }
    }

    private func page(_ w: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkspaceHeader(workspace: w)
            if w.id == Workspaces.sampleID { SampleTips(id: w.id) }
            if w.archived { ArchivedBanner(workspace: w) }
            if !w.pinned.isEmpty { PinnedRow(workspace: w) }
            controls
            WorkspaceItemsView(workspace: w, items: shown(w), layout: layout, facts: facts)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(w.name)
        .task(id: w.items) { await loadFacts(w.items) }
        .searchable(text: $query, placement: .toolbar, prompt: Text("Search in \(w.name)"))
        .toolbar { toolbar(w) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { (result: Result<[URL], Error>) in
            imported(result)
        }
        .alert("Add Link", isPresented: $addingLink) {
            TextField("https://", text: $linkText)
            Button("Add", action: { addLink() })
            Button("Cancel", role: .cancel, action: {})
        }
        .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in
            model.addToWorkspace(id, urls)
            return true
        }
    }

    private var controls: some View {
        HStack {
            Picker("Show", selection: $tab) {
                ForEach(WorkspaceTab.allCases, id: \.self) { (t: WorkspaceTab) in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Picker("View", selection: $layout) {
                ForEach(WorkspaceLayout.allCases, id: \.self) { (l: WorkspaceLayout) in Text(l.rawValue).tag(l) }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private func toolbar(_ w: Workspace) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Folders and Files…", action: { importing = true })
                Button("Link…", action: { addingLink = true })
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add folders, files or links. Nothing is copied or moved.")
            WorkspaceMenu(workspace: w)
        }
    }

    private func shown(_ w: Workspace) -> [WorkspaceItem] {
        let q: String = query.trimmingCharacters(in: .whitespaces)
        let items: [WorkspaceItem] = w.items.filter { (item: WorkspaceItem) -> Bool in
            guard tab.matches(item) else { return false }
            if q.isEmpty { return true }
            let place: String = item.path ?? item.url ?? ""
            return item.name.localizedCaseInsensitiveContains(q) || place.localizedCaseInsensitiveContains(q)
        }
        guard layout == .changed else { return items }
        // Changed Lately: most recently modified first; links (no date) last.
        func date(_ item: WorkspaceItem) -> Date { facts[item.id]?.modified ?? .distantPast }
        return items.sorted { (a: WorkspaceItem, b: WorkspaceItem) -> Bool in date(a) > date(b) }
    }

    private func loadFacts(_ items: [WorkspaceItem]) async {
        let task = Task.detached(priority: .userInitiated) { () -> [UUID: ItemFacts] in ItemFacts.of(items) }
        let found: [UUID: ItemFacts] = await task.value
        if !Task.isCancelled { facts = found }
    }

    private func imported(_ result: Result<[URL], Error>) {
        if case .success(let urls) = result { model.addToWorkspace(id, urls) }
    }

    private func addLink() {
        let text: String = linkText
        linkText = ""
        guard let url = Bookmarks.normalize(text) else { return model.toast("That isn't a link", undoable: false) }
        model.addToWorkspace(id, [url])
    }
}

private struct WorkspaceHeader: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(workspaceColor(workspace.color)).frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name).font(.title2.weight(.semibold))
                if !workspace.description.isEmpty {
                    Text(workspace.description).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("Nothing is copied or moved").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SampleTips: View {
    let id: UUID
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Workspaces.sampleTips, id: \.self) { (tip: String) in
                Label(tip, systemImage: "lightbulb").font(.callout)
            }
            Button("Remove Sample", action: { model.deleteWorkspace(id) })
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ArchivedBanner: View {
    let workspace: Workspace
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Label("This workspace is archived", systemImage: "archivebox")
            Spacer()
            Button("Restore", action: { model.restoreWorkspace(workspace.id) })
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Up to six pinned items, opened with ⌃⌥1–6.
private struct PinnedRow: View {
    let workspace: Workspace
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(workspace.pinned.enumerated()), id: \.element.id) { (pair: (offset: Int, element: WorkspaceItem)) in
                Button(action: { model.openWorkspaceItem(pair.element) }) {
                    HStack(spacing: 6) {
                        ItemIcon(item: pair.element, side: 18)
                        Text(pair.element.name).lineLimit(1)
                        Text("⌃⌥\(pair.offset + 1)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .help("Open “\(pair.element.name)” (⌃⌥\(pair.offset + 1))")
            }
        }
    }
}

/// The ⋯ menu: Edit Workspace…, Colour, Archive / Restore, Delete…, Remove Sample.
struct WorkspaceMenu: View {
    let workspace: Workspace
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button("Edit Workspace…", action: { model.editWorkspace(workspace.id) })
            Menu("Colour") {
                ForEach(AppModel.workspaceColors, id: \.self) { (c: String) in
                    Button(c == workspace.color ? "✓ \(c.capitalized)" : c.capitalized, action: { model.setWorkspaceColor(workspace.id, c) })
                }
            }
            Divider()
            if workspace.archived {
                Button("Restore", action: { model.restoreWorkspace(workspace.id) })
            } else {
                Button("Archive", action: { model.archiveWorkspace(workspace.id) })
            }
            if workspace.id == Workspaces.sampleID {
                Button("Remove Sample", action: { model.deleteWorkspace(workspace.id) })
            } else {
                Button("Delete…", role: .destructive, action: { model.askDeleteWorkspace(workspace.id) })
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .help("More")
    }
}

/// List, Tiles, Cards, or Changed Lately (a list sorted by date).
private struct WorkspaceItemsView: View {
    let workspace: Workspace
    let items: [WorkspaceItem]
    let layout: WorkspaceLayout
    let facts: [UUID: ItemFacts]

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView("Nothing here yet", systemImage: "tray",
                                   description: Text("Drag folders, files or links here, or use Add. Nothing is copied or moved."))
        } else {
            ScrollView { content }
        }
    }

    @ViewBuilder private var content: some View {
        switch layout {
        case .list, .changed:
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(items) { (item: WorkspaceItem) in ItemRow(workspace: workspace, item: item, fact: facts[item.id], showDate: layout == .changed) }
            }
        case .tiles:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                ForEach(items) { (item: WorkspaceItem) in ItemTile(workspace: workspace, item: item, fact: facts[item.id]) }
            }
        case .cards:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(items) { (item: WorkspaceItem) in ItemCard(workspace: workspace, item: item, fact: facts[item.id]) }
            }
        }
    }
}

/// What the page shows about an item that needs the disk: missing or not, and when it last changed.
struct ItemFacts: Sendable {
    let status: ItemStatus
    let modified: Date?

    static func of(_ items: [WorkspaceItem]) -> [UUID: ItemFacts] {
        var out: [UUID: ItemFacts] = [:]
        for item in items {
            let status: ItemStatus = Workspaces.status(of: item, fileExists: { (p: String) -> Bool in FileManager.default.fileExists(atPath: p) },
                                                       volumeMounted: { (p: String) -> Bool in FileManager.default.fileExists(atPath: p) })
            let modified: Date? = item.path.flatMap { (p: String) -> Date? in
                (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
            out[item.id] = ItemFacts(status: status, modified: modified)
        }
        return out
    }
}

private struct ItemIcon: View {
    let item: WorkspaceItem
    let side: CGFloat

    var body: some View {
        if item.kind == .link {
            Image(systemName: "link").frame(width: side, height: side)
        } else if let path = item.path {
            Image(nsImage: Thumbnails.icon(URL(fileURLWithPath: path))).resizable().frame(width: side, height: side)
        }
    }
}

/// "Can't find it" / "“T7 Shield” isn't connected", with Locate… for files.
private struct ItemProblem: View {
    let workspace: Workspace
    let item: WorkspaceItem
    let fact: ItemFacts?
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text = fact?.status.text {
            HStack(spacing: 6) {
                Text(text).font(.caption).foregroundStyle(.orange)
                Button("Locate…", action: { model.locate(workspace.id, item) }).controlSize(.small)
            }
        }
    }
}

private struct ItemRow: View {
    let workspace: Workspace
    let item: WorkspaceItem
    let fact: ItemFacts?
    let showDate: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            ItemIcon(item: item, side: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if item.pinned { Image(systemName: "pin.fill").foregroundStyle(.secondary).accessibilityLabel("Pinned") }
            ItemProblem(workspace: workspace, item: item, fact: fact)
            Spacer()
            if showDate, let date = fact?.modified {
                Text(date, style: .relative).font(.caption).foregroundStyle(.secondary)
            }
            ItemMenu(workspace: workspace, item: item)
        }
        .padding(.vertical, 4)
        .modifier(ItemActions(workspace: workspace, item: item))
    }

    private var place: String {
        guard let path = item.path else { return item.url ?? "" }
        return model.displayPath(URL(fileURLWithPath: path).deletingLastPathComponent())
    }
}

private struct ItemTile: View {
    let workspace: Workspace
    let item: WorkspaceItem
    let fact: ItemFacts?

    var body: some View {
        VStack(spacing: 6) {
            ItemIcon(item: item, side: 48)
            Text(item.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            ItemProblem(workspace: workspace, item: item, fact: fact)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .overlay(alignment: .topTrailing) { ItemMenu(workspace: workspace, item: item) }
        .modifier(ItemActions(workspace: workspace, item: item))
    }
}

private struct ItemCard: View {
    let workspace: Workspace
    let item: WorkspaceItem
    let fact: ItemFacts?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ItemIcon(item: item, side: 32)
                Spacer()
                ItemMenu(workspace: workspace, item: item)
            }
            Text(item.name).font(.headline).lineLimit(1)
            Text(item.path ?? item.url ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            ItemProblem(workspace: workspace, item: item, fact: fact)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .modifier(ItemActions(workspace: workspace, item: item))
    }
}

/// Double-click opens; right-click shows the same items as ⋯.
private struct ItemActions: ViewModifier {
    let workspace: Workspace
    let item: WorkspaceItem
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: { model.openWorkspaceItem(item) })
            .contextMenu { ItemMenuItems(workspace: workspace, item: item) }
            .accessibilityAction(named: "Open", { model.openWorkspaceItem(item) })
    }
}

private struct ItemMenu: View {
    let workspace: Workspace
    let item: WorkspaceItem

    var body: some View {
        Menu {
            ItemMenuItems(workspace: workspace, item: item)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }
}

private struct ItemMenuItems: View {
    let workspace: Workspace
    let item: WorkspaceItem
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Open", action: { model.openWorkspaceItem(item) })
        if let path = item.path {
            Button("Show in Finder", action: { model.showInFinder([URL(fileURLWithPath: path)]) })
            Button("Copy Path", action: { model.copyPath([URL(fileURLWithPath: path)]) })
            Button("Locate…", action: { model.locate(workspace.id, item) })
        } else if let url = item.url {
            Button("Copy Link", action: { Pasteboard.write(url) })
        }
        Divider()
        Button(item.pinned ? "Unpin" : "Pin", action: { model.setPinned(workspace.id, item.id, !item.pinned) })
        Button("Remove from Workspace", action: { model.removeFromWorkspace(workspace.id, [item.id]) })
    }
}

/// Right-click / Peek "Add to Workspace" (F11.2): the open workspaces, then New Workspace… with these items.
struct AddToWorkspaceMenu: View {
    let urls: [URL]
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu("Add to Workspace") {
            ForEach(model.activeWorkspaces) { (w: Workspace) in
                Button(w.name, action: { model.addToWorkspace(w.id, urls) })
            }
            if !model.activeWorkspaces.isEmpty { Divider() }
            Button("New Workspace…", action: { model.newWorkspace(with: urls) })
        }
    }
}
