import SwiftUI
import AppKit
import FileOSCore

/// F12.3 views.
enum BookmarkLayout: String, CaseIterable, Sendable {
    case grid = "Grid", headlines = "Headlines", masonry = "Masonry", list = "List"
}

/// The link the Edit Title… / Tags… alert is changing.
private struct LinkEdit {
    var id: UUID?
    var text = ""
}

/// F12: ⌘V saves a copied link; filters, sorts, search, four views and the ··· menu.
struct BookmarksPage: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var filter: BookmarkFilter = .all
    @State private var sort: BookmarkSort = .newest
    @State private var layout: BookmarkLayout = .grid
    @State private var edit = LinkEdit()
    @State private var editingTitle = false
    @State private var editingTags = false

    private static let filters: [BookmarkFilter] = [.all, .articles, .videos, .images, .files, .favourites]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("Filter", selection: $filter) {
                ForEach(Self.filters, id: \.self) { (f: BookmarkFilter) in Text(f.rawValue).tag(f) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            BookmarkContent(links: shown, layout: layout, grouped: sort == .newest || sort == .oldest,
                            onEditTitle: { (b: Bookmark) in begin(b, tags: false) },
                            onEditTags: { (b: Bookmark) in begin(b, tags: true) })
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Bookmarks")
        .searchable(text: $query, placement: .toolbar, prompt: Text("Search bookmarks"))
        .toolbar { toolbar }
        .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in
            model.saveLinks(urls, collection: model.placeCollection)
            return true
        }
        .alert("Edit Title", isPresented: $editingTitle) {
            TextField("Title", text: $edit.text)
            Button("Save", action: { saveTitle() })
            Button("Cancel", role: .cancel, action: {})
        }
        .alert("Tags", isPresented: $editingTags) {
            TextField("design, #swift", text: $edit.text)
            Button("Save", action: { saveTags() })
            Button("Cancel", role: .cancel, action: {})
        } message: {
            Text("Separate tags with commas or #.")
        }
    }

    private var header: some View {
        HStack {
            Text(placeTitle).font(.title2.weight(.semibold))
            Text(shown.count == 1 ? "1 link" : "\(shown.count) links").foregroundStyle(.secondary)
            Spacer()
            if case .collection(let id) = model.bookmarkPlace {
                Button("Delete Collection…", role: .destructive, action: { model.askDeleteCollection(id) })
            }
        }
    }

    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: $layout) {
                ForEach(BookmarkLayout.allCases, id: \.self) { (l: BookmarkLayout) in Text(l.rawValue).tag(l) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Picker("Sort", selection: $sort) {
                ForEach(BookmarkSort.allCases, id: \.self) { (s: BookmarkSort) in Text(s.rawValue).tag(s) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            TagMenu()
            IconButton(symbol: "folder.badge.plus", label: "New Collection", help: "New Collection (⌥⇧⌘N)", disabled: false,
                       action: { model.askNewCollection() })
            IconButton(symbol: "plus", label: "Add Link", help: "Add Link (⇧⌘L)", disabled: false,
                       action: { model.showAddLink = true })
        }
    }

    private var placeTitle: String {
        switch model.bookmarkPlace {
        case .all: return "All Bookmarks"
        case .favourites: return "Favourites"
        case .unsorted: return "Unsorted"
        case .collection(let id): return model.collection(id)?.name ?? "Collection"
        case .tag(let t): return "#\(t)"
        }
    }

    private var shown: [Bookmark] {
        var list: [Bookmark] = model.bookmarkState.bookmarks
        var collection: UUID?
        var tag: String?
        switch model.bookmarkPlace {
        case .all: break
        case .favourites: list = list.filter { (b: Bookmark) -> Bool in b.favourite }
        case .unsorted: list = list.filter { (b: Bookmark) -> Bool in b.collections.isEmpty }
        case .collection(let id): collection = id
        case .tag(let t): tag = t
        }
        return Bookmarks.filter(list, filter: filter, query: query, collection: collection, tag: tag, sort: sort)
    }

    private func begin(_ b: Bookmark, tags: Bool) {
        edit = LinkEdit(id: b.id, text: tags ? b.tags.joined(separator: ", ") : b.title)
        if tags { editingTags = true } else { editingTitle = true }
    }

    private func saveTitle() {
        guard let id = edit.id else { return }
        let title: String = edit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        model.editBookmark(id, "Edit Title") { (b: inout Bookmark) in b.title = title }
    }

    private func saveTags() {
        guard let id = edit.id else { return }
        let tags: [String] = Bookmarks.parseTags(edit.text)
        model.editBookmark(id, "Tags") { (b: inout Bookmark) in b.tags = tags }
    }
}

/// Tags (F12.2) as a menu of places.
private struct TagMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            let tags: [String] = Bookmarks.tags(model.bookmarkState.bookmarks)
            if tags.isEmpty { Text("No tags yet") }
            ForEach(tags, id: \.self) { (t: String) in
                Button("#\(t)", action: { model.bookmarkPlace = .tag(t) })
            }
        } label: {
            Label("Tags", systemImage: "number")
        }
        .help("Tags")
    }
}

