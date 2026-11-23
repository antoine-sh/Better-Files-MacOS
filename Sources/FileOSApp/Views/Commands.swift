import SwiftUI
import AppKit
import FileOSCore

extension KeyCombo {
    var modifiers: EventModifiers {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return m
    }

    private var functionKeyNumber: Int? {
        guard key.count > 1, key.hasPrefix("f") else { return nil }
        return Int(key.dropFirst())
    }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "space": return .space
        case "return": return .return
        case "escape": return .escape
        case "tab": return .tab
        case "delete": return .delete
        case "up": return .upArrow
        case "down": return .downArrow
        case "left": return .leftArrow
        case "right": return .rightArrow
        default:
            if let n = functionKeyNumber {
                // AppKit's NSF1FunctionKey is U+F704; menus accept these private-use characters.
                guard let scalar = Unicode.Scalar(UInt32(0xF703 + n)) else { return nil }
                return KeyEquivalent(Character(scalar))
            }
            guard key.count == 1, let c = key.first else { return nil }
            return KeyEquivalent(c)
        }
    }

    /// nil for bare keys (Return, Space, Tab, arrows…): as menu shortcuts they would steal those keys
    /// from text fields, so the file views handle them with onKeyPress instead.
    var menuShortcut: KeyboardShortcut? {
        guard let equivalent = keyEquivalent else { return nil }
        if modifiers.isEmpty, functionKeyNumber == nil { return nil }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }
}

/// A menu item whose shortcut comes from the (user-editable) shortcut map.
struct MenuItem: View {
    let title: String
    let id: String
    let model: AppModel
    var disabled = false
    let action: @MainActor () -> Void

    var body: some View {
        Button(title, action: { action() })
            .keyboardShortcut(model.shortcuts[id]?.menuShortcut)
            .disabled(disabled)
    }
}

struct FileOSCommands: Commands {
    let model: AppModel

    var body: some Commands {
        FileMenuCommands(model: model)
        EditMenuCommands(model: model)
        ViewMenuCommands(model: model)
        GoMenuCommands(model: model)
    }
}

private struct FileMenuCommands: Commands {
    let model: AppModel
    private var targets: [URL] { model.targets }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            MenuItem(title: "New Folder", id: "newFolder", model: model, action: { model.newFolder() })
        }
        CommandGroup(after: .newItem) {
            Divider()
            itemCommands
            Divider()
            placeCommands
        }
    }

    @ViewBuilder private var itemCommands: some View {
        MenuItem(title: "Rename…", id: "renameF2", model: model, disabled: targets.isEmpty, action: { rename() })
        MenuItem(title: "Duplicate", id: "duplicate", model: model, disabled: targets.isEmpty, action: { model.duplicate(model.targets) })
        MenuItem(title: "Make Alias", id: "makeAlias", model: model, disabled: targets.isEmpty, action: { model.makeAlias(model.targets) })
        MenuItem(title: "Move to Trash", id: "trash", model: model, disabled: targets.isEmpty, action: { trash() })
        MenuItem(title: "Empty Trash…", id: "emptyTrash", model: model, action: { model.askEmptyTrash() })
    }

    @ViewBuilder private var placeCommands: some View {
        MenuItem(title: "Show in Finder", id: "showInFinder", model: model, action: { model.showInFinder(model.targets) })
        MenuItem(title: "Copy Path", id: "copyPath", model: model, action: { model.copyPath(model.targets) })
        MenuItem(title: "Add to Sidebar", id: "addToSidebar", model: model, action: { model.addToSidebar(model.targets) })
        MenuItem(title: "AirDrop…", id: "airDrop", model: model, disabled: !model.canAirDrop(targets), action: { model.airDrop(model.targets) })
        MenuItem(title: "Open in Terminal", id: "openInTerminal", model: model, action: { model.openIn(kind: .terminal) })
        MenuItem(title: "Open in Editor", id: "openInEditor", model: model, action: { model.openIn(kind: .editor) })
        Menu("Commander Keys") {
            MenuItem(title: "Edit", id: "editF4", model: model, action: { model.openIn(kind: .editor) })
            MenuItem(title: "New Folder", id: "newFolderF7", model: model, action: { model.newFolder() })
            MenuItem(title: "Move to Trash", id: "trashF8", model: model, disabled: targets.isEmpty, action: { trashF8() })
        }
    }

    private func rename() { model.beginRename() }

    /// F8 while typing in a field does nothing (only ⌘⌫ has a text-editing meaning).
    private func trashF8() {
        if TextEditing.isActive { return }
        model.trash(model.targets)
    }
    private func trash() {
        // ⌘⌫ in a text field deletes to the line start; never trash files from there.
        if TextEditing.forward(#selector(NSResponder.deleteToBeginningOfLine(_:))) { return }
        model.trash(model.targets)
    }
}

