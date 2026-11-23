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
        let fm = FileManager.default
        let home = model.home
        let docs = home.appendingPathComponent("Documents")
        let pane = model.pane

        pane.navigate(to: docs)
        check("lists Documents/a.txt", pane.entries.map(\.name) == ["a.txt"] && pane.error == nil)
        check("Documents shows contents", FolderState(error: pane.error) == .contents)
        check("status bar text", StatusBar.text(items: 1, selected: 0, free: 0) == "1 item, 0 selected, 0 bytes available")

        let missing = home.appendingPathComponent("Nope")
        pane.navigate(to: missing)
        check("missing folder sets notFound", pane.error == .notFound(missing.path) && pane.entries.isEmpty)
        check("missing folder screen", FolderState(error: pane.error) == .unavailable("“Nope” could not be found"))

        pane.back()
        check("back returns to Documents", pane.url == docs.standardizedFileURL && pane.canGoForward)
        pane.forward()
        check("forward goes to the missing folder", pane.url == missing.standardizedFileURL)
        pane.navigate(to: docs)
        pane.up()
        check("up selects the folder it came from", pane.url == home.standardizedFileURL && pane.selection == [docs.path])

        check("path bar opens ~/Documents", model.go("~/Documents") && pane.url == docs.standardizedFileURL)
        check("path bar opens a file's folder with it selected",
              model.go("~/Documents/a.txt") && pane.selection == [docs.appendingPathComponent("a.txt").path])
        check("path bar suggests a near miss",
              !model.go("~/Documnts") && model.pathError?.suggestion == "~/Documents"
                  && model.pathError.map { PathBar.missingMessage(name: $0.name, parent: $0.parent) }
                  == "There's no folder called “Documnts” in \(home.lastPathComponent)")
        _ = model.go("~/New Stuff")
        model.createMissingFolder()
        let created = home.appendingPathComponent("New Stuff")
        check("Create This Folder makes and opens it", fm.fileExists(atPath: created.path) && pane.url == created.standardizedFileURL
              && model.undo.canUndo && model.toasts.contains { $0.undoable })

        pane.filter = "zzz"
        pane.navigate(to: docs)
        check("filter clears on navigation", pane.filter.isEmpty)
        pane.filter = "A.T"
        check("filter matches case-insensitively", pane.visibleEntries.map(\.name) == ["a.txt"])
        pane.filter = ""

        // Live refresh: another process writes into the open folder.
        try? "b".write(to: docs.appendingPathComponent("b.txt"), atomically: false, encoding: .utf8)
        var refreshed = false
        for _ in 0..<40 where !refreshed {
            try? await Task.sleep(for: .milliseconds(50))
            refreshed = pane.entries.contains { $0.name == "b.txt" }
        }
        check("live refresh picks up a new file", refreshed)

        model.toggleHidden()
        try? "h".write(to: docs.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        pane.reload()
        check("show hidden lists dotfiles", pane.entries.contains { $0.name == ".hidden" })
        model.toggleHidden()
        check("hidden state persisted", Store(url: home.appendingPathComponent("Library/Application Support/FileOS/state.json"))
              .get("showHidden", default: true) == false)

        if getuid() != 0 {
            let locked = home.appendingPathComponent("Locked")
            try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
            pane.navigate(to: locked)
            check("unreadable folder shows the locked screen", FolderState(error: pane.error) == .locked(folder: "Locked"))
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            pane.reload()
            check("Try Again after access is granted lists it", pane.error == nil)
        }

        for page in [Page.freeUpSpace, .installed, .agents, .aboutMac] {
            model.page = page
            check("page \(page.title) hosts", host(model) )
        }
        model.page = .browser
        pane.navigate(to: docs)
        check("main window lays out offscreen", host(model))

        try? fm.removeItem(at: home)
        print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
        return ok
    }

    /// Hosts MainWindow in an NSHostingView without presenting a window and forces layout.
    private static func host(_ model: AppModel) -> Bool {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: MainWindow().environment(model))
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        view.layoutSubtreeIfNeeded()
        return view.frame.width == 1000 && (!view.subviews.isEmpty || view.fittingSize != .zero)
    }
}
