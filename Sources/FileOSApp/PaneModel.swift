import Foundation
import Observation
import FileOSCore

enum ViewMode: String, Codable, CaseIterable { case list, icons, columns }

/// F3.2: one size for all folders.
enum IconSize: Int, Codable, CaseIterable {
    case tiny, extraSmall, small, medium, large

    var title: String { ["Tiny", "Extra Small", "Small", "Medium", "Large"][rawValue] }
    var side: CGFloat { [24, 40, 56, 88, 128][rawValue] }
    var listIcon: CGFloat { [12, 14, 16, 20, 24][rawValue] }
    /// Medium and Large show real previews (F3.3).
    var showsPreviews: Bool { rawValue >= IconSize.medium.rawValue }
}

extension Entry {
    /// "Folder" or the system's description of the type ("PDF document"), for the Kind column.
    var kindName: String { isDirectory ? "Folder" : kindDescription(name) }
}

/// One visible line: a folder's entry, or a child of a folder expanded in place (list view).
struct Row: Identifiable, Hashable {
    let entry: Entry
    let depth: Int
    var id: String { entry.id }
    var kindName: String { entry.kindName }
}

struct RowSection: Identifiable {
    let title: String
    let rows: [Row]
    var id: String { title }
}

@MainActor @Observable
final class PaneModel {
    private(set) var url: URL
    private(set) var entries: [Entry] = []
    var selection: Set<Entry.ID> = []
    var view: ViewMode = .list
    private(set) var prefs = FolderPrefs()
    /// Mirrors `prefs` for the list's clickable column headers; see `tableSortChanged`.
    var sort: [KeyPathComparator<Row>] = [PaneModel.comparator(.name, ascending: true)]
    var filter = ""
    private(set) var expanded: Set<String> = []
    private(set) var children: [String: [Entry]] = [:]
    /// Column view: folders opened to the right of `url`, outermost first.
    private(set) var trail: [URL] = []
    /// The item showing an inline rename field, and whether the preview pane hosts the field rather
    /// than the item's row: exactly one field may exist, or the one that loses focus commits early.
    var renaming: String?
    var renamingInPreview = false
    private var anchor: String?
    private var cursor: String?
    private(set) var error: FileOSError?
    private(set) var freeSpace: Int64 = 0
    private(set) var history: [URL] = []
    private(set) var forwardStack: [URL] = []
    var showHidden: Bool

    @ObservationIgnored private let store: Store?
    /// The Downloads folder groups by kind and date the Smart Downloads way (F9.1, F9.2).
    @ObservationIgnored private let downloads: URL?
    private let watcher = DirectoryWatcher()
    @ObservationIgnored private var reloadPending = false

    init(url: URL, showHidden: Bool = false, store: Store? = nil, downloads: URL? = nil) {
        self.url = FileOps.canonical(url)
        self.showHidden = showHidden
        self.store = store
        self.downloads = downloads.map { (u: URL) -> URL in FileOps.canonical(u) }
        loadPrefs()
        reload()
    }

    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { url.path != "/" }

    /// Where new folders and pastes land: the deepest open column in column view, else this folder.
    var currentFolder: URL {
        guard view == .columns, let index = selectedColumn else { return url }
        return columnDirs[index]
    }

    /// Whether the rename field for `id` belongs in the preview pane (`preview`) or in its row.
    func hostsRename(_ id: String, preview: Bool) -> Bool { renaming == id && renamingInPreview == preview }