private struct DayGroup: Identifiable {
    let id: Int
    let title: String
    var links: [Bookmark]
}

/// Grid, Headlines, Masonry, or List; Headlines and List are grouped by day when sorted by date.
private struct BookmarkContent: View {
    let links: [Bookmark]
    let layout: BookmarkLayout
    let grouped: Bool
    let onEditTitle: @MainActor (Bookmark) -> Void
    let onEditTags: @MainActor (Bookmark) -> Void

    var body: some View {
        if links.isEmpty {
            ContentUnavailableView("No bookmarks", systemImage: "bookmark",
                                   description: Text("Copy a link and press ⌘V, or use Add Link (⇧⌘L)."))
        } else {
            ScrollView { content.padding(.bottom, 12) }
        }
    }

    @ViewBuilder private var content: some View {
        switch layout {
        case .grid:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(links) { (b: Bookmark) in LinkCard(link: b, imageHeight: 120, menu: menu(b)) }
            }
        case .masonry:
            HStack(alignment: .top, spacing: 12) {
                ForEach(0..<3, id: \.self) { (column: Int) in
                    LazyVStack(spacing: 12) {
                        ForEach(Self.column(links, column)) { (b: Bookmark) in
                            LinkCard(link: b, imageHeight: b.image == nil ? 0 : 160, menu: menu(b))
                        }
                    }
                }
            }
        case .headlines, .list:
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(days) { (day: DayGroup) in
                    if grouped { Text(day.title).font(.headline).padding(.top, 8) }
                    ForEach(day.links) { (b: Bookmark) in LinkRow(link: b, headline: layout == .headlines, menu: menu(b)) }
                }
            }
        }
    }

    private func menu(_ b: Bookmark) -> LinkMenu { LinkMenu(link: b, onEditTitle: onEditTitle, onEditTags: onEditTags) }

    static func column(_ links: [Bookmark], _ n: Int) -> [Bookmark] {
        links.enumerated().filter { (pair: (offset: Int, element: Bookmark)) -> Bool in pair.offset % 3 == n }
            .map { (pair: (offset: Int, element: Bookmark)) -> Bookmark in pair.element }
    }

    /// Runs of links added on the same day, in the current order.
    private var days: [DayGroup] {
        guard grouped else { return [DayGroup(id: 0, title: "", links: links)] }
        let calendar: Calendar = .current
        var out: [DayGroup] = []
        for b in links {
            let title: String = Self.dayTitle(b.added, calendar)
            if out.last?.title == title {
                out[out.count - 1].links.append(b)
            } else {
                out.append(DayGroup(id: out.count, title: title, links: [b]))
            }
        }
        return out
    }

    static func dayTitle(_ date: Date, _ calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .complete, time: .omitted)
    }
}

private struct SiteIcon: View {
    let link: Bookmark

    var body: some View {
        if let icon = link.icon, let url = URL(string: icon) {
            AsyncImage(url: url) { (image: Image) in image.resizable() } placeholder: { Image(systemName: "globe") }
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: Self.symbol(link.type)).frame(width: 16, height: 16)
        }
    }

    static func symbol(_ type: LinkType) -> String {
        switch type {
        case .article: return "doc.richtext"
        case .video: return "play.rectangle"
        case .image: return "photo"
        case .file: return "doc.zipper"
        }
    }
}

