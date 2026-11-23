import SwiftUI
import AppKit
import Quartz
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
        setvbuf(stdout, nil, _IOLBF, 0) // lines reach the CI log even if the run aborts
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
        for (name, passed) in await paneChecks(model) { check(name, passed) }
        for (name, passed) in await queueChecks(model) { check(name, passed) }
        for (name, passed) in await searchChecks(model) { check(name, passed) }
        // These print as they go, so a crash points at the step that caused it.
        await peekChecks(model, check)
        await markdownChecks(model, check)
        await smartChecks(model, check)

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

    /// F8: ⌘D, Tab, F5, ⌘U, layouts and saved layouts.
    static func paneChecks(_ model: AppModel) async -> [(String, Bool)] {
        var r: [(String, Bool)] = []
        let home: URL = model.home
        let docs: URL = home.appendingPathComponent("Documents")
        let aTxt: URL = docs.appendingPathComponent("a.txt")
        let other: URL = home.appendingPathComponent("Other")
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        model.page = .browser
        model.setLayout(.one)
        model.pane.navigate(to: docs)
        let oneTables: Int = tableCount(model) // includes the sidebar's outline view
        model.toggleDualPane()
        r.append(("⌘D makes two panes", model.panes.count == 2 && model.layout == .sideBySide))
        let twoTables: Int = tableCount(model)
        r.append(("two panes build two tables", twoTables == oneTables + 1))
        let left: PaneModel = model.panes[0]
        let right: PaneModel = model.panes[1]
        let tab: NSEvent? = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                             context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                                             isARepeat: false, keyCode: 48)
        let tabHandled: Bool = tab.map { (e: NSEvent) -> Bool in model.handlePaneKey(e) } ?? false
        r.append(("Tab switches the active pane", tabHandled && model.pane === right))
        let shiftTab: NSEvent? = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: "\t",
                                                  charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)
        let shiftHandled: Bool = shiftTab.map { (e: NSEvent) -> Bool in model.handlePaneKey(e) } ?? true
        r.append(("⇧Tab is left alone", !shiftHandled && model.pane === right))
        right.navigate(to: other)
        model.activate(left)
        left.selection = [aTxt.path]
        await model.transferToOtherPane(.copy)
        let copied: URL = other.appendingPathComponent("a.txt")
        r.append(("F5 copies a file to the other pane", exists(copied) && exists(aTxt)))
        r.append(("F5 toast", hasToast(model, "Copied 1 item to “Other”")))
        r.append(("F5 keeps the active pane", model.activePane == 0 && right.selection.isEmpty))
        r.append(("a drag from one pane to the other is across panes", model.isAcrossPanes([aTxt], to: other)))
        let sub: URL = docs.appendingPathComponent("Projects")
        r.append(("a drag within a pane is not", !model.isAcrossPanes([aTxt], to: sub)))
        await model.undoLast()
        r.append(("F5 copy is undoable", !exists(copied)))
        model.swapPanes()
        r.append(("⌘U swaps the panes", model.panes[0] === right && model.pane === left))
        model.setLayout(.four)
        r.append(("⌥⌘6 makes four panes", model.panes.count == 4 && tableCount(model) == twoTables + 2))
        model.saveLayout(named: "Month end")
        r.append(("saved layout listed first", model.savedLayouts.first?.name == "Month end"))
        let reopened = AppModel(home: model.home, trashDir: model.trashDir)
        r.append(("saved layout persisted", reopened.savedLayouts.first?.layout == .four))
        let found: [NamedMatch] = SearchModel.namedMatches("month", chip: .all, store: model.store, layouts: model.savedLayouts)
        r.append(("⌘K matches saved layouts", found.map { (n: NamedMatch) -> String in n.name } == ["Month end"]))
        model.setLayout(.one)
        r.append(("One Pane keeps the active pane", model.panes.count == 1 && model.pane === left))
        model.applyLayout(model.savedLayouts[0])
        r.append(("a saved layout restores its panes", model.panes.count == 4 && model.panes[0].url == FileOps.canonical(other)))
        model.setLayout(.one)
        return r
    }

    /// F5.4, F5.5: one transfer at a time, "Waiting: …", Cancel answers an open clash with Stop.
    static func queueChecks(_ model: AppModel) async -> [(String, Bool)] {
        var r: [(String, Bool)] = []
        let home: URL = model.home
        let docs: URL = home.appendingPathComponent("Documents")
        let spare: URL = home.appendingPathComponent("Spare2")
        try? FileManager.default.createDirectory(at: spare, withIntermediateDirectories: true)
        let clashing: URL = home.appendingPathComponent("Other/a.txt")
        try? "other".write(to: clashing, atomically: true, encoding: .utf8)
        let queue: TransferQueue = model.transfers
        let first = Task { await model.runTransfer([clashing], to: docs, mode: .copy) }
        var asked = false
        for _ in 0..<100 where !asked {
            try? await Task.sleep(for: .milliseconds(20))
            asked = model.clashPrompt != nil
        }
        let second = Task { await model.runTransfer([docs.appendingPathComponent("a.txt")], to: spare, mode: .copy) }
        var queued = false
        for _ in 0..<100 where !queued {
            try? await Task.sleep(for: .milliseconds(20))
            queued = !queue.waiting.isEmpty
        }
        let waitingText: String = queue.waiting.first.map { (j: TransferQueue.Job) -> String in TransferQueue.waitingText(j) } ?? ""
        r.append(("a second transfer waits", asked && queued && waitingText == "Waiting: Copying “a.txt” to “Spare2”"))
        let runningTitle: String = queue.running.map { (j: TransferQueue.Job) -> String in TransferQueue.title(j) } ?? ""
        r.append(("the running transfer is named", runningTitle == "Copying “a.txt”"))
        if let waiting = queue.waiting.first { queue.cancel(waiting.id) }
        r.append(("Cancel removes a waiting transfer", queue.waiting.isEmpty))
        if let running = queue.running { queue.cancel(running.id) }
        let firstDone: Bool = await first.value
        let secondDone: Bool = await second.value
        r.append(("Cancel stops the running transfer at its clash", !firstDone && model.clashPrompt == nil
                    && !exists(docs.appendingPathComponent("a 2.txt"))))
        r.append(("a cancelled waiting transfer never runs", !secondDone && !exists(spare.appendingPathComponent("a.txt"))))
        r.append(("queue is idle afterwards", queue.running == nil && queue.waiting.isEmpty))
        // A sheet dismissed by the system answers Stop instead of stranding the transfer.
        model.showSearch = true
        let third = Task { await model.runTransfer([clashing], to: docs, mode: .copy) }
        var reasked = false
        for _ in 0..<100 where !reasked {
            try? await Task.sleep(for: .milliseconds(20))
            reasked = model.clashPrompt != nil
        }
        r.append(("a clash closes ⌘K so its sheet can show", reasked && !model.showSearch))
        queue.showClash = false
        queue.clashSheetDismissed()
        let thirdDone: Bool = await third.value
        r.append(("dismissing the clash sheet stops the transfer", reasked && !thirdDone && model.clashPrompt == nil))
        let detail: String = TransferQueue.detail(bytesDone: 1_200_000_000, bytesTotal: 3_400_000_000, itemsDone: 12, itemsTotal: 40)
        r.append(("progress text", detail == "1.2 GB of 3.4 GB · 12 of 40 items"))
        return r
    }

    /// F7: ⌘K names, contents with the line, and ⌥Return.
    static func searchChecks(_ model: AppModel) async -> [(String, Bool)] {
        var r: [(String, Bool)] = []
        let docs: URL = model.home.appendingPathComponent("Documents")
        let aTxt: URL = docs.appendingPathComponent("a.txt")
        try? "one\nthe needle line".write(to: docs.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let search: SearchModel = model.search
        model.openSearch()
        r.append(("⌘K opens the palette", model.showSearch))
        search.query = "zzzz"
        model.runSearch()
        search.query = "a.txt"
        model.runSearch()
        await search.pending?.value
        let names: [String] = search.hits.map { (h: SearchHit) -> String in h.url.path }
        r.append(("⌘K finds Documents/a.txt", names.contains(aTxt.path)))
        search.query = "needle"
        search.contents = true
        model.runSearch()
        await search.pending?.value
        let line: (number: Int, text: String)? = search.hits.first?.line
        r.append(("Contents shows the matching line", line?.number == 2 && line?.text == "the needle line"))
        search.contents = false
        search.query = "a.txt"
        model.runSearch()
        await search.pending?.value
        if let row = search.rows.first(where: { (row: PaletteRow) -> Bool in row.id == "\(aTxt.path)#0" }) {
            model.revealPaletteRow(row)
        }
        r.append(("⌥Return shows the file in its folder", !model.showSearch && model.pane.url == FileOps.canonical(docs)
                    && model.pane.selection == Set([aTxt.path])))
        return r
    }

    private static func key(_ code: UInt16, _ chars: String) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
    }

    private static func press(_ model: AppModel, _ code: UInt16, _ chars: String) -> Bool {
        key(code, chars).map { (e: NSEvent) -> Bool in model.handlePaneKey(e) } ?? false
    }

    /// F6.1, F6.2, F5.14: Space, "1 of 2", ← →, Esc, the Info drawer, zip listing and Unpack.
    static func peekChecks(_ model: AppModel, _ check: (String, Bool) -> Void) async {
        let docs: URL = model.home.appendingPathComponent("Documents")
        let aTxt: URL = docs.appendingPathComponent("a.txt")
        let words: URL = docs.appendingPathComponent("words.txt")
        try? "one two\nthree".write(to: words, atomically: true, encoding: .utf8)
        let peek: PeekModel = model.peek
        model.showSearch = false
        model.showBatchRename = false
        model.page = .browser
        model.setLayout(.one)
        model.setView(.list)
        model.pane.navigate(to: docs)
        model.pane.reload()
        model.pane.selection = [aTxt.path, words.path]
        check("Space opens Peek", press(model, 49, " ") && peek.isShown)
        check("Peek steps through just the selection", peek.urls.count == 2 && peek.position == "1 of 2"
                    && Set(peek.urls) == Set([aTxt, words]))
        let second: URL? = peek.urls.count == 2 ? peek.urls[1] : nil // the folder's sort decides the order
        check("→ moves to the next item", press(model, 124, "\u{F703}") && peek.current == second
                    && peek.position == "2 of 2" && model.pane.selection.count == 2)
        if peek.current != words { model.peekStep(-1) }
        await peek.loading?.value
        check("Peek shows text", peek.content == .text("one two\nthree"))
        let rows: [(label: String, value: String)] = InfoDrawer.rows(url: words, info: peek.info)
        check("Info counts words and lines", rows.contains { (row: (label: String, value: String)) -> Bool in
            row.label == "Words" && row.value == "3" } && rows.contains { (row: (label: String, value: String)) -> Bool in
            row.label == "Lines" && row.value == "2" })
        check("Esc closes Peek", press(model, 53, "\u{1B}") && !peek.isShown)
        model.pane.selection = [aTxt.path]
        model.peekSelection()
        let siblings: Int = model.pane.shownIDs.count
        check("one selected item steps through its folder", peek.urls.count == siblings && peek.current == aTxt)
        check("Space closes Peek", press(model, 49, " ") && !peek.isShown)
        let wasShown: Bool = peek.showInfo
        peek.toggleInfo()
        check("the Info drawer is remembered", PeekModel(store: model.store).showInfo == !wasShown)
        peek.toggleInfo()

        // A zip made by the system tool, listed in Peek and unpacked next to itself.
        let src: URL = model.home.appendingPathComponent("ZipSource")
        try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try? "zipped".write(to: src.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)
        let zip: URL = docs.appendingPathComponent("Archive.zip")
        _ = try? await ProcessRunner().run("/usr/bin/ditto", ["-c", "-k", src.path, zip.path], timeout: 30)
        peek.show([zip])
        await peek.loading?.value
        var listed = false
        if case let .zip(entries, encrypted) = peek.content { listed = entries.contains("z.txt") && !encrypted }
        check("Peek lists a zip", listed)
        peek.close()
        await model.unpack(zip)
        let unpacked: URL = docs.appendingPathComponent("Archive/z.txt")
        check("Unpack makes a folder next to the zip", exists(unpacked))
        check("Unpack toast", hasToast(model, "Unpacked “Archive.zip” into “Archive”"))
        await model.unpack(zip)
        check("a second Unpack picks a new name", exists(docs.appendingPathComponent("Archive 2/z.txt")))
        await model.undoLast()
        await model.undoLast()
        check("Unpack is undoable", !exists(docs.appendingPathComponent("Archive")) && exists(zip))

        // A file Quick Look previews builds QLPreviewView inside the overlay.
        let blob: URL = docs.appendingPathComponent("blob.bin")
        try? Data([0, 1, 2]).write(to: blob)
        peek.show([blob])
        await peek.loading?.value
        let views: [NSView] = hostedViews(model)
        check("Peek hosts a Quick Look view", peek.content == .quickLook
                    && views.contains { (v: NSView) -> Bool in v is QLPreviewView })
        peek.close()
    }

    /// F6.3: a .md opens as a page; Save is undoable; leaving with edits asks first.
    static func markdownChecks(_ model: AppModel, _ check: (String, Bool) -> Void) async {
        let readme: URL = model.home.appendingPathComponent("Documents/readme.md")
        let original: String = "# Title\n\n## Part\nHello"
        try? original.write(to: readme, atomically: true, encoding: .utf8)
        func onDisk() -> String { (try? String(contentsOf: readme, encoding: .utf8)) ?? "" }
        await model.openMarkdown(readme)
        guard let doc = model.markdown else { return check("a .md opens as a page", false) }
        check("a .md opens as a page", model.page == .markdown && doc.text == original)
        let outline: [String] = Markdown.outline(doc.text).map { (h: (level: Int, text: String, id: String)) -> String in h.id }
        check("On this page lists the headings", outline == ["title", "part"])
        doc.mode = .edit
        check("Edit mode builds a text editor", hostedViews(model).contains { (v: NSView) -> Bool in v is NSTextView })
        doc.text = original + "\nMore"
        check("typing shows the Edited bar", doc.isEdited)
        doc.revert()
        check("Revert restores the saved text", !doc.isEdited && doc.text == original)
        doc.text = original + "\nMore"
        model.saveMarkdown()
        check("Save writes the file", onDisk() == original + "\nMore" && !doc.isEdited)
        check("Save toast", hasToast(model, "Saved “readme.md”"))
        await model.undoLast()
        check("undoing Save restores the previous text", onDisk() == original && doc.text == original)
        doc.text = "unsaved"
        await model.openMarkdown(readme)
        check("reopening the open .md keeps its edits", model.markdown === doc && doc.text == "unsaved")
        // Another app changes the file after it was opened: Save wins, Undo brings that version back.
        try? "external".write(to: readme, atomically: true, encoding: .utf8)
        model.saveMarkdown()
        check("Save over an outside change says so", onDisk() == "unsaved"
                && hasToast(model, "Saved “readme.md” over changes made elsewhere"))
        await model.undoLast()
        check("undo restores the outside change", onDisk() == "external" && doc.text == "external")
        doc.text = "edited"
        check("quitting with edits can be cancelled", !model.mayQuit({ (_: String) -> LeaveAnswer in .cancel })
                && model.markdown === doc)
        check("quitting with Don't Save writes nothing", model.mayQuit({ (_: String) -> LeaveAnswer in .discard })
                && onDisk() == "external")
        check("quitting with Save writes first", model.mayQuit({ (_: String) -> LeaveAnswer in .save }) && onDisk() == "edited")
        let original2: String = onDisk()
        doc.text = "changed"
        model.page = .browser
        model.pageChanged(from: .markdown, to: .browser)
        check("leaving with edits asks first", model.page == .markdown && model.showLeaveAlert
                    && AppModel.leaveTitle(doc.name) == "Save the changes to “readme.md”?")
        model.showLeaveAlert = false
        model.finishLeaving(save: false)
        check("Don't Save leaves without writing", model.page == .browser && model.markdown == nil && onDisk() == original2)
    }

    /// F9 Tidy and Smart Downloads, F13 folder symbols, F10 Free Up Space.
    static func smartChecks(_ model: AppModel, _ check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        let home: URL = model.home
        let downloads: URL = home.appendingPathComponent("Downloads")
        let hourAgo: Date = Date().addingTimeInterval(-3600)
        try? fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        for name in ["a.pdf", "b.jpg", "c.pdf"] {
            let url: URL = downloads.appendingPathComponent(name)
            try? name.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.modificationDate: hourAgo, .creationDate: hourAgo], ofItemAtPath: url.path)
        }
        try? "new".write(to: downloads.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        model.page = .browser
        model.pane.navigate(to: downloads)
        check("Tidy is titled for Downloads", model.tidyTitle == "Tidy Downloads…")
        model.beginTidy()
        check("Tidy plans the loose files", model.showTidy && model.tidy?.count == 3 && model.tidy?.buttonTitle == "Move 3 Files")
        check("Tidy leaves just-added files", model.tidy?.plan.left.first?.reason == "Added in the last 2 minutes")
        model.setTidySkip(.images, true)
        check("unticking a kind skips it", model.tidy?.buttonTitle == "Move 2 Files")
        model.applyTidy()
        check("Tidy moves into kind folders", exists(downloads.appendingPathComponent("PDFs/a.pdf")) && exists(downloads.appendingPathComponent("b.jpg")))
        check("Tidy toast", hasToast(model, "Moved 2 files into folders"))
        await model.undoLast()
        check("undoing Tidy restores and removes its folder", exists(downloads.appendingPathComponent("a.pdf"))
                    && !exists(downloads.appendingPathComponent("PDFs")))

        model.setGroup(.date)
        let dateTitles: [String] = model.pane.sections.map { (s: RowSection) -> String in s.title }
        check("Downloads groups by Smart Downloads dates", dateTitles.first == "Today")
        model.setGroup(.kind)
        let kindTitles: [String] = model.pane.sections.map { (s: RowSection) -> String in s.title }
        check("Downloads groups by kind, biggest first", kindTitles.first == "Documents" || kindTitles.first == "PDFs")
        model.setGroup(.none)
        model.setView(.list)
        if !model.showInsights { model.toggleInsights() }
        check("Insights replaces the preview pane", model.showInsights && !model.showPreview)
        check("Insights builds", hostedViews(model).contains { (v: NSView) -> Bool in v is NSTableView })
        model.toggleInsights()

        let invoices: URL = home.appendingPathComponent("Documents/Invoices")
        try? fm.createDirectory(at: invoices, withIntermediateDirectories: true)
        let entry: Entry? = (try? FileOps.listDirectory(invoices.deletingLastPathComponent()))?.first { (e: Entry) -> Bool in e.name == "Invoices" }
        if let entry {
            await model.loadSymbol(entry)
            check("Invoices gets the receipt symbol", model.folderSymbol(entry) == "receipt")
            model.setSymbol("star", for: [invoices])
            let stored: [String: String] = Store(url: home.appendingPathComponent("Library/Application Support/FileOS/state.json"))
                .get(AppModel.symbolsKey, default: [String: String]())
            check("a chosen symbol is stored by path", model.folderSymbol(entry) == "star" && stored[FileOps.canonical(invoices).path] == "star")
            model.setColor("red", for: [invoices])
            check("a chosen colour shows", model.folderColor(invoices) != nil)
            await model.undoLast()
            await model.undoLast()
            check("undo puts the automatic symbol and colour back", model.folderSymbol(entry) == "receipt" && model.folderColor(invoices) == nil)
        } else {
            check("Invoices is listed", false)
        }

        let blob: String = String(repeating: "z", count: 4096)
        let kept: URL = home.appendingPathComponent("Documents/big.bin")
        let spare: URL = downloads.appendingPathComponent("big.bin")
        try? blob.write(to: kept, atomically: true, encoding: .utf8)
        try? blob.write(to: spare, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.modificationDate: hourAgo, .creationDate: hourAgo.addingTimeInterval(-86_400)], ofItemAtPath: kept.path)
        try? fm.setAttributes([.modificationDate: hourAgo, .creationDate: hourAgo], ofItemAtPath: spare.path)
        await model.clean.scan(home: home, applications: [home.appendingPathComponent("Applications")])
        check("Free Up Space shows nine cards", model.clean.cards.count == 9 && !model.clean.looking)
        let dupes: [CleanItem] = model.clean.card(.duplicates)?.items ?? []
        check("the Downloads duplicate is ticked", dupes.map { (i: CleanItem) -> String in i.url.lastPathComponent } == ["big.bin"]
                    && dupes.first?.url.path == spare.path && dupes.first?.ticked == true)
        check("the ticked bar", model.clean.barText == "1 ticked · 4.1 KB")
        model.moveTickedToTrash()
        check("Move 1 to Trash moves only the spare", !exists(spare) && exists(kept))
        check("Smart Clean toast", hasToast(model, "Moved 1 item to the Trash"))
        check("the moved item leaves its card", model.clean.ticked.isEmpty)
        await model.undoLast()
        check("undoing Smart Clean restores the spare", exists(spare))
        model.page = .freeUpSpace
        check("Free Up Space page builds", hostedViews(model).contains { (v: NSView) -> Bool in v is NSSplitView })
        model.page = .browser
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
