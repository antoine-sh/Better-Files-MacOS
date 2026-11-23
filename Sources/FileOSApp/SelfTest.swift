import SwiftUI
import AppKit
import FileOSCore

/// `FileOSApp --self-test`: a headless smoke run for CI. Prints one line per check, then
/// "SELFTEST PASS" or "SELFTEST FAIL". Later tasks append checks to `run`.
@MainActor
enum SelfTest {
    /// A model whose home is a fresh temp folder holding Documents/a.txt, so nothing real is touched.
    static func makeModel() -> AppModel {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fileos-selftest-\(UUID().uuidString)")
        let docs = home.appendingPathComponent("Documents")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try? "a".write(to: docs.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        return AppModel(home: home)
    }

    static func run(model: AppModel) async -> Bool {
        var ok = true
        func check(_ name: String, _ passed: Bool) {
            print("\(passed ? "ok  " : "FAIL") \(name)")
            if !passed { ok = false }
        }
        check("runs on the main thread", pthread_main_np() != 0)
        let fm = FileManager.default
        let home: URL = model.home
        let docs: URL = home.appendingPathComponent("Documents")
        let aTxt: URL = docs.appendingPathComponent("a.txt")
        let pane: PaneModel = model.pane

        pane.navigate(to: docs)
        let names: [String] = pane.entries.map { (e: Entry) -> String in e.name }
        check("lists Documents/a.txt", names == ["a.txt"])
        check("Documents has no error", pane.error == nil)
        check("Documents shows contents", FolderState(error: pane.error) == .contents)
        let status: String = StatusBar.text(items: 1, selected: 0, free: 0)
        check("status bar text", status == "1 item, 0 selected, 0 bytes available")

        let missing: URL = home.appendingPathComponent("Nope")
        pane.navigate(to: missing)
        check("missing folder sets notFound", pane.error == FileOSError.notFound(missing.path))
        check("missing folder has no entries", pane.entries.isEmpty)
        let missingState: FolderState = FolderState(error: pane.error)
        check("missing folder screen", missingState == .unavailable("“Nope” could not be found"))

        pane.back()
        check("back returns to Documents", pane.url == FileOps.canonical(docs))
        check("forward is available", pane.canGoForward)
        pane.forward()
        check("forward goes to the missing folder", pane.url == FileOps.canonical(missing))
        pane.navigate(to: docs)
        pane.up()
        check("up goes to the parent", pane.url == FileOps.canonical(home))
        check("up selects the folder it came from", pane.selection == Set([docs.path]))

        check("home is the sidebar's home row", pane.url == model.home)
        pane.navigate(to: docs)
        let depth: Int = pane.history.count
        pane.navigate(to: URL(fileURLWithPath: docs.path + "/"))
        check("same folder with a trailing slash adds no history", pane.history.count == depth)
        pane.navigate(to: URL(fileURLWithPath: home.path + "/x/../Documents"))
        check("same folder spelled with .. adds no history", pane.history.count == depth)

        let wentDocs: Bool = model.go("~/Documents")
        check("path bar opens ~/Documents", wentDocs)
        check("path bar is in Documents", pane.url == FileOps.canonical(docs))
        let wentFile: Bool = model.go("~/Documents/a.txt")
        check("path bar opens a file's folder", wentFile)
        check("path bar selects the file", pane.selection == Set([aTxt.path]))

        let wentTypo: Bool = model.go("~/Documnts")
        check("path bar reports a missing folder", !wentTypo)
        check("path bar suggests a near miss", model.pathError?.suggestion == "~/Documents")
        let expected: String = "There's no folder called “Documnts” in \(home.lastPathComponent)"
        var message: String = ""
        if let err = model.pathError { message = PathBar.missingMessage(name: err.name, parent: err.parent) }
        check("missing-folder message", message == expected)

        _ = model.go("~/New Stuff")
        model.createMissingFolder()
        let created: URL = home.appendingPathComponent("New Stuff")
        check("Create This Folder makes it", fm.fileExists(atPath: created.path))
        check("Create This Folder opens it", pane.url == FileOps.canonical(created))
        check("Create This Folder is undoable", model.undo.canUndo)
        check("Create This Folder shows an Undo toast", model.toasts.contains { (t: Toast) -> Bool in t.undoable })

        pane.filter = "zzz"
        pane.navigate(to: docs)
        check("filter clears on navigation", pane.filter.isEmpty)
        pane.filter = "A.T"
        let filtered: [String] = pane.visibleEntries.map { (e: Entry) -> String in e.name }
        check("filter matches case-insensitively", filtered == ["a.txt"])
        pane.filter = ""

        // Live refresh: another process writes into the open folder.
        try? "b".write(to: docs.appendingPathComponent("b.txt"), atomically: false, encoding: .utf8)
        var refreshed = false
        for _ in 0..<40 where !refreshed {
            try? await Task.sleep(for: .milliseconds(50))
            refreshed = pane.entries.contains { (e: Entry) -> Bool in e.name == "b.txt" }
        }
        check("live refresh picks up a new file", refreshed)

        model.toggleHidden()
        try? "h".write(to: docs.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        pane.reload()
        check("show hidden lists dotfiles", pane.entries.contains { (e: Entry) -> Bool in e.name == ".hidden" })
        model.toggleHidden()
        let stateFile: URL = home.appendingPathComponent("Library/Application Support/FileOS/state.json")
        let persisted: Bool = Store(url: stateFile).get("showHidden", default: true)
        check("hidden state persisted", persisted == false)

        if getuid() != 0 {
            let locked: URL = home.appendingPathComponent("Locked")
            try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
            pane.navigate(to: locked)
            let lockedState: FolderState = FolderState(error: pane.error)
            check("unreadable folder shows the locked screen", lockedState == .locked(folder: "Locked"))
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            pane.reload()
            check("Try Again after access is granted lists it", pane.error == nil)
        }

        let pages: [Page] = [.freeUpSpace, .installed, .agents, .aboutMac]
        for page in pages {
            model.page = page
            let views: [NSView] = hostedViews(model)
            check("page \(page.title) builds a split view", views.contains { (v: NSView) -> Bool in v is NSSplitView })
        }
        model.page = .browser
        pane.navigate(to: docs)
        let browserViews: [NSView] = hostedViews(model)
        check("browser builds a split view", browserViews.contains { (v: NSView) -> Bool in v is NSSplitView })
        check("browser builds the list table", browserViews.contains { (v: NSView) -> Bool in v is NSTableView })

        try? fm.removeItem(at: home)
        print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
        return ok
    }

    /// Hosts MainWindow in a borderless window that is never ordered front, lays it out,
    /// and returns every view in the hierarchy so checks can assert on real structure.
    private static func hostedViews(_ model: AppModel) -> [NSView] {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MainWindow().environment(model))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        host.layoutSubtreeIfNeeded()
        var all: [NSView] = []
        var stack: [NSView] = [host]
        while let view = stack.popLast() {
            all.append(view)
            stack.append(contentsOf: view.subviews)
        }
        window.contentView = nil
        return all
    }
}
