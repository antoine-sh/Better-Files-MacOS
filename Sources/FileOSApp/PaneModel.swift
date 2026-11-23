import Foundation
import Observation
import FileOSCore

enum ViewMode: String, Codable, CaseIterable { case list, icons, columns }
enum Grouping: String, Codable, CaseIterable { case none, kind, date }

extension Entry {
    /// "Folder" or the system's description of the type ("PDF document"), for the Kind column.
    var kindName: String { isDirectory ? "Folder" : kindDescription(name) }
}

@MainActor @Observable
final class PaneModel {
    private(set) var url: URL
    private(set) var entries: [Entry] = []
    var selection: Set<Entry.ID> = []
    var view: ViewMode = .list
    var sort: [KeyPathComparator<Entry>] = [KeyPathComparator(\Entry.name, comparator: String.StandardComparator.localizedStandard)]
    var group: Grouping = .none
    var filter = ""
    private(set) var error: FileOSError?
    private(set) var freeSpace: Int64 = 0
    private(set) var history: [URL] = []
    private(set) var forwardStack: [URL] = []
    var showHidden: Bool

    private let watcher = DirectoryWatcher()
    @ObservationIgnored private var reloadPending = false

    init(url: URL, showHidden: Bool = false) {
        self.url = FileOps.canonical(url)
        self.showHidden = showHidden
        reload()
    }

    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { url.path != "/" }

    /// Entries after the filter and the column sort.
    // shortcut: recomputed per render; cache it if huge folders get slow
    var visibleEntries: [Entry] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let shown = needle.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        return shown.sorted(using: sort)
    }

    var selectedEntries: [Entry] { entries.filter { selection.contains($0.id) } }

    /// Selected items the filter still shows, for the status bar.
    var visibleSelectionCount: Int {
        var n = 0
        for entry in visibleEntries where selection.contains(entry.id) { n += 1 }
        return n
    }

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
        let ids = Set(entries.map(\.id))
        selection.formIntersection(ids)
        freeSpace = FileOps.diskInfo(for: url).free
    }

    private func show(_ target: URL, select: URL?) {
        url = target
        filter = ""
        selection = select.map { (u: URL) -> Set<String> in [FileOps.canonical(u).path] } ?? []
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
}
