import AppKit
import Quartz
import Observation
import UniformTypeIdentifiers
import FileOSCore

/// What Peek shows for the current item; worked out off the main actor.
enum PeekContent: Sendable, Equatable {
    case loading
    /// QLPreviewView: PDFs, images, Office/iWork and anything else Quick Look knows.
    case quickLook
    /// AVPlayerView: audio and video, playing.
    case media
    case text(String)
    case zip(entries: [String], encrypted: Bool)
    case folder(items: Int, bytes: Int64)
    /// "Still downloading" / "In iCloud only" / why a zip can't be listed.
    case notice(String)
}

/// Space (F6.1): an overlay over the window that steps through items with ← →.
@MainActor @Observable
final class PeekModel {
    private(set) var urls: [URL] = []
    private(set) var index = 0
    private(set) var content: PeekContent = .loading
    private(set) var info: FileInfoSummary?
    /// The Info drawer, remembered across launches.
    private(set) var showInfo: Bool
    @ObservationIgnored private(set) var loading: Task<Void, Never>?
    @ObservationIgnored private let store: Store

    /// Peek shows at most this much text; larger files go to Quick Look.
    nonisolated static let maxTextBytes = 512 * 1024

    init(store: Store) {
        self.store = store
        showInfo = store.get("peek.info", default: false)
    }

    func toggleInfo() {
        showInfo.toggle()
        store.set("peek.info", showInfo)
    }

    var isShown: Bool { !urls.isEmpty }
    var current: URL? { urls.indices.contains(index) ? urls[index] : nil }
    /// "7 of 10".
    var position: String { "\(index + 1) of \(urls.count)" }

    func show(_ list: [URL], at start: Int = 0) {
        guard !list.isEmpty else { return }
        urls = list
        index = min(max(start, 0), list.count - 1)
        load()
    }

    /// ← →: stops at the ends.
    func step(_ delta: Int) {
        let next: Int = index + delta
        guard urls.indices.contains(next) else { return }
        index = next
        load()
    }

    func close() {
        loading?.cancel()
        urls = []
        index = 0
        content = .loading
        info = nil
    }

    /// Re-reads the current item (after an unpack, for instance).
    func reload() { load() }

    private func load() {
        loading?.cancel()
        guard let url = current else { return }
        content = .loading
        info = nil
        loading = Task {
            let found: PeekContent = await Self.content(of: url)
            let summary: FileInfoSummary = await Self.summary(of: url)
            guard !Task.isCancelled, current == url else { return }
            content = found
            info = summary
        }
    }

    nonisolated static func summary(of url: URL) async -> FileInfoSummary { FileInfo.summary(url) }

    /// Reads only regular files, and only up to the caps; links, FIFOs and devices are never opened.
    nonisolated static func content(of url: URL) async -> PeekContent {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .ubiquitousItemDownloadingStatusKey]
        let values: URLResourceValues? = try? url.resourceValues(forKeys: keys)
        if values?.isDirectory == true && values?.isPackage != true {
            let total: (bytes: Int64, items: Int) = FileOps.directorySize(url)
            return .folder(items: total.items, bytes: total.bytes)
        }
        if isDownloading(url.lastPathComponent) { return .notice("Still downloading") }
        if values?.ubiquitousItemDownloadingStatus == .notDownloaded { return .notice("In iCloud only") }
        let type: UTType? = UTType(filenameExtension: url.pathExtension)
        if url.pathExtension.lowercased() == "zip" {
            do {
                let list: [ZipEntry] = try ZipReader.listing(url)
                return .zip(entries: list.map { (e: ZipEntry) -> String in e.name },
                            encrypted: list.contains { (e: ZipEntry) -> Bool in e.encrypted })
            } catch {
                return .notice(error.localizedDescription)
            }
        }
        // shortcut: .7z, .rar and .tar.gz show Quick Look's view; list them when a reader exists (F5.14)
        if type?.conforms(to: .audiovisualContent) == true { return .media }
        if type?.conforms(to: .text) == true, type?.conforms(to: .rtf) != true, type?.conforms(to: .html) != true,
           let text = FileInfo.text(url, limit: maxTextBytes) {
            return .text(text)
        }
        return .quickLook
    }
}

