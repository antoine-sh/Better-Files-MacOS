import AppKit
import FileOSCore

/// Where the Bookmarks page is looking (sidebar rows and the page's own pickers).
enum BookmarkPlace: Hashable, Sendable {
    case all, favourites, unsorted, collection(UUID), tag(String)
}

/// F11.1: how a new workspace starts.
enum WorkspaceStart: String, CaseIterable, Sendable {
    case empty = "Empty", files = "Folders and Files…", link = "Paste Link"
}

/// The New / Edit Workspace sheet's fields.
struct WorkspaceDraft: Sendable {
    var editing: UUID?
    var name = ""
    var description = ""
    var color = "blue"
    var start: WorkspaceStart = .empty
    var urls: [URL] = []
    var link = ""
}

/// Fetches a saved link's page once for its title, picture and icon (F12.1). Off the main actor;
/// http(s) only, 5 s, and at most 1 MB is read.
enum LinkMeta {
    static let maxBytes = 1_000_000

    static func fetch(_ url: URL) async -> (title: String?, image: String?, icon: String?)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maxBytes { break } // the <head> is near the top; the rest isn't needed
            }
            let base: URL = response.url ?? url
            return Bookmarks.extractMeta(html: String(decoding: data, as: UTF8.self), base: base)
        } catch {
            return nil
        }
    }
}

// MARK: - Workspaces (F11). References only: nothing here copies, moves or deletes a file.

extension AppModel {
    static let workspaceColors: [String] = ["blue", "purple", "pink", "red", "orange", "yellow", "green", "gray"]

    var activeWorkspaces: [Workspace] { workspaces.filter { (w: Workspace) -> Bool in !w.archived } }

    func workspace(_ id: UUID) -> Workspace? { workspaces.first { (w: Workspace) -> Bool in w.id == id } }

    /// Saves the list; with a label, registers an undo that puts the previous list back.
    func setWorkspaces(_ new: [Workspace], undo label: String?) {
        let previous: [Workspace] = workspaces
        workspaces = new
        store.set("workspaces", new)
        guard let label else { return }
        undo.push(label) {
            await self.setWorkspaces(previous, undo: nil)
            return RestoreResult()
        }
    }

    static func workspaceItem(_ url: URL) -> WorkspaceItem? {
        if url.isFileURL {
            return .file(FileOps.canonical(url).path, isFolder: isBrowsableFolder(url))
        }
        return Bookmarks.normalize(url.absoluteString).map { (u: URL) -> WorkspaceItem in .link(u.absoluteString) }
    }

    /// ⌥⌘N / +, or "New Workspace…" from Add to Workspace with the chosen items.
    func newWorkspace(with urls: [URL] = []) {
        workspaceDraft = WorkspaceDraft(start: urls.isEmpty ? .empty : .files, urls: urls)
        showSearch = false
        peek.close()
        showWorkspaceSheet = true
    }

    func editWorkspace(_ id: UUID) {
        guard let w = workspace(id) else { return }
        workspaceDraft = WorkspaceDraft(editing: id, name: w.name, description: w.description, color: w.color)
        showWorkspaceSheet = true
    }

