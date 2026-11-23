import AppKit
import SystemConfiguration
import Observation
import UniformTypeIdentifiers
import FileOSCore

enum Page: Hashable {
    case browser, home, bookmarks, freeUpSpace, installed, agents, workspace(UUID), aboutMac

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
    var panes: [PaneModel]
    var activePane = 0
    private(set) var showHidden: Bool
    var page: Page = .browser
    private(set) var toasts: [Toast] = []

    /// Path bar edit mode (⌘L / ⇧⌘G) and the last "no folder called …" result.
    var editingPath = false
    var pathError: (name: String, parent: URL, suggestion: String?)?

    // Sidebar
    private(set) var favorites: [URL]
    private(set) var volumes: [URL] = []
    private(set) var collapsedSections: Set<String>
    var locationsExpanded = false // F2.1: Locations always starts folded
    /// The Mac's sharing name, read from the local configuration store (no network lookup, unlike Host).
    var macName: String { (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac" }

    static var defaultHome: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["FILEOS_HOME"] ?? NSHomeDirectory())
    }

    init(home: URL) {
        self.home = FileOps.canonical(home)
        store = Store(url: home.appendingPathComponent("Library/Application Support/FileOS/state.json"))
        let hidden = store.get("showHidden", default: false)
        showHidden = hidden
        favorites = store.get("favorites", default: [String]()).map { (p: String) -> URL in FileOps.canonical(URL(fileURLWithPath: p)) }
        collapsedSections = Set(store.get("sidebar.collapsed", default: [String]()))
        panes = [PaneModel(url: home, showHidden: hidden)]
        refreshVolumes()
    }

    var pane: PaneModel { panes[activePane] }

    var standardFavorites: [URL] {
        ["Desktop", "Documents", "Downloads", "Pictures"].map { (name: String) -> URL in
            FileOps.canonical(home.appendingPathComponent(name))
        }
    }

    var trashURL: URL { FileOps.canonical(home.appendingPathComponent(".Trash")) }

    // MARK: Navigation

    func open(_ url: URL) {
        page = .browser
        pathError = nil
        pane.navigate(to: url)
    }

    /// ⌘↓ / double-click: folders open in place, files open in their default app.
    func openSelection(_ ids: Set<Entry.ID>? = nil) {
        let ids = ids ?? pane.selection
        let chosen = pane.entries.filter { ids.contains($0.id) }
        if chosen.count == 1, let folder = chosen.first, folder.isDirectory {
            pane.navigate(to: folder.url)
            return
        }
        for entry in chosen { _ = NSWorkspace.shared.open(entry.url) }
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
        undo.push("New Folder") {
            // Undo goes through the Trash, so anything put in the folder since is still recoverable.
            do { _ = try FileOps.trash([url], trashDir: nil); return RestoreResult(restored: [url]) }
            catch { return RestoreResult(failed: [(url, error.localizedDescription)]) }
        }
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
        Task {
            guard let result = await undo.undo()?.result else { return }
            for p in panes { p.reload() }
            if !result.failed.isEmpty { toast(Self.restoreFailureText(result), undoable: false) }
        }
    }
}