/// ⌘Y: the system Quick Look panel (F6.1).
@MainActor
enum QuickLook {
    private static var source: QuickLookSource?

    static func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        let src = QuickLookSource(urls: urls)
        source = src
        panel.dataSource = src
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
}

final class QuickLookSource: NSObject, QLPreviewPanelDataSource {
    let urls: [URL]
    init(urls: [URL]) { self.urls = urls }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}

// MARK: - Peek actions (F6.1, F5.14)

extension AppModel {
    /// Space / F3: several selected items step through just those; one steps through its folder's items.
    func peekSelection() {
        let selected: [URL] = targets
        guard let first = selected.first else { return }
        if selected.count > 1 {
            peek.show(selected)
            return
        }
        let parent: String = first.deletingLastPathComponent().path
        let siblings: [URL] = pane.shownIDs.map { (p: String) -> URL in URL(fileURLWithPath: p) }
            .filter { (u: URL) -> Bool in u.deletingLastPathComponent().path == parent }
        let start: Int = siblings.firstIndex(of: first) ?? 0
        peek.show(siblings.isEmpty ? [first] : siblings, at: start)
    }

    /// ← → in Peek; a single selection follows along so closing leaves the last item selected.
    func peekStep(_ delta: Int) {
        peek.step(delta)
        guard let url = peek.current, pane.selection.count <= 1, pane.shownIDs.contains(url.path) else { return }
        pane.selection = [url.path]
    }

    /// Return in Peek.
    func peekOpen() {
        guard let url = peek.current else { return }
        peek.close()
        showSearch = false
        openItem(url)
    }

    /// ⌘Y: Peek's item, ⌘K's selected hit, or the selection.
    func quickLook() {
        if let url = peek.current { return QuickLook.show([url]) }
        if showSearch, case .hit(let h) = search.selectedRow { return QuickLook.show([h.url]) }
        QuickLook.show(targets)
    }

    /// Keys while Peek is up, seen by the window's key monitor before any list or field.
    func handlePeekKey(_ event: NSEvent) -> Bool {
        let mods: NSEvent.ModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case 123: peekStep(-1) // ←
        case 124: peekStep(1) // →
        case 36, 76: peekOpen() // Return, Enter
        case 49, 53: peek.close() // Space, Esc
        default: return false
        }
        return true
    }

    /// Unpacks next to the zip into a new folder ("a 2" if "a" exists); undo sends that folder to the Trash.
    /// Zips with absolute or ".." names or links are refused by `ZipReader.unzip` before anything is written.
    func unpack(_ zip: URL) async {
        let dir: URL = zip.deletingLastPathComponent()
        let dest: URL = dir.appendingPathComponent(FileOps.uniqueName(in: dir, for: splitExtension(zip.lastPathComponent).base))
        do {
            try await ZipReader.unzip(zip, to: dest)
        } catch {
            // A half-unpacked folder goes to the Trash rather than staying behind.
            if FileManager.default.fileExists(atPath: dest.path) { _ = try? FileOps.trash([dest], trashDir: trashDir) }
            toast("Couldn't unpack “\(zip.lastPathComponent)”: \(error.localizedDescription)", undoable: false)
            return
        }
        undoByTrashing("Unpack", [dest])
        reloadAll()
        toast("Unpacked “\(zip.lastPathComponent)” into “\(dest.lastPathComponent)”", undoable: true)
    }

    /// Password-protected zips (F5.14).
    func openInArchiveUtility(_ zip: URL) {
        let app = URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Archive Utility.app")
        NSWorkspace.shared.open([zip], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(),
                                completionHandler: nil)
    }
}