    /// The sheet's Create / Save: nil when done, else what to fix.
    @discardableResult
    func commitWorkspaceDraft(_ d: WorkspaceDraft) -> String? {
        if let id = d.editing {
            guard !d.name.trimmingCharacters(in: .whitespaces).isEmpty else { return WorkspaceError.emptyName.localizedDescription }
            setWorkspaces(Workspaces.edit(workspaces, id, name: d.name, description: d.description, color: d.color), undo: "Edit Workspace")
            return nil
        }
        var items: [WorkspaceItem] = []
        switch d.start {
        case .empty: break
        case .files: items = d.urls.compactMap { (u: URL) -> WorkspaceItem? in Self.workspaceItem(u) }
        case .link:
            guard let url = Bookmarks.normalize(d.link) else { return "That isn't a link" }
            items = [.link(url.absoluteString)]
        }
        do {
            let (list, w) = try Workspaces.create(workspaces, name: d.name, description: d.description, color: d.color)
            setWorkspaces(Workspaces.add(list, to: w.id, items: items), undo: "New Workspace")
            page = .workspace(w.id)
            toast("Created “\(w.name)”", undoable: true)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Drag, picker, right-click > Add to Workspace, ⌘V: files and folders stay where they are.
    func addToWorkspace(_ id: UUID, _ urls: [URL]) {
        guard let w = workspace(id) else { return }
        let items: [WorkspaceItem] = urls.compactMap { (u: URL) -> WorkspaceItem? in Self.workspaceItem(u) }
        let next: [Workspace] = Workspaces.add(workspaces, to: id, items: items)
        let added: Int = (next.first { (x: Workspace) -> Bool in x.id == id }?.items.count ?? 0) - w.items.count
        guard added > 0 else {
            toast(items.isEmpty ? "Nothing to add" : "Already in “\(w.name)”", undoable: false)
            return
        }
        setWorkspaces(next, undo: "Add to Workspace")
        toast("Added \(Self.items(added)) to “\(w.name)”", undoable: true)
    }

    /// ⌘V on a workspace: copied files, else a copied link.
    func pasteIntoWorkspace(_ id: UUID) {
        let files: [URL] = Pasteboard.fileURLs()
        if !files.isEmpty { return addToWorkspace(id, files) }
        guard let text = Pasteboard.string(), let url = Bookmarks.normalize(text) else {
            return toast("Copy a file or a link first", undoable: false)
        }
        addToWorkspace(id, [url])
    }

    /// Remove only unlists (F11.3).
    func removeFromWorkspace(_ id: UUID, _ items: Set<UUID>) {
        guard let w = workspace(id), !items.isEmpty else { return }
        setWorkspaces(Workspaces.remove(workspaces, from: id, items: items), undo: "Remove from Workspace")
        toast("Removed \(Self.items(items.count)) from “\(w.name)”", undoable: true)
    }

    func setPinned(_ id: UUID, _ item: UUID, _ pinned: Bool) {
        do {
            setWorkspaces(try Workspaces.pin(workspaces, in: id, item: item, pinned), undo: pinned ? "Pin" : "Unpin")
        } catch {
            toast(error.localizedDescription, undoable: false)
        }
    }

    func setWorkspaceColor(_ id: UUID, _ color: String) {
        guard let w = workspace(id) else { return }
        setWorkspaces(Workspaces.edit(workspaces, id, name: w.name, description: w.description, color: color), undo: "Colour")
    }

    func archiveWorkspace(_ id: UUID) {
        guard let w = workspace(id) else { return }
        setWorkspaces(Workspaces.archive(workspaces, id), undo: "Archive")
        toast("Archived “\(w.name)”", undoable: true)
    }

    func restoreWorkspace(_ id: UUID) {
        guard let w = workspace(id) else { return }
        setWorkspaces(Workspaces.restore(workspaces, id), undo: "Restore")
        toast("Restored “\(w.name)”", undoable: true)
    }

    func askDeleteWorkspace(_ id: UUID) {
        workspaceToDelete = id
        showDeleteWorkspace = true
    }

    /// After "Delete “X”?" (or Remove Sample): only the list goes; its files are untouched.
    func deleteWorkspace(_ id: UUID) {
        guard let w = workspace(id) else { return }
        if page == .workspace(id) { page = .browser }
        setWorkspaces(Workspaces.delete(workspaces, id), undo: "Delete Workspace")
        toast(id == Workspaces.sampleID ? "Removed the sample workspace" : "Deleted “\(w.name)”", undoable: true)
    }

    static func deleteWorkspaceMessage(_ name: String) -> String {
        "“\(name)” will be removed from FileOS. Its folders, files and links stay where they are."
    }

    /// ⌃1–⌃9.
    func openWorkspace(number n: Int) {
        let list: [Workspace] = activeWorkspaces
        guard n >= 1, n <= list.count else { return }
        page = .workspace(list[n - 1].id)
    }

    /// ⌃⌥1–6 on a workspace page.
    func pinnedItem(_ n: Int) -> WorkspaceItem? {
        guard case .workspace(let id) = page, let pins = workspace(id)?.pinned, n >= 1, n <= pins.count else { return nil }
        return pins[n - 1]
    }

    func openPinned(_ n: Int) {
        if let item = pinnedItem(n) { openWorkspaceItem(item) }
    }

    func itemStatus(_ item: WorkspaceItem) -> ItemStatus {
        Workspaces.status(of: item, fileExists: { (p: String) -> Bool in FileManager.default.fileExists(atPath: p) },
                          volumeMounted: { (p: String) -> Bool in FileManager.default.fileExists(atPath: p) })
    }

    func openWorkspaceItem(_ item: WorkspaceItem) {
        if item.kind == .link {
            if let url = item.url.flatMap({ (s: String) -> URL? in Bookmarks.normalize(s) }) { _ = NSWorkspace.shared.open(url) }
            return
        }
        guard let path = item.path else { return }
        if let problem = itemStatus(item).text { return toast(problem, undoable: false) }
        openItem(URL(fileURLWithPath: path))
    }

    /// Locate…: point a missing item at where it is now.
    func locate(_ id: UUID, _ item: WorkspaceItem) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Where is “\(item.name)” now?"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relocate(id, item, to: url)
    }

    func relocate(_ id: UUID, _ item: WorkspaceItem, to url: URL) {
        setWorkspaces(Workspaces.relocate(workspaces, in: id, item: item.id, to: FileOps.canonical(url).path,
                                          isFolder: Self.isBrowsableFolder(url)), undo: "Locate")
    }

    /// ⌘V on Bookmarks or a workspace; false elsewhere, so the files paste as usual.
    func pasteOnPage() -> Bool {
        switch page {
        case .bookmarks:
            saveCopiedLink()
            return true
        case .workspace(let id):
            pasteIntoWorkspace(id)
            return true
        default:
            return false
        }
    }
}

// MARK: - Bookmarks (F12)

extension AppModel {
    func setBookmarks(_ new: BookmarkState, undo label: String?) {
        let previous: BookmarkState = bookmarkState
        bookmarkState = new
        store.set("bookmarks", new.bookmarks)
        store.set("bookmarkCollections", new.collections)
        guard let label else { return }
        undo.push(label) {
            await self.setBookmarks(previous, undo: nil)
            return RestoreResult()
        }
    }

