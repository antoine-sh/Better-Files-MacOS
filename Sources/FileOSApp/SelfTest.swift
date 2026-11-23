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
        Pasteboard.board = NSPasteboard(name: NSPasteboard.Name("com.fileos.selftest.\(UUID().uuidString)"))
        return AppModel(home: home, trashDir: home.appendingPathComponent(".Trash"))
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

        for (name, passed) in await fileChecks(model) { check(name, passed) }
        for (name, passed) in viewChecks(model) { check(name, passed) }

        try? fm.removeItem(at: home)
        print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
        return ok
    }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private static func hasToast(_ model: AppModel, _ text: String) -> Bool {
        model.toasts.contains { (t: Toast) -> Bool in t.text == text && t.undoable }
    }

    /// F5: new folder, rename, trash + undo, clipboard, clashes, duplicate, batch rename.
    static func fileChecks(_ model: AppModel) async -> [(String, Bool)] {
        var r: [(String, Bool)] = []
        let home: URL = model.home
        let docs: URL = home.appendingPathComponent("Documents")
        let aTxt: URL = docs.appendingPathComponent("a.txt")
        let pane: PaneModel = model.pane
        model.page = .browser
        model.setView(.list)
        pane.navigate(to: docs)

        model.newFolder()
        let untitled: URL = docs.appendingPathComponent("untitled folder")
        r.append(("new folder is “untitled folder”", exists(untitled)))
        r.append(("new folder starts its rename", pane.renaming == untitled.path))
        r.append(("new folder is undoable", hasToast(model, "Created “untitled folder”")))
        model.commitRename(untitled, to: "Projects")
        let projects: URL = docs.appendingPathComponent("Projects")
        r.append(("inline rename renames", exists(projects) && !exists(untitled)))
        r.append(("rename rejects a colon", { () -> Bool in
            pane.renaming = projects.path
            model.commitRename(projects, to: "a:b")
            return exists(projects)
        }()))

        let report: URL = docs.appendingPathComponent("report.pdf")
        try? "pdf".write(to: report, atomically: true, encoding: .utf8)
        pane.reload()
        pane.renaming = report.path
        model.commitRename(report, to: "summary.docx")
        r.append(("extension change asks first", model.showExtensionAlert && model.extensionPrompt?.from == ".pdf"))
        r.append(("nothing renamed before the answer", exists(report)))
        model.showExtensionAlert = false
        model.resolveExtension(keep: true)
        r.append(("Keep .pdf keeps the extension", exists(docs.appendingPathComponent("summary.pdf"))))

        pane.selection = [aTxt.path]
        model.trash(model.targets)
        r.append(("trash moves the item", !exists(aTxt)))
        r.append(("trash toast", hasToast(model, "Moved 1 item to the Trash")))
        await model.undoLast()
        r.append(("undo restores the trashed item", exists(aTxt)))

        pane.selection = [aTxt.path]
        model.copy(model.targets)
        pane.navigate(to: home)
        await model.paste()
        let pasted: URL = home.appendingPathComponent("a.txt")
        r.append(("paste copies via the clipboard", exists(pasted) && exists(aTxt)))
        r.append(("paste toast", hasToast(model, "Copied 1 item to “\(home.lastPathComponent)”")))
        r.append(("pasted item is selected", pane.selection == Set([pasted.path])))

        // The same name in Documents now clashes.
        model.copy([pasted])
        pane.navigate(to: docs)
        let pasting = Task { await model.paste() }
        var asked = false
        for _ in 0..<100 where !asked {
            try? await Task.sleep(for: .milliseconds(20))
            asked = model.clashPrompt != nil
        }
        let title: String = model.clashPrompt.map { (p: ClashPrompt) -> String in ClashDialog.title(p.clash) } ?? ""
        r.append(("a clash asks", title == "“a.txt” is already in “Documents”"))
        model.answerClash(.keepBoth, all: false)
        await pasting.value
        r.append(("Keep Both makes “a 2.txt”", exists(docs.appendingPathComponent("a 2.txt"))))
        await model.undoLast()
        r.append(("undo removes the kept copy", !exists(docs.appendingPathComponent("a 2.txt"))))

        model.copy([aTxt], cut: true)
        r.append(("cut items are dimmed", model.isCut(aTxt.path)))
        model.cancelCut()
        r.append(("Esc cancels a cut", !model.isCut(aTxt.path)))

        // Two pastes at once: the second waits for the first (which is asking about a clash), both finish and undo.
        let spare: URL = home.appendingPathComponent("Spare")
        try? FileManager.default.createDirectory(at: spare, withIntermediateDirectories: true)
        model.copy([aTxt])
        let firstPaste = Task { await model.paste(into: home) }
        let secondPaste = Task { await model.paste(into: spare) }
        var clashed = false
        for _ in 0..<100 where !clashed {
            try? await Task.sleep(for: .milliseconds(20))
            clashed = model.clashPrompt != nil
        }
        r.append(("overlapping paste waits for the first", clashed && !exists(spare.appendingPathComponent("a.txt"))))
        model.answerClash(.keepBoth, all: false)
        await firstPaste.value
        await secondPaste.value
        let kept: URL = home.appendingPathComponent("a 2.txt")
        let second: URL = spare.appendingPathComponent("a.txt")
        r.append(("overlapping pastes both complete", exists(kept) && exists(second)))
        await model.undoLast()
        await model.undoLast()
        r.append(("overlapping pastes are both undoable", !exists(kept) && !exists(second)))

        pane.selection = [aTxt.path]
        pane.filter = "zzz"
        r.append(("commands skip selected items the filter hides", model.targets.isEmpty))
        pane.filter = ""

        model.duplicate([aTxt])
        r.append(("duplicate makes “a copy.txt”", exists(docs.appendingPathComponent("a copy.txt"))))

        for name in ["x1.txt", "x2.txt"] {
            try? name.write(to: docs.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let present: Set<String> = Set((try? FileManager.default.contentsOfDirectory(atPath: docs.path)) ?? [])
        let rows: [Rename.BatchRow] = Rename.plan(["x1.txt", "x2.txt"], rule: .number(name: "Lisbon", start: 1), existing: present)
        model.applyBatchRename(rows, in: docs)
        r.append(("batch rename applies the plan", exists(docs.appendingPathComponent("Lisbon 01.txt"))
                    && exists(docs.appendingPathComponent("Lisbon 02.txt"))))
        r.append(("batch rename toast", hasToast(model, "Renamed 2 items")))
        await model.undoLast()
        r.append(("undo reverts the batch rename", exists(docs.appendingPathComponent("x1.txt"))))

        let expected: String = "12 items (1.9 GB) will be deleted for good. This can't be undone."
        r.append(("Empty Trash copy", AppModel.emptyTrashMessage(count: 12, bytes: 1_900_000_000) == expected))
        return r
    }

    /// F3: view modes, sort and group persisted per folder, shortcuts in menus.
    static func viewChecks(_ model: AppModel) -> [(String, Bool)] {
        var r: [(String, Bool)] = []
        let docs: URL = model.home.appendingPathComponent("Documents")
        let pane: PaneModel = model.pane
        model.page = .browser
        pane.navigate(to: docs)
        model.setView(.list)
        let listTables: Int = tableCount(model)
        model.setView(.icons)
        r.append(("icons view replaces the table", pane.view == .icons && tableCount(model) < listTables))
        model.setView(.columns)
        r.append(("columns view replaces the table", pane.view == .columns && tableCount(model) < listTables))
        if !model.showPreview { model.togglePreview() }
        model.newFolder()
        let fresh: String = pane.renaming ?? ""
        r.append(("one rename field: the row, not the preview",
                  !fresh.isEmpty && pane.hostsRename(fresh, preview: false) && !pane.hostsRename(fresh, preview: true)))
        model.beginRename([URL(fileURLWithPath: fresh)], inPreview: true)
        r.append(("rename from the preview is hosted there only",
                  pane.hostsRename(fresh, preview: true) && !pane.hostsRename(fresh, preview: false)))
        model.cancelRename()
        model.togglePreview()
        let reopenedView: ViewMode = AppModel(home: model.home, trashDir: model.trashDir).pane.view
        r.append(("view mode persisted", reopenedView == .columns))
        model.setView(.list)

        model.setGroup(.kind)
        model.setSort(.size)
        model.toggleFilesFirst()
        r.append(("files first puts files before folders", pane.visibleEntries.first?.isDirectory == false))
        r.append(("grouping by kind makes sections", pane.sections.map { (s: RowSection) -> String in s.title } == ["Folders", "PDFs", "Documents"]))
        r.append(("grouped list still builds a table", tableCount(model) == listTables))
        let reopened = AppModel(home: model.home, trashDir: model.trashDir)
        reopened.pane.navigate(to: docs)
        let prefs: FolderPrefs = reopened.pane.prefs
        r.append(("group and sort persisted per folder", prefs == FolderPrefs(sortKey: .size, filesFirst: true, group: .kind)))
        reopened.pane.navigate(to: model.home)
        r.append(("other folders keep the default sort", reopened.pane.prefs == FolderPrefs()))
        pane.sort = [PaneModel.comparator(.modified, ascending: false)]
        pane.tableSortChanged()
        r.append(("column click sets the folder sort", pane.prefs.sortKey == .modified && !pane.prefs.ascending))
        model.setGroup(.none)

        let newFolder: KeyboardShortcut? = model.shortcuts["newFolder"]?.menuShortcut
        r.append(("⇧⌘N is New Folder", newFolder == KeyboardShortcut("n", modifiers: [.command, .shift])))
        r.append(("F7 is a menu shortcut", model.shortcuts["newFolderF7"]?.menuShortcut != nil))
        r.append(("Return is left to the file views", model.shortcuts["rename"]?.menuShortcut == nil))
        return r
    }

    private static func tableCount(_ model: AppModel) -> Int {
        hostedViews(model).filter { (v: NSView) -> Bool in v is NSTableView }.count
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