/// Cut/Copy/Paste/Select All/Undo act on files, except while a text field is being edited.
private struct EditMenuCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            MenuItem(title: "Undo", id: "undo", model: model, action: { undo() })
            // Files have no redo; text fields keep theirs.
            MenuItem(title: "Redo", id: "redo", model: model, action: { redo() })
        }
        CommandGroup(replacing: .pasteboard) {
            MenuItem(title: "Cut", id: "cut", model: model, action: { cut() })
            MenuItem(title: "Copy", id: "copy", model: model, action: { copy() })
            MenuItem(title: "Paste", id: "paste", model: model, action: { paste(move: false) })
            MenuItem(title: "Move Item Here", id: "moveHere", model: model, action: { paste(move: true) })
            MenuItem(title: "Select All", id: "selectAll", model: model, action: { selectAll() })
        }
    }

    private func undo() {
        if !TextEditing.forward(TextEditing.undo) { model.performUndo() }
    }

    private func redo() { _ = TextEditing.forward(TextEditing.redo) }

    private func cut() {
        if !TextEditing.forward(TextEditing.cut) { model.copy(model.targets, cut: true) }
    }

    private func copy() {
        if !TextEditing.forward(TextEditing.copy) { model.copy(model.targets) }
    }

    private func paste(move: Bool) {
        if !move, TextEditing.forward(TextEditing.paste) { return }
        Task { await model.paste(move: move) }
    }

    private func selectAll() {
        if !TextEditing.forward(TextEditing.selectAll) { model.pane.selectAll() }
    }
}

private struct ViewMenuCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            modeCommands
            Divider()
            arrangeCommands
            Divider()
            showCommands
            Divider()
            PaneCommands(model: model)
            Divider()
        }
    }

    @ViewBuilder private var modeCommands: some View {
        MenuItem(title: "as List", id: "viewList", model: model, action: { model.setView(.list) })
        MenuItem(title: "as Icons", id: "viewIcons", model: model, action: { model.setView(.icons) })
        MenuItem(title: "as Columns", id: "viewColumns", model: model, action: { model.setView(.columns) })
        MenuItem(title: "Next View", id: "viewF3", model: model, action: { nextView() })
    }

    @ViewBuilder private var arrangeCommands: some View {
        MenuItem(title: "Bigger", id: "sizeUp", model: model, disabled: model.iconSize == .large, action: { model.resize(by: 1) })
        MenuItem(title: "Smaller", id: "sizeDown", model: model, disabled: model.iconSize == .tiny, action: { model.resize(by: -1) })
        Menu("Group By") {
            MenuItem(title: "Kind", id: "groupKind", model: model, action: { model.setGroup(.kind) })
            MenuItem(title: "Date Added", id: "groupDate", model: model, action: { model.setGroup(.date) })
            MenuItem(title: "None", id: "groupNone", model: model, action: { model.setGroup(.none) })
        }
        Menu("Sort By") {
            MenuItem(title: "Name", id: "sortName", model: model, action: { model.setSort(.name) })
            MenuItem(title: "Date Modified", id: "sortModified", model: model, action: { model.setSort(.modified) })
            MenuItem(title: "Files First", id: "filesFirst", model: model, action: { model.toggleFilesFirst() })
        }
    }

    @ViewBuilder private var showCommands: some View {
        MenuItem(title: model.showPreview ? "Hide Preview" : "Show Preview", id: "previewPane", model: model,
                 action: { model.togglePreview() })
        MenuItem(title: model.showHidden ? "Hide Hidden Files" : "Show Hidden Files", id: "toggleHidden", model: model,
                 action: { model.toggleHidden() })
        MenuItem(title: "Filter", id: "filter", model: model, action: { filter() })
    }

    private func nextView() {
        let all: [ViewMode] = ViewMode.allCases
        let i: Int = all.firstIndex(of: model.pane.view) ?? 0
        model.setView(all[(i + 1) % all.count])
    }

    private func filter() {
        model.page = .browser
        model.filterShown = true
    }
}