private struct LinkCard: View {
    let link: Bookmark
    let imageHeight: CGFloat
    let menu: LinkMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if imageHeight > 0 { picture }
            HStack(alignment: .top) {
                Text(link.title).font(.headline).lineLimit(2)
                Spacer()
                menu
            }
            HStack(spacing: 6) {
                SiteIcon(link: link)
                Text(link.site).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if link.favourite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow).accessibilityLabel("Favourite") }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .modifier(LinkActions(link: link, menu: menu))
    }

    @ViewBuilder private var picture: some View {
        if let image = link.image, let url = URL(string: image) {
            AsyncImage(url: url) { (img: Image) in img.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                .frame(height: imageHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Color.secondary.opacity(0.12)
                .frame(height: imageHeight)
                .overlay { Image(systemName: SiteIcon.symbol(link.type)).font(.largeTitle).foregroundStyle(.secondary) }
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct LinkRow: View {
    let link: Bookmark
    let headline: Bool
    let menu: LinkMenu

    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(link: link)
            VStack(alignment: .leading, spacing: 1) {
                Text(link.title).font(headline ? .title3.weight(.semibold) : .body).lineLimit(headline ? 2 : 1)
                Text(headline ? link.site : link.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if link.favourite { Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Favourite") }
            if !link.tags.isEmpty {
                Text(link.tags.map { (t: String) -> String in "#\(t)" }.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            menu
        }
        .padding(.vertical, headline ? 6 : 2)
        .modifier(LinkActions(link: link, menu: menu))
    }
}

/// Double-click opens in the browser; right-click shows the ··· items.
private struct LinkActions: ViewModifier {
    let link: Bookmark
    let menu: LinkMenu

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: { openLink(link) })
            .contextMenu { menu.items }
            .help(link.url)
    }
}

@MainActor private func openLink(_ link: Bookmark) {
    if let url = Bookmarks.normalize(link.url) { _ = NSWorkspace.shared.open(url) }
}

/// ···: Open in Browser, Copy Link, Edit Title…, Add to Favourites, Tags…, Collections, In Workspace, Remove.
private struct LinkMenu: View {
    let link: Bookmark
    let onEditTitle: @MainActor (Bookmark) -> Void
    let onEditTags: @MainActor (Bookmark) -> Void

    var body: some View {
        Menu { items } label: { Image(systemName: "ellipsis") }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
    }

    var items: some View { LinkMenuItems(link: link, onEditTitle: onEditTitle, onEditTags: onEditTags) }
}

private struct LinkMenuItems: View {
    let link: Bookmark
    let onEditTitle: @MainActor (Bookmark) -> Void
    let onEditTags: @MainActor (Bookmark) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Open in Browser", action: { openLink(link) })
        Button("Copy Link", action: { Pasteboard.write(link.url) })
        Divider()
        Button("Edit Title…", action: { onEditTitle(link) })
        Button(link.favourite ? "Remove from Favourites" : "Add to Favourites", action: { toggleFavourite() })
        Button("Tags…", action: { onEditTags(link) })
        Menu("Collections") {
            ForEach(model.bookmarkState.collections) { (c: BookmarkCollection) in
                Button(link.collections.contains(c.id) ? "✓ \(c.name)" : c.name, action: { toggle(c.id) })
            }
            if !model.bookmarkState.collections.isEmpty { Divider() }
            Button("New Collection…", action: { model.askNewCollection() })
        }
        Menu("In Workspace") {
            ForEach(model.activeWorkspaces) { (w: Workspace) in
                Button(w.name, action: { model.addBookmark(link, toWorkspace: w.id) })
            }
        }
        Divider()
        Button("Remove", action: { model.removeBookmarks([link.id]) })
    }

    private func toggleFavourite() {
        let on: Bool = !link.favourite
        model.editBookmark(link.id, on ? "Add to Favourites" : "Remove from Favourites") { (b: inout Bookmark) in b.favourite = on }
    }

    private func toggle(_ collection: UUID) {
        model.editBookmark(link.id, "Collections") { (b: inout Bookmark) in
            if let i = b.collections.firstIndex(of: collection) { b.collections.remove(at: i) } else { b.collections.append(collection) }
        }
    }
}

/// ⌥⇧⌘N (F12.2): a name and an icon.
struct NewCollectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon = "folder"

    static let icons: [String] = ["folder", "book", "star", "heart", "paintbrush", "hammer", "globe", "film",
                                  "photo", "music.note", "cart", "briefcase"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Collection").font(.title3.weight(.semibold))
            TextField("Name", text: $name, prompt: Text("Reading"))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30)), count: 6), spacing: 6) {
                ForEach(Self.icons, id: \.self) { (symbol: String) in iconButton(symbol) }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: { dismiss() }).keyboardShortcut(.cancelAction)
                Button("Create", action: { create() }).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func iconButton(_ symbol: String) -> some View {
        Button(action: { icon = symbol }) {
            Image(systemName: symbol)
                .frame(width: 26, height: 26)
                .background(symbol == icon ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol)
        .accessibilityAddTraits(symbol == icon ? .isSelected : [])
    }

    private func create() {
        model.createCollection(name: name, icon: icon)
        dismiss()
    }
}