    var placeCollection: UUID? {
        if case .collection(let id) = bookmarkPlace { return id }
        return nil
    }

    func bookmark(_ id: UUID) -> Bookmark? { bookmarkState.bookmarks.first { (b: Bookmark) -> Bool in b.id == id } }

    func collection(_ id: UUID) -> BookmarkCollection? {
        bookmarkState.collections.first { (c: BookmarkCollection) -> Bool in c.id == id }
    }

    /// "Saved" + Undo, or "Already saved". Into the open collection when one is open.
    @discardableResult
    func saveLink(_ text: String, collection: UUID? = nil) -> Bool {
        guard let url = Bookmarks.normalize(text) else {
            toast("That isn't a link", undoable: false)
            return false
        }
        let (next, saved, already) = Bookmarks.add(bookmarkState, url: url, collection: collection)
        if already {
            toast("Already saved", undoable: false)
            return true
        }
        setBookmarks(next, undo: "Save Link")
        toast("Saved", undoable: true)
        if fetchesLinkMeta { Task { await fillMeta(saved) } }
        return true
    }

    /// Drops onto Bookmarks or a collection: links are saved, files are ignored.
    func saveLinks(_ urls: [URL], collection: UUID?) {
        for url in urls where !url.isFileURL { saveLink(url.absoluteString, collection: collection) }
    }

    /// ⌘V on Bookmarks and ⌃⌥⌘B anywhere.
    func saveCopiedLink() {
        guard let text = Pasteboard.string() else { return toast("Copy a link first", undoable: false) }
        saveLink(text, collection: page == .bookmarks ? placeCollection : nil)
    }

    /// Reads the page once; the title only replaces the placeholder (the site), never one the user typed.
    func fillMeta(_ saved: Bookmark) async {
        guard let url = URL(string: saved.url), let meta = await LinkMeta.fetch(url) else { return }
        let next: BookmarkState = Bookmarks.update(bookmarkState, saved.id) { (b: inout Bookmark) in
            if b.title == b.site, let title = meta.title { b.title = title }
            if b.image == nil { b.image = meta.image }
            if b.icon == nil { b.icon = meta.icon }
        }
        setBookmarks(next, undo: nil)
    }

    func editBookmark(_ id: UUID, _ label: String, _ change: (inout Bookmark) -> Void) {
        setBookmarks(Bookmarks.update(bookmarkState, id, change), undo: label)
    }

    func removeBookmarks(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        setBookmarks(Bookmarks.remove(bookmarkState, ids), undo: "Remove Link")
        toast(ids.count == 1 ? "Removed 1 link" : "Removed \(ids.count) links", undoable: true)
    }

    func addBookmark(_ b: Bookmark, toWorkspace id: UUID) {
        if let url = URL(string: b.url) { addToWorkspace(id, [url]) }
    }

    /// ⌥⇧⌘N.
    func askNewCollection() {
        page = .bookmarks
        showNewCollection = true
    }

    func createCollection(name: String, icon: String) {
        let (next, made) = Bookmarks.createCollection(bookmarkState, name: name, icon: icon)
        setBookmarks(next, undo: "New Collection")
        page = .bookmarks
        bookmarkPlace = .collection(made.id)
        toast("Created “\(made.name)”", undoable: true)
    }

    func askDeleteCollection(_ id: UUID) {
        collectionToDelete = id
        showDeleteCollection = true
    }

    func deleteCollection(_ id: UUID) {
        guard let c = collection(id) else { return }
        if bookmarkPlace == .collection(id) { bookmarkPlace = .all }
        setBookmarks(Bookmarks.deleteCollection(bookmarkState, id), undo: "Delete Collection")
        toast("Deleted “\(c.name)”", undoable: true)
    }

    func deleteCollectionMessage(_ id: UUID) -> String {
        let n: Int = bookmarkState.bookmarks.filter { (b: Bookmark) -> Bool in b.collections.contains(id) }.count
        return n == 1 ? "Its 1 link will be removed too." : "Its \(n) links will be removed too."
    }
}
