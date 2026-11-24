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
        let model = AppModel(home: home, trashDir: home.appendingPathComponent(".Trash"))
        model.cleanApplications = [home.appendingPathComponent("Applications")] // not the runner's real apps
        model.fetchesLinkMeta = false // CI must not depend on the network
        model.runner = SelfTestRunner() // canned git/brew/lsof answers: nothing real is run
        return model
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
        check("a folder lists off the main actor", pane.loading)
        await pane.loaded()
        check("the listing lands", !pane.loading)
        let names: [String] = pane.entries.map { (e: Entry) -> String in e.name }
        check("lists Documents/a.txt", names == ["a.txt"])
        check("Documents has no error", pane.error == nil)
        check("Documents shows contents", FolderState(error: pane.error) == .contents)
        let status: String = StatusBar.text(items: 1, selected: 0, free: 0)
        check("status bar text", status == "1 item, 0 selected, 0 bytes available")

        let missing: URL = home.appendingPathComponent("Nope")
        pane.navigate(to: missing)
        await pane.loaded()
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
        await pane.loaded()
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
        await pane.loaded()
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
            await pane.loaded()
            let lockedState: FolderState = FolderState(error: pane.error)
            check("unreadable folder shows the locked screen", lockedState == .locked(folder: "Locked"))
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            pane.reload()
            await pane.loaded()
            check("Try Again after access is granted lists it", pane.error == nil)
        }

        let pages: [Page] = [.freeUpSpace, .installed, .agents, .aboutMac, .bookmarks, .workspace(Workspaces.sampleID)]
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
        for (name, passed) in await viewChecks(model) { check(name, passed) }
        for (name, passed) in await paneChecks(model) { check(name, passed) }
        for (name, passed) in await queueChecks(model) { check(name, passed) }
        for (name, passed) in await searchChecks(model) { check(name, passed) }
        // These print as they go, so a crash points at the step that caused it.
        await peekChecks(model, check)
        await markdownChecks(model, check)
        await smartChecks(model, check)
        await libraryChecks(model, check)
        await devChecks(model, check)
        await homeChecks(model, check)
        await sidebarChecks(model, check)
        await settingsChecks(model, check)

        try? fm.removeItem(at: home)
        print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
        return ok
    }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Lines appended from concurrent tasks (the undo-order check).
    @MainActor final class SelfTestLog {
        private(set) var lines: [String] = []
        func add(_ line: String) { lines.append(line) }
    }

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

        await model.settled()
        pane.selection = [aTxt.path]
        model.trash(model.targets)
        r.append(("trash moves the item", !exists(aTxt)))
        r.append(("trash toast", hasToast(model, "Moved 1 item to the Trash")))
        await model.undoLast()
        r.append(("undo restores the trashed item", exists(aTxt)))

        await model.settled()
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

        // A dot name is allowed after "Use “.”" (it hides the item).
        let envFile: URL = docs.appendingPathComponent("env")
        try? "x".write(to: envFile, atomically: true, encoding: .utf8)
        pane.renaming = envFile.path
        model.commitRename(envFile, to: ".env")
        r.append(("a dot name asks first", model.showDotAlert && exists(envFile)))
        model.showDotAlert = false
        model.confirmDotName()
        r.append(("Use “.” renames", exists(docs.appendingPathComponent(".env")) && !exists(envFile)))

        r.append(("only the newest undoable toast offers Undo",
                  model.undoToastID == model.toasts.last { (t: Toast) -> Bool in t.undoable }?.id && model.undoToastID != nil))

        // Two undos at once run one after the other, never interleaved.
        let order = SelfTestLog()
        for name in ["first", "second"] {
            model.undo.push(name) {
                await order.add("start \(name)")
                try? await Task.sleep(for: .milliseconds(30))
                await order.add("end \(name)")
                return RestoreResult()
            }
        }
        let u1 = Task { await model.undoLast() }
        let u2 = Task { await model.undoLast() }
        await u1.value
        await u2.value
        r.append(("concurrent undos don't interleave", order.lines == ["start second", "end second", "start first", "end first"]))

        // F2.2: Remove from Sidebar is undoable and keeps the folder.
        model.addToSidebar([spare])
        let favourite: URL = FileOps.canonical(spare)
        model.removeFromSidebar(favourite)
        r.append(("Remove from Sidebar removes only the shortcut", !model.favorites.contains(favourite) && exists(spare)))
        await model.undoLast()
        r.append(("Remove from Sidebar is undoable", model.favorites.contains(favourite)))
        model.removeFavorites([favourite])

        // F2.6: what counts as on a drive.
        let drive: URL = URL(fileURLWithPath: "/Volumes/Backup")
        r.append(("a path on a drive is on it", AppModel.isOn(URL(fileURLWithPath: "/Volumes/Backup/a.txt"), volume: drive)
                    && !AppModel.isOn(URL(fileURLWithPath: "/Volumes/Backup 2/a.txt"), volume: drive)))
        r.append(("an idle drive isn't busy", !model.isBusy(drive)))
        r.append(("⌘E is Eject", model.shortcuts["eject"]?.menuShortcut == KeyboardShortcut("e", modifiers: [.command])))

        // F5.10: an empty, readable Trash says so (read off the main actor).
        try? FileManager.default.removeItem(at: model.trashURL)
        try? FileManager.default.createDirectory(at: model.trashURL, withIntermediateDirectories: true)
        model.askEmptyTrash()
        var said = false
        for _ in 0..<100 where !said {
            try? await Task.sleep(for: .milliseconds(20))
            said = model.toasts.contains { (t: Toast) -> Bool in t.text == "The Trash is empty" }
        }
        r.append(("an empty Trash says so", said && !model.showTrashAccessAlert))
        r.append(("an unreadable Trash isn't shown as empty", AppModel.trashLine(nil) == "In the Trash: unknown (needs Full Disk Access)"))
        r.append(("link pictures on the local network aren't loaded", LinkMeta.imageURL("http://192.168.1.2/a.png") == nil
                    && LinkMeta.imageURL("https://example.com/a.png") != nil))

        let expected: String = "12 items (1.9 GB) will be deleted for good. This can't be undone."
        r.append(("Empty Trash copy", AppModel.emptyTrashMessage(count: 12, bytes: 1_900_000_000) == expected))
        return r
    }

    /// F3: view modes, sort and group persisted per folder, shortcuts in menus.
    static func viewChecks(_ model: AppModel) async -> [(String, Bool)] {
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
        await model.settled()
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
        await model.settled()
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
        await model.settled()
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
        await model.settled()
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

        await model.settled()
        model.setGroup(.date)
        let dateTitles: [String] = model.pane.sections.map { (s: RowSection) -> String in s.title }
        check("Downloads groups by Smart Downloads dates", dateTitles.first == "Today")
        model.setGroup(.kind)
        let kindTitles: [String] = model.pane.sections.map { (s: RowSection) -> String in s.title }
        check("Downloads groups by kind, biggest first", kindTitles == ["PDFs", "Images", "Documents"])
        model.setGroup(.none)
        model.setView(.list)
        if !model.showInsights { model.toggleInsights() }
        check("Insights replaces the preview pane", model.showInsights && !model.showPreview)
        model.installedAppNames = nil
        let loadedApps: Bool = await hostAndWait(model) { () -> Bool in model.installedAppNames != nil }
        check("Insights loads the installed apps when it opens", loadedApps)
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
        let apps: [URL]? = model.cleanApplications
        let first = Task { await model.clean.scan(home: home, applications: apps) }
        for _ in 0..<200 where !model.clean.looking { await Task.yield() }
        model.clean.cancel()
        await first.value
        check("a cancelled scan asks for another", model.clean.needsScan && !model.clean.looking)
        let before: Int = model.clean.scansStarted
        model.page = .freeUpSpace
        let rescanned: Bool = await hostAndWait(model) { () -> Bool in model.clean.scansStarted > before && !model.clean.looking }
        check("Free Up Space looks again when it opens", rescanned)
        model.page = .browser
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
    }

    /// F11 Workspaces, F12 Bookmarks, and ⌘K finding both.
    static func libraryChecks(_ model: AppModel, _ check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        let taxes: URL = model.home.appendingPathComponent("Documents/Taxes")
        try? fm.createDirectory(at: taxes, withIntermediateDirectories: true)
        try? "r".write(to: taxes.appendingPathComponent("receipt.pdf"), atomically: true, encoding: .utf8)
        check("the sample workspace is there", model.workspace(Workspaces.sampleID)?.name == "Acme Project")

        var draft = WorkspaceDraft()
        draft.name = "Taxes 2026"
        draft.color = "green"
        let problem: String? = model.commitWorkspaceDraft(draft)
        guard let w = model.workspaces.first(where: { (x: Workspace) -> Bool in x.name == "Taxes 2026" }) else {
            return check("New Workspace creates “Taxes 2026”", false)
        }
        check("New Workspace opens “Taxes 2026”", problem == nil && model.page == .workspace(w.id))
        model.addToWorkspace(w.id, [taxes])
        check("Add to Workspace toast", hasToast(model, "Added 1 item to “Taxes 2026”"))
        model.addToWorkspace(w.id, [taxes])
        let items: [WorkspaceItem] = model.workspace(w.id)?.items ?? []
        check("adding a folder twice lists it once", items.count == 1 && items.first?.kind == .folder
                && items.first?.path == FileOps.canonical(taxes).path)
        check("the folder is still on disk at its path", AppModel.isBrowsableFolder(taxes)
                && exists(taxes.appendingPathComponent("receipt.pdf")))
        check("the workspace page builds", hostedViews(model).contains { (v: NSView) -> Bool in v is NSSplitView })
        let stored: [Workspace] = Store(url: model.home.appendingPathComponent("Library/Application Support/FileOS/state.json"))
            .getArray("workspaces", of: Workspace.self) ?? []
        check("workspaces are saved", stored.contains { (x: Workspace) -> Bool in x.id == w.id && x.items.count == 1 })

        if let item = items.first {
            model.setPinned(w.id, item.id, true)
            model.openPinned(1)
            check("⌃⌥1 opens the pinned folder", model.page == .browser && model.pane.url == FileOps.canonical(taxes))
            model.page = .workspace(w.id)
            model.removeFromWorkspace(w.id, [item.id])
            check("Remove only unlists", model.workspace(w.id)?.items.isEmpty == true && exists(taxes))
            await model.undoLast()
            check("undo puts the item back", model.workspace(w.id)?.items.count == 1)
        }
        let gone: URL = model.home.appendingPathComponent("Gone")
        try? fm.createDirectory(at: gone, withIntermediateDirectories: true)
        model.addToWorkspace(w.id, [gone])
        try? fm.removeItem(at: gone)
        let goneItem: WorkspaceItem? = model.workspace(w.id)?.items.first { (i: WorkspaceItem) -> Bool in i.name == "Gone" }
        check("a missing item says Can't find it", goneItem.map { (i: WorkspaceItem) -> String? in model.itemStatus(i).text } == "Can't find it")

        model.archiveWorkspace(w.id)
        check("Archive hides it from ⌃1–⌃9", !model.activeWorkspaces.contains { (x: Workspace) -> Bool in x.id == w.id })
        model.restoreWorkspace(w.id)
        model.deleteWorkspace(w.id)
        check("Delete removes the workspace and leaves its page", model.workspace(w.id) == nil && model.page == .browser && exists(taxes))
        await model.undoLast()
        check("undoing Delete brings it back", model.workspace(w.id)?.items.count == 2)

        Pasteboard.clear()
        model.page = .bookmarks
        let handled: Bool = model.pasteOnPage()
        check("⌘V on Bookmarks without a link saves nothing", handled && model.bookmarkState.bookmarks.isEmpty
                && model.toasts.contains { (t: Toast) -> Bool in t.text == "Copy a link first" })
        Pasteboard.write("https://example.com/taxes-guide")
        _ = model.pasteOnPage()
        check("⌘V on Bookmarks saves the copied link", hasToast(model, "Saved")
                && model.bookmarkState.bookmarks.map { (b: Bookmark) -> String in b.url } == ["https://example.com/taxes-guide"])
        model.saveLink("example.com/taxes-guide")
        check("saving it again says Already saved", model.toasts.contains { (t: Toast) -> Bool in t.text == "Already saved" }
                && model.bookmarkState.bookmarks.count == 1)
        check("the Bookmarks page builds", hostedViews(model).contains { (v: NSView) -> Bool in v is NSSplitView })
        let servicePB = NSPasteboard(name: NSPasteboard.Name("FileOS.selftest.service"))
        servicePB.clearContents()
        servicePB.setString("https://example.com/from-services", forType: .string)
        var serviceError: NSString? = nil
        ServiceProvider(model: model).saveLink(servicePB, userData: nil, error: &serviceError)
        check("Services > Save Link to FileOS saves the link", serviceError == nil
                && model.bookmarkState.bookmarks.contains { (b: Bookmark) -> Bool in b.url == "https://example.com/from-services" })
        await model.undoLast() // later checks count bookmarks
        servicePB.clearContents()
        servicePB.setString("not a link at all", forType: .string)
        ServiceProvider(model: model).saveLink(servicePB, userData: nil, error: &serviceError)
        check("Services rejects text that isn't a link", serviceError == "That isn't a link")
        servicePB.releaseGlobally()

        model.search.query = "taxes"
        model.search.chip = .all
        model.runSearch()
        let named: [NamedMatch] = model.search.named
        check("⌘K finds the workspace", named.contains { (n: NamedMatch) -> Bool in n.kind == .workspace && n.target == w.id.uuidString })
        check("⌘K finds the bookmark", named.contains { (n: NamedMatch) -> Bool in n.kind == .bookmark && n.target == "https://example.com/taxes-guide" })
        if let row = model.search.rows.first(where: { (r: PaletteRow) -> Bool in r.id == "Workspace:\(w.id.uuidString)" }) {
            model.openPaletteRow(row)
        }
        check("Return on a ⌘K workspace opens it", model.page == .workspace(w.id))
        await model.search.pending?.value

        model.createCollection(name: "Reading", icon: "book")
        guard let reading = model.placeCollection else { return check("New Collection opens it", false) }
        model.saveLink("https://swift.org/blog", collection: reading)
        model.deleteCollection(reading)
        check("deleting a collection removes its links", model.bookmarkState.collections.isEmpty
                && model.bookmarkState.bookmarks.count == 1 && model.bookmarkPlace == .all)
        await model.undoLast()
        check("undoing Delete Collection brings them back", model.bookmarkState.collections.count == 1
                && model.bookmarkState.bookmarks.count == 2)

        // Page details fetched after a save survive undoing to an older snapshot (here: the second save's).
        model.saveLink("https://example.org/post")
        model.saveLink("https://example.org/later")
        if let saved = model.bookmarkState.bookmarks.first(where: { (b: Bookmark) -> Bool in b.url == "https://example.org/post" }) {
            let meta = FetchedMeta(title: "The Real Title", image: nil, icon: nil)
            model.fetchedMeta[saved.id] = meta // as `fillMeta` does when the page arrives
            model.setBookmarks(Bookmarks.update(model.bookmarkState, saved.id) { (b: inout Bookmark) in meta.apply(to: &b) }, undo: nil)
            await model.undoLast()
            check("undo keeps a fetched title", model.bookmark(saved.id)?.title == "The Real Title"
                    && !model.bookmarkState.bookmarks.contains { (b: Bookmark) -> Bool in b.url == "https://example.org/later" })
        }
        model.page = .bookmarks
        let before: Int = model.bookmarkState.bookmarks.count
        check("⌥⌘V on Bookmarks moves nothing", model.pasteOnPage(move: true) && model.bookmarkState.bookmarks.count == before)

        var scratch = WorkspaceDraft()
        scratch.name = "Scratch"
        model.commitWorkspaceDraft(scratch)
        await model.undoLast()
        check("undoing New Workspace leaves its page", model.page == .browser
                && !model.workspaces.contains { (x: Workspace) -> Bool in x.name == "Scratch" })
        model.page = .browser
    }

    /// F14: git chip, Open In defaults, Installed, AI Agents, About This Mac.
    static func devChecks(_ model: AppModel, _ check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        let home: URL = model.home
        func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        func said(_ text: String) -> Bool { model.toasts.contains { (t: Toast) -> Bool in t.text == text } }

        let repo: URL = FileOps.canonical(home.appendingPathComponent("Repo"))
        try? fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let git: GitResult = await model.gitStatus(repo)
        if case .status(let s) = git {
            check("git chip shows the branch and count", AppModel.gitChipText(s) == "main · 2" && AppModel.gitCounts(s) == "1 changed, 1 new, 0 deleted")
            model.copyBranchName(s)
            check("Copy Branch Name", Pasteboard.string() == "main")
        } else {
            check("git chip shows the branch and count", false)
        }
        let plain: GitResult = await model.gitStatus(home.appendingPathComponent("Documents"))
        check("no git chip outside a repo", plain == .notRepo)

        model.setDefaultApp(.terminal, id: "no-such-terminal")
        check("an uninstalled default falls back", model.defaultApp(.terminal)?.id != "no-such-terminal"
                && model.store.get(AppModel.defaultsKey(.terminal), default: "") == "no-such-terminal")

        let installed: InstalledModel = model.installed
        await installed.load(runner: model.runner, home: home)
        check("Installed lists Homebrew", installed.summary == "6 packages from 1 tool")
        installed.filter = .apps
        check("Installed Apps filter", installed.shown(now: Date()).map { (p: Package) -> String in p.name } == ["firefox"])
        installed.filter = .leftBehind
        check("Installed Left behind filter", installed.shown(now: Date()).map { (p: Package) -> String in p.name } == ["oldlib"])
        check("Two of the same finds node and node@24", installed.twins.count == 1)
        installed.filter = .all
        if let node = installed.all.first(where: { (p: Package) -> Bool in p.name == "node" }) {
            model.copyRemoveCommand(node)
        }
        check("Copy Remove Command copies, runs nothing", Pasteboard.string() == "brew uninstall node")
        let brewfile: URL = home.appendingPathComponent("Brewfile")
        model.saveBrewfile(to: brewfile)
        check("Save List writes a Brewfile", read(brewfile) == "brew \"node\"\nbrew \"node@24\"\ncask \"firefox\"\n")
        await model.undoLast()
        check("undoing Save List removes it", !exists(brewfile))
        model.page = .installed
        check("the Installed page builds", await hostAndWait(model) { () -> Bool in installed.loaded && !installed.loading })

        await agentChecks(model, check)

        let about: String = SystemInfo.asText(await model.aboutThisMac(hideNames: true))
        check("Hide Names removes the user name", about.contains("you@this-mac") && !about.contains(NSUserName()))
        let named: String = SystemInfo.asText(await model.aboutThisMac(hideNames: false))
        check("About This Mac lists memory and disk", named.contains("Memory") && named.contains("Disk"))
        // Hide Names just turned on, the re-read not done yet: the copy still has no names.
        model.copyAboutText(await model.aboutThisMac(hideNames: false), hideNames: true)
        let copied: String = Pasteboard.string() ?? ""
        check("Copy as Text hides names at once", copied.hasPrefix("About This Mac") && said("Copied About This Mac")
                && !copied.contains(NSUserName()) && !copied.contains(SystemInfo.hostName()))
        model.page = .browser
    }

    static func agentChecks(_ model: AppModel, _ check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        let home: URL = model.home
        func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        func said(_ text: String) -> Bool { model.toasts.contains { (t: Toast) -> Bool in t.text == text } }
        let project: URL = FileOps.canonical(home.appendingPathComponent("Proj"))
        let other: URL = FileOps.canonical(home.appendingPathComponent("Other"))
        try? fm.createDirectory(at: other, withIntermediateDirectories: true)
        try? fm.createDirectory(at: project, withIntermediateDirectories: true)
        try? "# Rules".write(to: project.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try? "mine".write(to: project.appendingPathComponent("CLAUDE.local.md"), atomically: true, encoding: .utf8)
        try? #"{"mcpServers":{"github":{"command":"npx","args":["gh"]}}}"#.write(to: project.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try? "theirs".write(to: other.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let logs: URL = home.appendingPathComponent(".claude/projects/p")
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let stamp: String = ISO8601DateFormatter().string(from: Date())
        try? #"{"timestamp":"\#(stamp)","message":{"id":"m","usage":{"input_tokens":40,"output_tokens":2}}}"#
            .write(to: logs.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

        model.page = .browser
        model.pane.navigate(to: project)
        let agents: AgentsModel = model.agents
        await model.loadAgents()
        await agents.select(project, home: home)
        check("AI Agents lists the current folder", agents.projects.contains(project) && agents.selected == project)
        check("AI Agents finds Claude's setup", agents.setup.map { (a: AgentFiles) -> Agent in a.agent } == [.claude])
        check("AI Agents lists the MCP server", agents.mcp.map { (m: MCPServer) -> String in m.name } == ["github"])
        check("AI Agents lists localhost ports", agents.ports.map { (p: ListeningPort) -> Int in p.port } == [3000, 8000])
        check("Claude Code usage counts today", agents.usage?.today == 42)

        agents.open("CLAUDE.md")
        let claudeMD: URL = project.appendingPathComponent("CLAUDE.md")
        agents.editor?.text = "# New"
        model.saveSetupFile()
        check("Save writes the setup file", read(claudeMD) == "# New" && agents.editor?.isEdited == false && said("Saved “CLAUDE.md”"))
        await model.undoLast()
        check("undoing Save restores it", read(claudeMD) == "# Rules" && agents.editor?.text == "# Rules")

        try? "outside".write(to: claudeMD, atomically: true, encoding: .utf8)
        agents.editor?.text = "# Mine"
        model.saveSetupFile()
        check("Save over an outside change says so", said("Saved “CLAUDE.md” over changes made elsewhere"))
        await model.undoLast()
        check("undo restores the outside change", read(claudeMD) == "outside" && agents.editor?.text == "outside")
        try? "# Rules".write(to: claudeMD, atomically: true, encoding: .utf8)
        try? Data(count: 3 << 20).write(to: project.appendingPathComponent("AGENTS.md"))
        agents.editor = nil
        agents.open("AGENTS.md")
        check("a huge setup file isn't previewed", agents.editor?.problem == "Too large to preview")
        agents.editor = nil

        model.planCopySetup(.claude, from: project, to: other)
        let paths: [String] = agents.copying?.plan.map { (i: SetupPlanItem) -> String in i.path } ?? []
        check("Copy Setup never plans personal files", agents.showCopy && paths == [".mcp.json", "CLAUDE.md"])
        agents.showCopy = false
        model.copySetup(replace: false)
        check("Copy Setup keeps theirs without Replace Them", read(other.appendingPathComponent("CLAUDE.md")) == "theirs"
                && exists(other.appendingPathComponent(".mcp.json")) && !exists(other.appendingPathComponent("CLAUDE.local.md")))
        await model.undoLast()
        check("undoing Copy Setup removes what it copied", !exists(other.appendingPathComponent(".mcp.json")))

        if let launchd = agents.ports.first(where: { (p: ListeningPort) -> Bool in p.pid == 1 }) { model.askStop(launchd) }
        check("Stop refuses pid 1", !agents.showStop && said("FileOS won't stop that process"))
        if let fake = agents.ports.first(where: { (p: ListeningPort) -> Bool in p.pid != 1 }) { model.askStop(fake) }
        check("Stop asks first", agents.showStop && agents.stopping?.port.port == 3000)
        agents.showStop = false
        await model.stopConfirmed() // pid 999999 can't exist on macOS (max 99998): nothing is signalled
        check("Stop reports a failure", said("Couldn't stop “devserver”"))
        model.page = .agents
        check("the AI Agents page builds", await hostAndWait(model) { () -> Bool in agents.loaded })
    }

    /// Hosts MainWindow like `hostedViews`, but keeps it up (up to 5 s) until `done` holds, so `.onAppear`
    /// and `.task` work runs.
    private static func hostAndWait(_ model: AppModel, _ done: () -> Bool) async -> Bool {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MainWindow().environment(model))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        host.layoutSubtreeIfNeeded()
        var ok: Bool = done()
        for _ in 0..<100 where !ok {
            try? await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            ok = done()
        }
        window.contentView = nil
        return ok
    }

    /// F15, F16, F5.15 at model level: no global hotkey, panel or status item is made here (only the app
    /// delegate makes those), so the runner's desktop is never touched.
    static func homeChecks(_ model: AppModel, _ check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        let home: URL = model.home
        func reopened() -> AppModel { AppModel(home: home, trashDir: model.trashDir) }
        func write(_ url: URL) { try? "x".write(to: url, atomically: true, encoding: .utf8) }
        check("greeting by hour", Greeting.text(hour: 5) == "Good morning" && Greeting.text(hour: 14) == "Good afternoon"
                && Greeting.text(hour: 20) == "Good evening")

        let inbox: URL = FileOps.canonical(home.appendingPathComponent("Inbox"))
        let shelfDir: URL = home.appendingPathComponent("ShelfTest")
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        try? fm.createDirectory(at: shelfDir, withIntermediateDirectories: true)
        let drop: URL = shelfDir.appendingPathComponent("drop.txt")
        let landed: URL = inbox.appendingPathComponent("drop.txt")
        write(drop)

        model.pinToShelf([inbox])
        model.pinToShelf([inbox])
        check("Pin to Drop Shelf keeps one pin", model.shelfPinned == [inbox])
        check("the pin survives a relaunch", reopened().shelfPinned.map { (u: URL) -> String in u.path } == [inbox.path])
        check("the pin shows the folder's count", AppModel.itemCount(inbox) == 0)

        await model.dropShelfMove([drop], to: inbox, copy: false)
        check("a shelf drop moves the file", !exists(drop) && exists(landed))
        check("the shelf result line", model.shelfResult?.text == "Just now: Moved “drop.txt” to Inbox"
                && model.shelfResult?.undoable == true)
        await model.undoLast()
        check("undoing the shelf move puts it back", exists(drop) && !exists(landed))
        await model.dropShelfMove([drop], to: inbox, copy: true)
        check("an ⌥ shelf drop copies", exists(drop) && exists(landed)
                && model.shelfResult?.text == "Just now: Copied “drop.txt” to Inbox")
        await model.undoLast()
        check("undoing the shelf copy removes only the copy", exists(drop) && !exists(landed))

        let other: URL = shelfDir.appendingPathComponent("other.txt")
        write(other)
        model.addToHolding([drop, other])
        model.addToHolding([drop])
        check("holding keeps each path once", model.holding.map { (u: URL) -> String in u.lastPathComponent } == ["drop.txt", "other.txt"])
        check("holding moves nothing", exists(drop) && exists(other))
        check("holding survives a relaunch", reopened().holding.map { (u: URL) -> String in u.path } == [drop.path, other.path])
        try? fm.removeItem(at: other)
        check("holding forgets files that are gone", reopened().holding.map { (u: URL) -> String in u.path } == [drop.path])
        await model.dropShelfMove(model.holding, to: inbox, copy: false)
        check("held files dropped on a pin move and leave holding", exists(landed) && model.holding.isEmpty)
        await model.undoLast()
        check("undoing it puts the files back in Holding", exists(drop) && !exists(landed)
                && model.holding.map { (u: URL) -> String in u.path } == [drop.path])
        model.addToHolding([drop])
        model.clearHolding()

        // A clash on a shelf drop asks the shared question; Keep Both, then undo, leaves the other file alone.
        write(landed)
        let clashing = Task { await model.dropShelfMove([drop], to: inbox, copy: false) }
        var asked = false
        for _ in 0..<150 where !asked {
            try? await Task.sleep(for: .milliseconds(20))
            asked = model.clashPrompt != nil
        }
        check("a shelf drop asks about a clash", asked)
        model.answerClash(.keepBoth, all: false)
        await clashing.value
        let both: URL = inbox.appendingPathComponent("drop 2.txt")
        check("Keep Both on a shelf drop keeps both", exists(both) && exists(landed) && !exists(drop)
                && model.shelfResult?.text == "Just now: Moved “drop.txt” to Inbox")
        await model.undoLast()
        check("undoing it moves only the dropped file back", exists(drop) && !exists(both) && exists(landed))
        try? fm.removeItem(at: landed)
        check("Clear empties holding for good", model.holding.isEmpty && reopened().holding.isEmpty && exists(drop))

        model.addToQuickAccess([inbox])
        check("Add to Quick Access saves the folder", reopened().quickAccess.map { (u: URL) -> String in u.path } == [inbox.path]
                && hasToast(model, "Added 1 item to Quick Access"))
        model.removeFromQuickAccess([inbox])
        check("Remove from Quick Access", model.quickAccess.isEmpty && reopened().quickAccess.isEmpty)
        model.addToQuickAccess([inbox])
        await model.undoLast()
        check("undoing Add to Quick Access", model.quickAccess.isEmpty)
        model.unpinFromShelf([inbox])
        check("Unpin only forgets the pin", reopened().shelfPinned.isEmpty && AppModel.isBrowsableFolder(inbox))

        model.setHomePart(.photoFrame, shown: false)
        let parts: [String: Bool] = reopened().homeParts
        check("Customize hides a Home part for good", !HomePart.photoFrame.isShown(in: parts) && HomePart.today.isShown(in: parts))
        model.page = .home
        check("the Home page builds", hostedViews(model).contains { (v: NSView) -> Bool in v is NSSplitView })
        model.page = .browser

        check("six quick actions by default", model.quickActions == QuickAction.defaults)
        model.setQuickActions([.addToHolding, .trash])
        check("the quick action order is saved", reopened().quickActions == [.addToHolding, .trash])
        model.showQuickActions(for: [drop])
        check("⌘. shows the quick actions", model.showQuickActions && model.quickActionTargets == [drop])
        model.performQuickAction(.addToHolding)
        check("a quick action runs on its item", !model.showQuickActions && model.holding.map { (u: URL) -> String in u.path } == [drop.path])
        model.clearHolding()
        model.setQuickActions(QuickAction.defaults)

        let seen = SeenCombo()
        model.dropShelfShortcutChanged = { (combo: KeyCombo) -> Bool in
            seen.combo = combo
            return seen.accepts
        }
        let bare: String? = model.setDropShelfShortcut(KeyCombo(key: "space", shift: true))
        check("a shelf shortcut needs ⌘, ⌥ or ⌃", bare != nil && seen.combo == nil)
        let taken: String? = model.setDropShelfShortcut(KeyCombo(key: "k", command: true))
        check("a shelf shortcut already in use is reported", taken != nil && seen.combo == nil)
        let wanted = KeyCombo(key: "space", option: true, control: true)
        let fine: String? = model.setDropShelfShortcut(wanted)
        check("a new shelf shortcut is saved and re-registered", fine == nil && seen.combo == wanted
                && reopened().dropShelfShortcut == wanted)
        seen.accepts = false
        let refused: String? = model.setDropShelfShortcut(KeyCombo(key: "d", command: true, option: true, control: true))
        check("a refused shelf shortcut keeps the old one", refused != nil && seen.combo == wanted
                && model.dropShelfShortcut == wanted && reopened().dropShelfShortcut == wanted)
        seen.accepts = true
        check("hotkey key codes", HotKey.keyCode("space") == 49 && HotKey.keyCode("k") == 40 && HotKey.keyCode("f5") == 96
                && HotKey.modifiers(KeyCombo(key: "space", option: true)) == 0x0800)
        model.setDropShelfShortcut(KeyCombo(key: "space", option: true))
        model.dropShelfShortcutChanged = nil

        model.pinToShelf([inbox])
        model.addToHolding([drop])
        let shelf = NSHostingView(rootView: DropShelfView(resized: {}).environment(model))
        shelf.layoutSubtreeIfNeeded()
        check("the Drop Shelf lays out", shelf.fittingSize.width >= DropShelfController.width - 1 && shelf.fittingSize.height > 100)
        let menu = NSHostingView(rootView: MenuBarPanel().environment(model))
        menu.layoutSubtreeIfNeeded()
        check("the menu bar panel lays out", menu.fittingSize.height > 50)
        model.unpinFromShelf([inbox])
        model.clearHolding()
    }

    /// F2.1 cloud drives and tags, F2.5 sidebar search and ⌃⌘S, F16.1 stickers.
    static func sidebarChecks(_ model: AppModel, _ check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        let home: URL = model.home
        func reopened() -> AppModel { AppModel(home: home, trashDir: model.trashDir) }
        try? fm.createDirectory(at: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: home.appendingPathComponent("Library/CloudStorage/Dropbox"), withIntermediateDirectories: true)
        model.refreshVolumes()
        let clouds: [String] = model.cloudDrives.map { (u: URL) -> String in SidebarView.cloudTitle(u) }
        check("Locations lists iCloud Drive, then cloud drives", clouds == ["iCloud Drive", "Dropbox"])

        model.openTag("Red")
        await model.tagSearch?.value
        check("a tag shows its files from Spotlight", model.page == .tag("Red") && !model.loadingTag
                && model.tagged.map { (u: URL) -> String in u.path } == ["/Users/Shared/red.txt"])
        check("the tag page builds", hostedViews(model).contains { (v: NSView) -> Bool in v is NSSplitView })
        model.openTag(nil)
        await model.tagSearch?.value
        check("All Tags… asks for every tag", model.page.title == "All Tags" && model.tagged.isEmpty)
        model.page = .browser

        let found: [String] = SidebarView.matches(model, "down").map { (e: SidebarEntry) -> String in e.title }
        check("sidebar search filters rows by name", found == ["Downloads"])
        check("sidebar search finds folded sections", SidebarView.matches(model, "trash").map { (e: SidebarEntry) -> String in e.title } == ["Trash"])
        check("⌃⌘S toggles the sidebar by default", Shortcuts.defaults["toggleSidebar"] == KeyCombo("Ctrl+Cmd+S")
                && Shortcuts.conflict(in: Shortcuts.defaults, action: "toggleSidebar", combo: KeyCombo("Ctrl+Cmd+S")!) == nil)
        model.showSidebar.toggle()
        check("hiding the sidebar still builds the window", !model.showSidebar && !hostedViews(model).isEmpty)
        model.showSidebar = true

        model.addSticker("⭐️")
        check("Add Sticker places one and says so", model.stickers.map { (s: Sticker) -> String in s.emoji } == ["⭐️"]
                && hasToast(model, "Added a sticker"))
        if let id = model.stickers.first?.id { model.moveSticker(id, x: 300, y: 120) }
        check("a dragged sticker stays put", reopened().stickers.first.map { (s: Sticker) -> Bool in s.x == 300 && s.y == 120 } == true)
        await model.undoLast()
        check("undoing Add Sticker takes it off", model.stickers.isEmpty && reopened().stickers.isEmpty)
        model.addSticker("🚀")
        if let id = model.stickers.first?.id { model.removeSticker(id) }
        check("Remove Sticker says so", model.stickers.isEmpty && hasToast(model, "Removed a sticker"))
        await model.undoLast()
        check("undoing Remove Sticker puts it back", model.stickers.map { (s: Sticker) -> String in s.emoji } == ["🚀"])
        model.page = .home
        check("Home builds with stickers", hostedViews(model).contains { (v: NSView) -> Bool in v is NSSplitView })
        model.setHomePart(.stickers, shown: false)
        check("Customize hides stickers", !HomePart.stickers.isShown(in: reopened().homeParts))
        model.setHomePart(.stickers, shown: true)
        model.page = .browser
    }

    /// F17, F1.5, F1.7, F1.10 at model level, plus the Settings and welcome views building offscreen.
    static func settingsChecks(_ model: AppModel, _ check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        let home: URL = model.home
        let docs: URL = FileOps.canonical(home.appendingPathComponent("Documents"))
        let stateFile: URL = home.appendingPathComponent("Library/Application Support/FileOS/state.json")
        func reopened() -> AppModel { AppModel(home: home, trashDir: model.trashDir) }

        check("settings appearance .dark maps to ColorScheme.dark", AppSettings.Appearance.dark.colorScheme == .dark
                && AppSettings.Appearance.light.colorScheme == .light && AppSettings.Appearance.system.colorScheme == nil)
        check("no welcome or What's New in the self-test", !model.showWelcome && !model.showWhatsNew)
        check("sounds are off by default", model.settings.sound == .off && Sounds.name(.off) == nil)

        var applied: AppSettings?
        model.settingsApplied = { (s: AppSettings) in applied = s }
        model.settings.motion = .zoom
        let stored: AppSettings = Store(url: stateFile).get("settings", default: AppSettings())
        check("a settings change is saved at once", stored.motion == .zoom)
        check("a settings change is applied at once", applied?.motion == .zoom)
        check("settings survive a relaunch", reopened().settings.motion == .zoom)
        model.settingsApplied = nil
        model.settings.motion = .quiet
        check("accent colours", AppSettings.color(accent: "mac") == nil && AppSettings.color(accent: "#FF0000") != nil)

        model.settings.downloadsPath = docs.path
        check("Downloads folder follows Settings", model.downloadsURL == docs)
        model.settings.downloadsPath = ""

        // ⌫ alone trashes only when allowed (F17.2).
        let victim: URL = docs.appendingPathComponent("backspace.txt")
        try? "x".write(to: victim, atomically: true, encoding: .utf8)
        model.page = .browser
        model.pane.navigate(to: docs)
        await model.settled()
        model.pane.selection = [victim.path]
        check("⌫ alone does nothing by default", !press(model, 51, "\u{7F}") && fm.fileExists(atPath: victim.path))
        model.settings.backspaceTrashes = true
        let trashed: Bool = press(model, 51, "\u{7F}")
        check("⌫ alone trashes when allowed", trashed && !fm.fileExists(atPath: victim.path))
        await model.undoLast()
        check("⌫ trash is undoable", fm.fileExists(atPath: victim.path))
        model.settings.backspaceTrashes = false

        // Shortcuts (F17.5).
        let combo: KeyCombo = KeyCombo("Ctrl+Alt+Cmd+L")!
        model.setShortcut("viewList", combo)
        let user: [String: KeyCombo] = Store(url: stateFile).get("shortcuts", default: [String: KeyCombo]())
        check("a recorded shortcut is used and saved", model.shortcuts["viewList"] == combo && user["viewList"] == combo)
        model.setShortcut("viewList", .none)
        check("⌫ removes a shortcut", model.shortcuts["viewList"]?.isNone == true)
        let cmd2: KeyCombo = KeyCombo("Cmd+2")!
        check("a clash names the other command", Shortcuts.conflict(in: model.shortcuts, action: "viewList", combo: cmd2) == "viewIcons")
        let used: String? = model.useShortcutHere("viewList", cmd2, from: "viewIcons")
        check("Use It Here moves the shortcut", used == nil && model.shortcuts["viewList"] == cmd2
                && model.shortcuts["viewIcons"]?.isNone == true)
        model.setShortcut("copy", KeyCombo("Cmd+J")!)
        check("fixed shortcuts can't change", model.shortcuts["copy"] == Shortcuts.defaults["copy"])
        check("the Drop Shelf shortcut must be global", model.setShortcut("dropShelf", .none) != nil)
        check("Restore Defaults", model.restoreDefaultShortcuts() == nil && model.shortcuts == Shortcuts.defaults)
        check("recorded keys map to combos", HotKey.key(forCode: 40) == "k" && HotKey.key(forCode: 96) == "f5")

        // F1.7: panes and view come back.
        model.pane.navigate(to: docs)
        model.setLayout(.sideBySide)
        model.saveSession()
        let again: AppModel = reopened()
        check("panes are restored on relaunch", again.layout == .sideBySide && again.panes.first?.url == docs)
        model.settings.startInLastFolder = false
        check("start in the last folder can be turned off", reopened().layout == .one)
        model.settings.startInLastFolder = true
        model.setLayout(.one)

        // F1.5 / F1.10.
        model.finishWelcome()
        check("Start using FileOS ends the welcome", model.settings.welcomed && !model.showWelcome
                && !Release.showsWhatsNew(model.settings))
        model.showWhatsNew = true
        model.closeWhatsNew()
        check("What's New closes and is remembered", !model.showWhatsNew && model.settings.whatsNewSeen == Release.version)

        check("Settings builds", hosts(AnyView(SettingsView().environment(model)), width: 560, height: 640))
        check("welcome builds", hosts(AnyView(WelcomeView(steps: WelcomeStep.allCases).environment(model)), width: 540, height: 460))
        check("What's New builds", hosts(AnyView(WhatsNewView().environment(model)), width: 440, height: 300))
        check("folder motion is off for none", AppSettings.Motion.none.transition(reduceMotion: false) == .none)
    }

    /// Lays `view` out offscreen; true when it produced a view tree.
    private static func hosts(_ view: AnyView, width: CGFloat, height: CGFloat) -> Bool {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        let built: Bool = !host.subviews.isEmpty || host.fittingSize.height > 0
        window.contentView = nil
        return built
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

/// What the app would have re-registered as the global shortcut.
@MainActor
private final class SeenCombo {
    var combo: KeyCombo?
    /// What the system answers when asked to register.
    var accepts = true
}

/// Canned answers for the self-test, so it runs no real git, brew, lsof or system tools.
struct SelfTestRunner: CommandRunner {
    static let brew = """
    {"formulae":[
      {"name":"node","installed":[{"version":"24.1.0","installed_on_request":true}],"dependencies":["icu4c","zlib"]},
      {"name":"node@24","installed":[{"version":"24.0.0","installed_on_request":true}],"dependencies":[]},
      {"name":"icu4c","installed":[{"version":"76.1","installed_on_request":false}],"dependencies":[]},
      {"name":"oldlib","installed":[{"version":"1.0","installed_on_request":false}],"dependencies":[]},
      {"name":"zlib","installed":[{"version":"1.3","installed_on_request":false}],"dependencies":[]}
    ],"casks":[{"token":"firefox","installed":"133.0"}]}
    """
    static let lsof = """
    COMMAND     PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
    devserver 999999 me    23u  IPv4 0x1      0t0  TCP 127.0.0.1:3000 (LISTEN)
    launchd       1 root   4u  IPv4 0x2      0t0  TCP *:8000 (LISTEN)
    """

    func run(_ exe: String, _ args: [String], timeout: TimeInterval) async throws -> (status: Int32, stdout: String) {
        switch (exe as NSString).lastPathComponent {
        case "xcode-select": return (0, "/Library/Developer/CommandLineTools\n")
        case "git":
            if args.contains("config") { return (0, "local\0core.bare\nfalse\0") }
            return args.contains("status") ? (0, "## main...origin/main\0 M a.txt\0?? b.txt\0") : (128, "")
        case "brew": return (0, Self.brew)
        case "lsof": return (0, Self.lsof)
        case "sw_vers": return (0, "ProductName:\tmacOS\nProductVersion:\t15.1\nBuildVersion:\t24B83\n")
        case "pmset": return (0, "Now drawing from 'AC Power'\n")
        case "fdesetup": return (0, "FileVault is On.\n")
        case "csrutil": return (0, "System Integrity Protection status: enabled.\n")
        case "spctl": return (0, "assessments enabled\n")
        case "mdfind": return (0, args == ["kMDItemUserTags == 'Red'"] ? "/Users/Shared/red.txt\n" : "")
        default: throw CommandError.notFound(exe)
        }
    }
}