    /// Top-level entries after the filter and the folder's sort.
    // shortcut: recomputed per render; cache it if huge folders get slow
    var visibleEntries: [Entry] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let shown = needle.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        return Arrange.sorted(shown, prefs)
    }

    var sections: [RowSection] {
        let list: [Entry] = visibleEntries
        if url == downloads, prefs.group != .none { return downloadSections(list) }
        return Arrange.groups(list, by: prefs.group, now: Date()).map { (group: (title: String, entries: [Entry])) -> RowSection in
            RowSection(title: group.title, rows: flatten(group.entries, depth: 0))
        }
    }

    private func downloadSections(_ list: [Entry]) -> [RowSection] {
        var out: [RowSection] = []
        if prefs.group == .date {
            for group in Tidy.groupByDate(list, now: Date(), calendar: .current) {
                out.append(RowSection(title: group.label, rows: flatten(group.items, depth: 0)))
            }
            return out
        }
        let folders: [Entry] = list.filter { (e: Entry) -> Bool in e.isDirectory }
        if !folders.isEmpty { out.append(RowSection(title: "Folders", rows: flatten(folders, depth: 0))) }
        for group in Tidy.groupByKind(list) {
            out.append(RowSection(title: group.kind?.rawValue ?? "Downloading", rows: flatten(group.items, depth: 0)))
        }
        return out
    }

    var rows: [Row] { sections.flatMap { (s: RowSection) -> [Row] in s.rows } }

    private func flatten(_ list: [Entry], depth: Int) -> [Row] {
        var out: [Row] = []
        for entry in list {
            out.append(Row(entry: entry, depth: depth))
            if entry.isDirectory, expanded.contains(entry.id), let kids = children[entry.id] {
                out += flatten(Arrange.sorted(kids, prefs), depth: depth + 1)
            }
        }
        return out
    }

    var selectedURLs: [URL] { selection.sorted().map { (p: String) -> URL in URL(fileURLWithPath: p) } }

    /// Selected items currently on screen (the filter or a collapsed folder can hide some):
    /// what menu commands like Move to Trash act on.
    var visibleSelectedURLs: [URL] {
        shownIDs.filter { (id: String) -> Bool in selection.contains(id) }.map { (p: String) -> URL in URL(fileURLWithPath: p) }
    }

    /// Every item on screen, in display order (all columns in column view).
    var shownIDs: [String] {
        var shown: [String]
        if view == .columns {
            shown = []
            for index in columnDirs.indices {
                shown += columnEntries(index).map { (e: Entry) -> String in e.id }
            }
        } else {
            shown = rows.map { (r: Row) -> String in r.id }
        }
        return shown
    }

    /// Selected items the filter still shows, for the status bar.
    var visibleSelectionCount: Int {
        var n = 0
        for row in rows where selection.contains(row.id) { n += 1 }
        return n
    }

    // MARK: Navigation

    func navigate(to target: URL, select: URL? = nil) {
        let target = FileOps.canonical(target)
        if target != url {
            history.append(url)
            forwardStack.removeAll()
        }
        show(target, select: select)
    }

    func back() {
        guard let previous = history.popLast() else { return }
        forwardStack.append(url)
        show(previous, select: nil)
    }

    func forward() {
        guard let next = forwardStack.popLast() else { return }
        history.append(url)
        show(next, select: nil)
    }

    func up() {
        guard canGoUp else { return }
        navigate(to: url.deletingLastPathComponent(), select: url)
    }

    func reload() {
        do {
            entries = try FileOps.listDirectory(url, showHidden: showHidden)
            error = nil
            watcher.watch(url) { [weak self] in self?.scheduleReload() }
        } catch {
            watcher.stop() // a deleted folder's old vnode would never fire again
            entries = []
            // Non-FileOSError failures (e.g. not a directory) read as "can't be found" rather than a blank pane.
            self.error = (error as? FileOSError) ?? .notFound(url.path)
        }
        // shortcut: only the open folder is watched; expanded subfolders refresh with it
        for id in expanded {
            if let kids = try? FileOps.listDirectory(URL(fileURLWithPath: id), showHidden: showHidden) {
                children[id] = kids
            } else {
                expanded.remove(id)
                children[id] = nil
            }
        }
        trail = trail.filter { (u: URL) -> Bool in FileManager.default.fileExists(atPath: u.path) }
        // Selection can include expanded children and column items, so keep whatever still exists.
        selection = selection.filter { (p: String) -> Bool in (try? FileManager.default.attributesOfItem(atPath: p)) != nil }
        freeSpace = FileOps.diskInfo(for: url).free
    }

    private func show(_ target: URL, select: URL?) {
        url = target
        filter = ""
        expanded = []
        children = [:]
        trail = []
        renaming = nil
        renamingInPreview = false
        selection = select.map { (u: URL) -> Set<String> in [FileOps.canonical(u).path] } ?? []
        anchor = selection.first
        cursor = anchor
        loadPrefs()
        reload()
    }

    /// Coalesces bursts of change events (another app writing many files) into one reload.
    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            reloadPending = false
            reload()
        }
    }

    // MARK: Sort and group (F3.4), persisted per folder

    static let prefsKey = "folderPrefs"

    nonisolated static func comparator(_ key: SortKey, ascending: Bool) -> KeyPathComparator<Row> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch key {
        case .name: return KeyPathComparator(\Row.entry.name, comparator: String.StandardComparator.localizedStandard, order: order)
        case .kind: return KeyPathComparator(\Row.kindName, order: order)
        case .modified: return KeyPathComparator(\Row.entry.modified, order: order)
        case .added: return KeyPathComparator(\Row.entry.added, order: order)
        case .size: return KeyPathComparator(\Row.entry.size, order: order)
        }
    }

    private func loadPrefs() {
        let all: [String: FolderPrefs] = store?.get(Self.prefsKey, default: [String: FolderPrefs]()) ?? [:]
        prefs = all[url.path] ?? FolderPrefs()
        syncSort()
    }

    func setPrefs(_ new: FolderPrefs) {
        guard new != prefs else { return }
        prefs = new
        syncSort()
        guard let store else { return }
        var all: [String: FolderPrefs] = store.get(Self.prefsKey, default: [String: FolderPrefs]())
        all[url.path] = new
        store.set(Self.prefsKey, all)
    }

    private func syncSort() {
        let wanted: KeyPathComparator<Row> = Self.comparator(prefs.sortKey, ascending: prefs.ascending)
        if sort != [wanted] { sort = [wanted] }
    }

    /// A click on a list column title changed `sort`; record it as the folder's sort.
    func tableSortChanged() {
        guard let first = sort.first else { return }
        for key in SortKey.allCases where Self.comparator(key, ascending: true).keyPath == first.keyPath {
            var new = prefs
            new.sortKey = key
            new.ascending = first.order == .forward
            setPrefs(new)
        }
    }

    // MARK: Expand in place (list view)

    func toggleExpanded(_ entry: Entry) { setExpanded(entry, !expanded.contains(entry.id)) }

    func setExpanded(_ entry: Entry, _ open: Bool) {
        guard entry.isDirectory else { return }
        if open {
            children[entry.id] = (try? FileOps.listDirectory(entry.url, showHidden: showHidden)) ?? []
            expanded.insert(entry.id)
        } else {
            expanded.remove(entry.id)
            children[entry.id] = nil
        }
    }

    /// → / ← in the list: open or close the selected folders.
    func expandSelection(_ open: Bool) {
        for row in rows where selection.contains(row.id) { setExpanded(row.entry, open) }
    }

    // MARK: Selection for the icon and column views (the list's Table does its own)

    func click(_ id: String, in order: [String], command: Bool, shift: Bool) {
        if shift, let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
            selection = Set(order[min(a, b)...max(a, b)])
        } else if command {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else {
            selection = [id]
            anchor = id
        }
        cursor = id
    }

    /// Arrow keys: move by `delta` items; with Shift, extend from the anchor.
    func move(by delta: Int, in order: [String], extend: Bool) {
        guard !order.isEmpty else { return }
        let start: Int = cursor.flatMap { (c: String) -> Int? in order.firstIndex(of: c) } ?? (delta > 0 ? -1 : order.count)
        let target: String = order[min(max(start + delta, 0), order.count - 1)]
        if extend, let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: target) {
            selection = Set(order[min(a, b)...max(a, b)])
        } else {
            selection = [target]
            anchor = target
        }
        cursor = target
    }

    func selectAll() {
        if view == .columns {
            selection = Set(columnEntries(columnDirs.count - 1).map { (e: Entry) -> String in e.id })
        } else {
            selection = Set(rows.map { (r: Row) -> String in r.id })
        }
    }

    // MARK: Column view (F3.1)

    var columnDirs: [URL] { [url] + trail }

    func columnEntries(_ index: Int) -> [Entry] {
        if index == 0 { return visibleEntries }
        guard index < columnDirs.count else { return [] }
        // shortcut: deeper columns are listed per render; cache if columns of huge folders get slow
        let list: [Entry] = (try? FileOps.listDirectory(columnDirs[index], showHidden: showHidden)) ?? []
        return Arrange.sorted(list, prefs)
    }

    /// Clicking in column `index`: a folder opens the next column, a file closes deeper ones.
    func columnClick(_ entry: Entry, column index: Int, command: Bool = false, shift: Bool = false) {
        let order: [String] = columnEntries(index).map { (e: Entry) -> String in e.id }
        click(entry.id, in: order, command: command, shift: shift)
        trail = Array(trail.prefix(index))
        if selection.count == 1, entry.isDirectory { trail.append(FileOps.canonical(entry.url)) }
    }

    /// The column holding the current selection (the cursor's column).
    var selectedColumn: Int? {
        guard let id = cursor ?? selection.first else { return nil }
        let parent: URL = FileOps.canonical(URL(fileURLWithPath: id).deletingLastPathComponent())
        return columnDirs.firstIndex(of: parent)
    }

    func columnMove(by delta: Int, extend: Bool) {
        let index: Int = selectedColumn ?? 0
        let list: [Entry] = columnEntries(index)
        move(by: delta, in: list.map { (e: Entry) -> String in e.id }, extend: extend)
        trail = Array(trail.prefix(index))
        if selection.count == 1, let id = selection.first, let entry = list.first(where: { (e: Entry) -> Bool in e.id == id }),
           entry.isDirectory {
            trail.append(FileOps.canonical(entry.url))
        }
    }

    /// →: step into the open folder's column. ←: step back to the folder.
    func columnStep(into: Bool) {
        guard let index = selectedColumn else { return }
        if into {
            guard index + 1 < columnDirs.count, let first = columnEntries(index + 1).first else { return }
            columnClick(first, column: index + 1)
        } else if index > 0 {
            let folder: URL = columnDirs[index]
            let siblings: [Entry] = columnEntries(index - 1)
            guard let entry = siblings.first(where: { (e: Entry) -> Bool in e.id == folder.path }) else { return }
            columnClick(entry, column: index - 1)
        }
    }

    /// The single selected file shown as the last column (F3.1).
    var columnPreview: URL? {
        guard view == .columns, selection.count == 1, let id = selection.first else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: id, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return URL(fileURLWithPath: id)
    }
}
