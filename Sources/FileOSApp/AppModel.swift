import AppKit
import SystemConfiguration
import Observation
import UniformTypeIdentifiers
import FileOSCore

enum Page: Hashable, Sendable {
    case browser, home, bookmarks, freeUpSpace, installed, agents, workspace(UUID), aboutMac
    /// The Markdown page for `AppModel.markdown` (F6.3).
    case markdown

    var title: String {
        switch self {
        case .browser: return "Files"
        case .home: return "Home"
        case .bookmarks: return "Bookmarks"
        case .freeUpSpace: return "Free Up Space"
        case .installed: return "Installed"
        case .agents: return "AI Agents"
        case .workspace: return "Workspace"
        case .aboutMac: return "About This Mac"
        case .markdown: return "Markdown"
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let undoable: Bool
}

func kindDescription(_ name: String) -> String {
    let ext = (name as NSString).pathExtension
    if ext.isEmpty { return "Document" }
    return UTType(filenameExtension: ext)?.localizedDescription ?? "\(ext.uppercased()) file"
}

@MainActor @Observable
final class AppModel {
    let home: URL
    let store: Store
    let undo = UndoStack()
    /// nil: the system Trash. Set for the self-test so nothing lands in the real Trash.
    let trashDir: URL?
    /// Action id → shortcut, with the user's overrides (F17 Settings > Shortcuts writes "shortcuts").
    let shortcuts: [String: KeyCombo]
    private(set) var iconSize: IconSize
    private(set) var showPreview: Bool
    var filterShown = false
    private(set) var clipboard: Clipboard?
    /// Copies and moves, one at a time, with progress and the clash sheet (F5.4, F5.5).
    let transfers: TransferQueue
    /// ⌘K (F7).
    let search: SearchModel
    var showSearch = false
    /// Space (F6.1).
    let peek: PeekModel
    /// The open Markdown page, and where the user was going when "Save the changes…?" was asked.
    var markdown: MarkdownDocument?
    var leavingTo: Page?
    var showLeaveAlert = false
    var showSaveLayout = false

    // Dialogs (see FileDialogs)
    var extensionPrompt: ExtensionPrompt?
    var showExtensionAlert = false
    var showEmptyTrashAlert = false
    private(set) var emptyTrashSummary: (count: Int, bytes: Int64) = (0, 0)
    var showBatchRename = false
    private(set) var batchRenameTargets: [URL] = []
    /// ⌥⌘T (F9.4).
    var tidy: TidyState?
    var showTidy = false
    /// ⌥⌘I (F3.12): takes the preview pane's place.
    private(set) var showInsights: Bool
    /// Free Up Space (F10).
    let clean: CleanModel
    /// F14.3 Installed and F14.4 AI Agents.
    let installed = InstalledModel()
    let agents = AgentsModel()
    /// Every shell-out (git, brew, lsof …) goes through this; the self-test swaps in canned answers.
    @ObservationIgnored var runner: any CommandRunner = ProcessRunner()
    /// F14.2 Choose Defaults…
    var showOpenInDefaults = false
    @ObservationIgnored private var installedOpenIn: [ExternalApp]?
    /// F13: chosen symbols and colours by canonical folder path, and the automatic symbols worked out so far
    /// (keyed by path and modification date, so a changed folder is looked at again).
    var symbolOverrides: [String: String]
    var colorOverrides: [String: String]
    var autoSymbols: [String: String] = [:]
    var symbolTargets: [URL] = []
    /// App names in the Applications folders, for the Insights suggestions; nil until first loaded.
    var installedAppNames: Set<String>?
    /// Where Free Up Space looks for apps; nil is the real Applications folders (the self-test narrows it).
    var cleanApplications: [URL]?
    var showSymbolChooser = false
    /// The layout's panes (1–4, F8.3); menus and keys act on `pane`, the active one.
    var panes: [PaneModel]
    var activePane = 0
    private(set) var layout: PaneLayout = .one
    private(set) var savedLayouts: [SavedLayout]
    @ObservationIgnored var paneKeyMonitor: Any?
    private(set) var showHidden: Bool
    var page: Page = .browser
    private(set) var toasts: [Toast] = []

    // Workspaces (F11) and Bookmarks (F12); only `setWorkspaces` / `setBookmarks` write the lists.
    var workspaces: [Workspace]
    var bookmarkState: BookmarkState
    var bookmarkPlace: BookmarkPlace = .all
    var workspaceDraft = WorkspaceDraft()
    var showWorkspaceSheet = false
    var workspaceToDelete: UUID?
    var showDeleteWorkspace = false
    var showAddLink = false
    var showNewCollection = false
    var collectionToDelete: UUID?
    var showDeleteCollection = false
    /// Off for the self-test: CI must not depend on the network.
    var fetchesLinkMeta = true
    /// What each link's page said, so undoing to an older snapshot doesn't lose it.
    @ObservationIgnored var fetchedMeta: [UUID: FetchedMeta] = [:]

    /// Path bar edit mode (⌘L / ⇧⌘G) and the last "no folder called …" result.
    var editingPath = false
    var pathError: (name: String, parent: URL, suggestion: String?)?

    // Sidebar
    private(set) var favorites: [URL]
    private(set) var volumes: [URL] = []
    private(set) var collapsedSections: Set<String>
    /// The Mac's sharing name, read from the local configuration store (no network lookup, unlike Host).
    var macName: String { (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac" }

    static var defaultHome: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["FILEOS_HOME"] ?? NSHomeDirectory())
    }

    init(home: URL, trashDir: URL? = nil) {
        self.home = FileOps.canonical(home)
        self.trashDir = trashDir
        transfers = TransferQueue(trashDir: trashDir)
        search = SearchModel()
        clean = CleanModel()
        let store = Store(url: home.appendingPathComponent("Library/Application Support/FileOS/state.json"))
        self.store = store
        peek = PeekModel(store: store)
        let hidden = store.get("showHidden", default: false)
        showHidden = hidden
        favorites = store.get("favorites", default: [String]()).map { (p: String) -> URL in FileOps.canonical(URL(fileURLWithPath: p)) }
        collapsedSections = Set(store.get("sidebar.collapsed", default: [String]()))
        shortcuts = Shortcuts.merged(store.get("shortcuts", default: [String: KeyCombo]()))
        iconSize = store.get("view.size", default: IconSize.medium)
        showPreview = store.get("view.preview", default: false)
        showInsights = store.get("view.insights", default: false)
        symbolOverrides = store.get(Self.symbolsKey, default: [String: String]())
        colorOverrides = store.get(Self.colorsKey, default: [String: String]())
        savedLayouts = store.get("layouts", default: [SavedLayout]())
        // Element by element, so one damaged entry can't cost the rest. The sample "Acme Project" (F11.5) is
        // seeded only when nothing was ever saved; an empty saved list stays empty.
        let savedWorkspaces: [Workspace]? = store.getArray("workspaces", of: Workspace.self)
        let initialWorkspaces: [Workspace] = savedWorkspaces ?? [Workspaces.sample(home: FileOps.canonical(home))]
        workspaces = initialWorkspaces
        if savedWorkspaces == nil { store.setArray("workspaces", initialWorkspaces) }
        bookmarkState = BookmarkState(bookmarks: store.getArray("bookmarks", of: Bookmark.self) ?? [],
                                      collections: store.getArray("bookmarkCollections", of: BookmarkCollection.self) ?? [])
        let pane = PaneModel(url: home, showHidden: hidden, store: store, downloads: home.appendingPathComponent("Downloads"))
        pane.view = store.get("view.mode", default: ViewMode.list)
        panes = [pane]
        refreshVolumes()
        // A clash question must be answerable: close ⌘K so the sheet can show.
        transfers.willAsk = { [weak self] in
            self?.showSearch = false
            self?.peek.close()
        }
    }

    var pane: PaneModel { panes[activePane] }

    var standardFavorites: [URL] {
        ["Desktop", "Documents", "Downloads", "Pictures"].map { (name: String) -> URL in
            FileOps.canonical(home.appendingPathComponent(name))
        }
    }

    var trashURL: URL { FileOps.canonical(trashDir ?? home.appendingPathComponent(".Trash")) }

    // MARK: Navigation

    func open(_ url: URL) {
        page = .browser
        pathError = nil
        pane.navigate(to: url)
    }

    /// ⌘↓ / double-click: folders open in place, Markdown as a page, files in their default app.
    func openSelection(_ ids: Set<Entry.ID>? = nil) {
        let urls: [URL] = (ids ?? pane.selection).sorted().map { (p: String) -> URL in URL(fileURLWithPath: p) }
        if urls.count == 1, let only = urls.first { return openItem(only) }
        for url in urls { _ = NSWorkspace.shared.open(url) }
    }

    /// A folder, but not a package such as an .app (those open instead).
    nonisolated static func isBrowsableFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    func displayName(_ url: URL) -> String {
        if url.path == "/" {
            return (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "/"
        }
        return url.lastPathComponent
    }

    func toggleHidden() {
        showHidden.toggle()
        store.set("showHidden", showHidden)
        for p in panes { p.showHidden = showHidden; p.reload() }
    }

    // MARK: Path bar

    func displayPath(_ url: URL) -> String { PathBar.display(url.path, home: home) }

    /// Runs what was typed in the path bar. Returns false (and sets `pathError`) when no such folder exists.
    @discardableResult
    func go(_ text: String) -> Bool {
        pathError = nil
        switch PathBar.parse(text, cwd: pane.url, home: home) {
        case let .command(appID, target):
            openIn(appID: appID, target: target)
            return true
        case .path(let raw):
            switch PathBar.resolve(raw, cwd: pane.url, home: home) {
            case .folder(let url): open(url)
            case let .file(url, dir):
                page = .browser
                pane.navigate(to: dir, select: url)
            case let .missing(name, parent, suggestion):
                pathError = (name, parent, suggestion)
                return false
            }
            return true
        }
    }

    /// "Create This Folder": makes the missing folder (and parents), opens it, and is undoable.
    func createMissingFolder() {
        guard let missing = pathError else { return }
        let url = missing.parent.appendingPathComponent(missing.name)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            toast("Couldn't create “\(missing.name)”: \(error.localizedDescription)", undoable: false)
            return
        }
        undoByTrashing("New Folder", [url])
        open(url) // also clears pathError
        editingPath = false
        toast("Created “\(missing.name)”", undoable: true)
    }

    /// Path-bar command words (F4.4): open an installed app on the target; never runs a shell command.
    func openIn(appID: String, target: URL) {
        guard let app = OpenIn.apps.first(where: { $0.id == appID }) else { return }
        guard let appURL = Self.applicationURL(named: app.bundleName) else {
            toast("\(app.name) isn't installed", undoable: false)
            return
        }
        NSWorkspace.shared.open([target], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration(),
                                completionHandler: nil)
    }

    static func applicationURL(named name: String) -> URL? {
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent(name + ".app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Sidebar

    func refreshVolumes() {
        // shortcut: read at launch and on demand; listen to NSWorkspace mount notifications with eject (F2.6)
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        volumes = urls.filter { $0.path != "/" }.map(FileOps.canonical)
    }

    func isExpanded(_ section: String) -> Bool { !collapsedSections.contains(section) }

    func setExpanded(_ section: String, _ expanded: Bool) {
        if expanded { collapsedSections.remove(section) } else { collapsedSections.insert(section) }
        store.set("sidebar.collapsed", collapsedSections.sorted())
    }

    // MARK: Toasts and undo

    func toast(_ text: String, undoable: Bool) {
        let toast = Toast(text: text, undoable: undoable)
        toasts.append(toast)
        Task {
            try? await Task.sleep(for: .seconds(5))
            toasts.removeAll { $0.id == toast.id }
        }
    }

    func dismiss(_ toast: Toast) { toasts.removeAll { $0.id == toast.id } }

    static func restoreFailureText(_ result: RestoreResult) -> String {
        var names: [String] = []
        for failure in result.failed {
            let name: String = failure.url.lastPathComponent
            names.append("“\(name)” (\(failure.reason))")
        }
        let count: Int = result.failed.count
        let items: String = count == 1 ? "1 item" : "\(count) items"
        let list: String = names.joined(separator: ", ")
        return "Couldn't restore \(items): \(list)"
    }

    func performUndo() {
        Task { await undoLast() }
    }

    func undoLast() async {
        guard let result = await undo.undo()?.result else { return }
        reloadAll()
        if !result.failed.isEmpty { toast(Self.restoreFailureText(result), undoable: false) }
    }

    func reloadAll() { for p in panes { p.reload() } }

    static func items(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }
}

/// A name clash waiting for the user's answer (F5.4). Answered exactly once, by `answerClash`.
struct ClashPrompt: Identifiable {
    let id = UUID()
    let clash: Clash
    let continuation: CheckedContinuation<(ClashChoice, Bool), Never>
}

/// A rename that changes the extension, waiting for "Keep .pdf" / "Use .docx" (F5.6).
struct ExtensionPrompt {
    let url: URL
    let newName: String
    let from: String
    let to: String
}

// MARK: - Layout state (F8.3): the only writers of `layout` and `savedLayouts`.

extension AppModel {
    func setLayout(_ new: PaneLayout) {
        page = .browser
        let from: PaneModel = pane
        if activePane >= new.paneCount { // keep the pane the user is in
            panes.swapAt(0, activePane)
            activePane = 0
        }
        if panes.count > new.paneCount { panes.removeLast(panes.count - new.paneCount) }
        while panes.count < new.paneCount {
            let added = PaneModel(url: from.url, showHidden: showHidden, store: store, downloads: home.appendingPathComponent("Downloads"))
            added.view = from.view
            panes.append(added)
        }
        layout = new
        editingPath = false
    }

    func setSavedLayouts(_ list: [SavedLayout]) {
        savedLayouts = list
        store.set("layouts", list)
    }
}

// MARK: - File operations (F5). Every change goes through FileOSCore, registers an undo and shows a toast.

extension AppModel {
    /// The selected items that are on screen, or nothing.
    var targets: [URL] { pane.visibleSelectedURLs }

    /// Undo for something we created: send it to the Trash, so anything put in it since stays recoverable.
    func undoByTrashing(_ label: String, _ urls: [URL]) {
        let trashDir: URL? = self.trashDir
        undo.push(label) {
            var result = RestoreResult()
            for url in urls {
                do {
                    _ = try FileOps.trash([url], trashDir: trashDir)
                    result.restored.append(url)
                } catch {
                    result.failed.append((url, error.localizedDescription))
                }
            }
            return result
        }
    }

    private func fail(_ error: Error) { toast(error.localizedDescription, undoable: false) }

    private func select(_ urls: [URL]) {
        pane.selection = Set(urls.map { (u: URL) -> String in u.path })
    }

    /// ⇧⌘N / F7: "untitled folder", then rename it (F5.8).
    func newFolder() {
        page = .browser
        do {
            let url: URL = try FileOps.newFolder(in: pane.currentFolder)
            undoByTrashing("New Folder", [url])
            reloadAll()
            select([url])
            pane.renaming = url.path
            pane.renamingInPreview = false
            toast("Created “\(url.lastPathComponent)”", undoable: true)
        } catch {
            fail(error)
        }
    }

    /// ⌘⌫ / F8 (F5.9).
    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        do {
            let moves: [Move] = try FileOps.trash(urls, trashDir: trashDir)
            undo.push("Move to Trash") { FileOps.restore(moves) }
            reloadAll()
            toast("Moved \(Self.items(moves.count)) to the Trash", undoable: true)
        } catch {
            // shortcut: no "Move with Finder" fallback yet; add it when Finder automation is allowed
            toast("Couldn't move to the Trash: \(error.localizedDescription)", undoable: false)
        }
    }

    /// F5.2: "report copy.pdf".
    func duplicate(_ urls: [URL]) {
        made(urls, label: "Duplicate", verb: "Duplicated") { (u: URL) throws -> URL in try FileOps.duplicate(u) }
    }

    /// ⌃⌘A (F5.2).
    func makeAlias(_ urls: [URL]) {
        made(urls, label: "Make Alias", verb: "Made aliases of") { (u: URL) throws -> URL in try FileOps.makeAlias(u) }
    }

    private func made(_ urls: [URL], label: String, verb: String, _ make: (URL) throws -> URL) {
        var made: [URL] = []
        for url in urls {
            do { made.append(try make(url)) } catch { fail(error); break }
        }
        guard !made.isEmpty else { return }
        undoByTrashing(label, made)
        reloadAll()
        select(made)
        toast("\(verb) \(Self.items(made.count))", undoable: true)
    }

    // MARK: Clipboard (F5.1)

    func copy(_ urls: [URL], cut: Bool = false) {
        guard !urls.isEmpty else { return }
        let count: Int = Pasteboard.write(urls)
        clipboard = Clipboard(urls: urls, cut: cut, changeCount: count)
    }

    /// Esc: the cut items stop being dimmed and won't move on paste.
    func cancelCut() {
        if clipboard?.cut == true { clipboard?.cut = false }
    }

    func isCut(_ id: String) -> Bool {
        guard let clipboard, clipboard.cut, clipboard.changeCount == Pasteboard.changeCount else { return false }
        return clipboard.urls.contains { (u: URL) -> Bool in u.path == id }
    }

    /// ⌘V copies (or moves what was cut); ⌥⌘V moves (F5.1). Files copied in other apps paste too.
    func paste(into folder: URL? = nil, move forceMove: Bool = false) async {
        let dest: URL = folder ?? pane.currentFolder
        var sources: [URL]
        var mode: TransferMode = .copy
        if let clipboard, clipboard.changeCount == Pasteboard.changeCount {
            sources = clipboard.urls
            if clipboard.cut { mode = .move }
        } else {
            sources = Pasteboard.fileURLs()
        }
        if forceMove { mode = .move }
        guard !sources.isEmpty else { return }
        let finished: Bool = await runTransfer(sources, to: dest, mode: mode)
        guard mode == .move else { return }
        // Moved items are gone from where the pasteboard points; keep only what is still there.
        let left: [URL] = sources.filter { (u: URL) -> Bool in FileManager.default.fileExists(atPath: u.path) }
        if finished || left.isEmpty {
            Pasteboard.clear()
            clipboard = nil
        } else {
            copy(left, cut: clipboard?.cut ?? false)
        }
    }

    /// F5.3: same disk moves, another disk copies, ⌥ always copies. F8.2: from a pane always moves.
    func drop(_ urls: [URL], into folder: URL) async {
        guard let first = urls.first else { return }
        let copy: Bool = NSEvent.modifierFlags.contains(.option)
            || (!isAcrossPanes(urls, to: folder) && !Self.sameVolume(first, folder))
        _ = await runTransfer(urls, to: folder, mode: copy ? .copy : .move)
    }

    /// The pane showing `folder` (in any of its columns), if any.
    func paneIndex(showing folder: URL) -> Int? {
        let f: URL = FileOps.canonical(folder)
        return panes.firstIndex { (p: PaneModel) -> Bool in p.columnDirs.contains(f) }
    }

    /// F8.2: the items come from one pane and land in a folder shown in a different pane.
    func isAcrossPanes(_ urls: [URL], to folder: URL) -> Bool {
        guard let first = urls.first, let to = paneIndex(showing: folder),
              let from = paneIndex(showing: first.deletingLastPathComponent()), from != to else { return false }
        return urls.allSatisfy { (u: URL) -> Bool in paneIndex(showing: u.deletingLastPathComponent()) == from }
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let x = (try? a.resourceValues(forKeys: key))?.volumeIdentifier as? NSObject,
              let y = (try? b.resourceValues(forKeys: key))?.volumeIdentifier as? NSObject else { return false } // unknown: copy, never move
        return x.isEqual(y)
    }

    /// Queues one transfer behind any earlier one, asking about clashes; true when every item was handled.
    @discardableResult
    func runTransfer(_ sources: [URL], to dest: URL, mode: TransferMode) async -> Bool {
        guard let outcome = await transfers.run(sources, to: dest, mode: mode) else { return false } // cancelled while waiting
        reloadAll()
        switch outcome {
        case .failure(let error):
            fail(error)
            return false
        case .success(let result):
            let done: Int = result.results.count
            if done > 0 {
                undo.push(mode == .move ? "Move" : "Copy", result.undo)
                let verb: String = mode == .move ? "Moved" : "Copied"
                toast("\(verb) \(Self.items(done)) to “\(dest.lastPathComponent)”", undoable: true)
                let made: Set<String> = Set(result.results.map { (r: (from: URL, to: URL, action: TransferResult.Action)) -> String in r.to.path })
                // Only in the active pane: selecting in another pane would make it active (F5 twice must not copy back).
                if FileOps.canonical(dest) == pane.currentFolder || FileOps.canonical(dest) == pane.url {
                    pane.selection = made
                }
            }
            if let failure = result.failure { fail(failure) }
            return result.failure == nil && !result.stopped
        }
    }

    var clashPrompt: ClashPrompt? { transfers.clashPrompt }

    func answerClash(_ choice: ClashChoice, all: Bool) { transfers.answerClash(choice, all: all) }

    // MARK: Rename (F5.6, F5.7)

    /// Return / F2: one item renames inline, several open the batch sheet.
    func beginRename(_ urls: [URL]? = nil, inPreview: Bool = false) {
        let urls: [URL] = urls ?? targets
        if urls.count == 1, let url = urls.first {
            pane.renaming = url.path
            pane.renamingInPreview = inPreview
        } else if urls.count > 1 {
            batchRenameTargets = urls
            showBatchRename = true
        }
    }

    func cancelRename() { pane.renaming = nil }

    func commitRename(_ url: URL, to newName: String) {
        guard pane.renaming == url.path else { return } // already committed (Return, then focus loss)
        pane.renaming = nil
        let old: String = url.lastPathComponent
        guard newName != old else { return }
        if let problem = Rename.validate(newName) {
            toast(problem, undoable: false)
            return
        }
        // shortcut: only asks when both names have an extension; adding or removing one renames directly
        if let change = Rename.extensionChange(from: old, to: newName), !change.from.isEmpty, !change.to.isEmpty {
            extensionPrompt = ExtensionPrompt(url: url, newName: newName, from: change.from, to: change.to)
            showExtensionAlert = true
            return
        }
        performRename(url, to: newName)
    }

    func resolveExtension(keep: Bool) {
        guard let prompt = extensionPrompt else { return }
        extensionPrompt = nil
        let name: String = keep ? splitExtension(prompt.newName).base + prompt.from : prompt.newName
        performRename(prompt.url, to: name)
    }

    static func extensionTitle(_ p: ExtensionPrompt) -> String {
        "Are you sure you want to change the extension from “\(p.from)” to “\(p.to)”?"
    }

    func performRename(_ url: URL, to name: String) {
        do {
            let renamed: URL = try FileOps.rename(url, to: name)
            let oldName: String = url.lastPathComponent
            undo.push("Rename") {
                do {
                    _ = try FileOps.rename(renamed, to: oldName)
                    return RestoreResult(restored: [url])
                } catch {
                    return RestoreResult(failed: [(url, error.localizedDescription)])
                }
            }
            reloadAll()
            select([renamed])
            toast("Renamed “\(oldName)” to “\(renamed.lastPathComponent)”", undoable: true)
        } catch {
            fail(error)
        }
    }

    func applyBatchRename(_ rows: [Rename.BatchRow], in dir: URL) {
        let outcome = Rename.apply(rows, in: dir)
        if outcome.renamed > 0 {
            undo.push("Rename", outcome.undo)
            toast("Renamed \(Self.items(outcome.renamed))", undoable: true)
        }
        if let first = outcome.failed.first {
            toast("Couldn't rename “\(first.0)”: \(first.1)", undoable: false)
        }
        reloadAll()
    }

    // MARK: Trash (F5.10)

    func askEmptyTrash() {
        let summary: (count: Int, bytes: Int64) = FileOps.trashSummary(trashURL)
        guard summary.count > 0 else {
            toast("The Trash is empty", undoable: false)
            return
        }
        emptyTrashSummary = summary
        showEmptyTrashAlert = true
    }

    static func emptyTrashMessage(count: Int, bytes: Int64) -> String {
        "\(items(count)) (\(formatBytes(bytes))) will be deleted for good. This can't be undone."
    }

    /// Only ever called from the "Empty the Trash?" alert: the one permanent delete.
    func emptyTrash() {
        do {
            let done: (count: Int, bytes: Int64) = try FileOps.emptyTrash(trashURL)
            toast("Deleted \(Self.items(done.count)) for good", undoable: false)
        } catch {
            fail(error)
        }
        reloadAll()
    }

    // MARK: Misc (F5.13, F4)

    /// ⌥⌘C: the selected items' paths, one per line, or the folder's.
    func copyPath(_ urls: [URL]) {
        let list: [URL] = urls.isEmpty ? [pane.currentFolder] : urls
        Pasteboard.write(list.map { (u: URL) -> String in u.path }.joined(separator: "\n"))
        clipboard = nil
        toast(list.count == 1 ? "Copied the path of “\(list[0].lastPathComponent)”" : "Copied \(list.count) paths",
              undoable: false)
    }

    /// ⌘R.
    func showInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [pane.currentFolder] : urls)
    }

    /// ⌃⌘T: selected folders, or the open folder, join the sidebar's Favorites.
    func addToSidebar(_ urls: [URL]) {
        let folders: [URL] = (urls.isEmpty ? [pane.url] : urls.filter { (u: URL) -> Bool in Self.isBrowsableFolder(u) }).map { (u: URL) -> URL in FileOps.canonical(u) }
        let added: [URL] = folders.filter { (u: URL) -> Bool in !favorites.contains(u) && !standardFavorites.contains(u) }
        guard !added.isEmpty else { return }
        favorites += added
        store.set("favorites", favorites.map { (u: URL) -> String in u.path })
        undo.push("Add to Sidebar") {
            await self.removeFavorites(added)
            return RestoreResult(restored: added)
        }
        toast("Added \(Self.items(added.count)) to the sidebar", undoable: true)
    }

    func removeFavorites(_ urls: [URL]) {
        favorites.removeAll { (u: URL) -> Bool in urls.contains(u) }
        store.set("favorites", favorites.map { (u: URL) -> String in u.path })
    }

    func canAirDrop(_ urls: [URL]) -> Bool {
        !urls.isEmpty && !urls.contains { (u: URL) -> Bool in isDownloading(u.lastPathComponent) }
    }

    /// ⇧⌘R (F5.13).
    func airDrop(_ urls: [URL]) {
        guard canAirDrop(urls), let service = NSSharingService(named: .sendViaAirDrop) else { return }
        service.perform(withItems: urls)
    }

    /// ⌥⇧⌘T / ⌥⇧⌘E / F4: the default terminal or editor, on the selection or the folder.
    func openIn(kind: ExternalApp.Kind) {
        openIn(kind: kind, at: OpenIn.target(kind: kind, selection: targets, cwd: pane.currentFolder))
    }

    func openIn(kind: ExternalApp.Kind, at target: URL) {
        if let app = defaultApp(kind) {
            openIn(appID: app.id, target: target)
        } else if kind == .editor, let textEdit = Self.applicationURL(named: "TextEdit") {
            NSWorkspace.shared.open([target], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration(),
                                    completionHandler: nil)
        } else {
            toast("No \(kind == .terminal ? "terminal" : "editor") app is installed", undoable: false)
        }
    }

    /// The Open In apps found on this Mac, looked up once.
    var openInApps: [ExternalApp] {
        if let installedOpenIn { return installedOpenIn }
        let found: [ExternalApp] = OpenIn.apps.filter { (a: ExternalApp) -> Bool in Self.applicationURL(named: a.bundleName) != nil }
        installedOpenIn = found
        return found
    }

    static func defaultsKey(_ kind: ExternalApp.Kind) -> String { kind == .terminal ? "openIn.terminal" : "openIn.editor" }

    /// The chosen default if it is still installed, else the first installed app of that kind.
    func defaultApp(_ kind: ExternalApp.Kind) -> ExternalApp? {
        let apps: [ExternalApp] = openInApps.filter { (a: ExternalApp) -> Bool in a.kind == kind }
        let chosen: String = store.get(Self.defaultsKey(kind), default: "")
        return apps.first { (a: ExternalApp) -> Bool in a.id == chosen } ?? apps.first
    }

    func setDefaultApp(_ kind: ExternalApp.Kind, id: String) {
        store.set(Self.defaultsKey(kind), id)
    }

    /// Go menu places (F18).
    func goTo(_ place: String) {
        let url: URL
        switch place {
        case "Applications": url = URL(fileURLWithPath: "/Applications")
        case "iCloud Drive": url = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        case "Home": url = home
        default: url = home.appendingPathComponent(place)
        }
        open(url)
    }

    // MARK: View (F3.1–F3.4, F3.11)

    func setView(_ mode: ViewMode) {
        page = .browser
        pane.view = mode
        store.set("view.mode", mode)
    }

    func resize(by step: Int) {
        guard let size = IconSize(rawValue: iconSize.rawValue + step) else { return }
        iconSize = size
        store.set("view.size", size)
    }

    func togglePreview() {
        showPreview.toggle()
        store.set("view.preview", showPreview)
        if showPreview && showInsights { toggleInsights() }
    }

    /// ⌥⌘I: Insights and the preview pane share one place, so showing one hides the other.
    func toggleInsights() {
        showInsights.toggle()
        store.set("view.insights", showInsights)
        if showInsights && showPreview { togglePreview() }
    }

    func setGroup(_ grouping: Grouping) {
        var prefs: FolderPrefs = pane.prefs
        prefs.group = grouping
        pane.setPrefs(prefs)
    }

    /// Choosing the current key again flips the direction.
    func setSort(_ key: SortKey) {
        var prefs: FolderPrefs = pane.prefs
        if prefs.sortKey == key { prefs.ascending.toggle() } else { prefs.sortKey = key; prefs.ascending = true }
        pane.setPrefs(prefs)
    }

    func toggleFilesFirst() {
        var prefs: FolderPrefs = pane.prefs
        prefs.filesFirst.toggle()
        pane.setPrefs(prefs)
    }
}