private struct GoMenuCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Go") {
            historyCommands
            Divider()
            placeCommands
            Divider()
            MenuItem(title: "Search…", id: "search", model: model, action: { model.openSearch() })
            MenuItem(title: "Go to Folder…", id: "goToFolder", model: model, action: { editPath() })
            MenuItem(title: "Type a Path", id: "typePath", model: model, action: { editPath() })
        }
    }

    @ViewBuilder private var historyCommands: some View {
        MenuItem(title: "Back", id: "back", model: model, disabled: !model.pane.canGoBack, action: { back() })
        MenuItem(title: "Forward", id: "forward", model: model, disabled: !model.pane.canGoForward, action: { forward() })
        MenuItem(title: "Enclosing Folder", id: "enclosingFolder", model: model, disabled: !model.pane.canGoUp, action: { up() })
        MenuItem(title: "Open", id: "open", model: model, action: { model.openSelection() })
    }

    @ViewBuilder private var placeCommands: some View {
        MenuItem(title: "Documents", id: "goDocuments", model: model, action: { model.goTo("Documents") })
        MenuItem(title: "Desktop", id: "goDesktop", model: model, action: { model.goTo("Desktop") })
        MenuItem(title: "Downloads", id: "goDownloads", model: model, action: { model.goTo("Downloads") })
        MenuItem(title: "Home", id: "goHome", model: model, action: { model.goTo("Home") })
        MenuItem(title: "Applications", id: "goApplications", model: model, action: { model.goTo("Applications") })
        MenuItem(title: "iCloud Drive", id: "goICloud", model: model, action: { model.goTo("iCloud Drive") })
    }

    private func back() {
        model.page = .browser
        model.pane.back()
    }

    private func forward() {
        model.page = .browser
        model.pane.forward()
    }

    private func up() {
        model.page = .browser
        model.pane.up()
    }

    private func editPath() {
        model.page = .browser
        model.editingPath = true
    }
}

/// F8: two panes, layouts and the commander transfer keys.
private struct PaneCommands: View {
    let model: AppModel
    private var several: Bool { model.panes.count > 1 }

    var body: some View {
        MenuItem(title: several ? "Single Pane" : "Dual Pane", id: "dualPane", model: model, action: { model.toggleDualPane() })
        MenuItem(title: "Switch Pane", id: "switchPane", model: model, disabled: !several, action: { model.switchPane() })
        MenuItem(title: "Swap Panes", id: "swapPanes", model: model, disabled: !several, action: { model.swapPanes() })
        Menu("Layout") {
            ForEach(model.savedLayouts) { (saved: SavedLayout) in
                Button(saved.name, action: { model.applyLayout(saved) })
            }
            if !model.savedLayouts.isEmpty { Divider() }
            ForEach(PaneLayout.allCases, id: \.self) { (layout: PaneLayout) in
                MenuItem(title: layout.title, id: layout.shortcutID, model: model, action: { model.setLayout(layout) })
            }
            Divider()
            Button("Save Layout…", action: { model.showSaveLayout = true })
        }
        MenuItem(title: "Copy to Other Pane", id: "copyToOtherPane", model: model, disabled: !several, action: { send(.copy) })
        MenuItem(title: "Move to Other Pane", id: "moveToOtherPane", model: model, disabled: !several, action: { send(.move) })
    }

    /// F5 / F6 do nothing while typing in a field.
    private func send(_ mode: TransferMode) {
        if TextEditing.isActive { return }
        Task { await model.transferToOtherPane(mode) }
    }
}
