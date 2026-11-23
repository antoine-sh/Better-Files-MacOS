import Foundation

/// One keyboard shortcut. `key` is a single lowercased character ("n", "1", "+", ".") or a named key
/// ("space", "return", "escape", "tab", "delete", "up", "down", "left", "right", "f1"…"f12").
public struct KeyCombo: Codable, Hashable, Sendable, CustomStringConvertible {
    public var key: String
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key; self.command = command; self.shift = shift; self.option = option; self.control = control
    }

    static let namedKeys: [String: String] = {
        var keys = ["space": "Space", "return": "↩", "enter": "↩", "escape": "⎋", "esc": "⎋", "tab": "⇥",
                    "delete": "⌫", "backspace": "⌫", "up": "↑", "down": "↓", "left": "←", "right": "→"]
        for n in 1...12 { keys["f\(n)"] = "F\(n)" }
        return keys
    }()

    private static let aliases = ["enter": "return", "esc": "escape", "backspace": "delete"]

    /// Parses "Cmd+Shift+N", "Ctrl+Alt+Cmd+1", "F5", "Alt+Space", "Cmd++".
    public init?(_ s: String) {
        var text = s.trimmingCharacters(in: .whitespaces)
        var key: String?
        if text.hasSuffix("++") || text == "+" { // the "+" key itself
            key = "+"
            text = String(text.dropLast(text == "+" ? 1 : 2))
        }
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map { String($0).lowercased() }
        if parts == [""] { parts = [] }
        if key == nil {
            guard let last = parts.popLast(), !last.isEmpty else { return nil }
            let name = Self.aliases[last] ?? last
            guard name.count == 1 || Self.namedKeys[name] != nil else { return nil }
            key = name
        }
        self.init(key: key!)
        for p in parts {
            switch p {
            case "cmd", "command", "⌘": command = true
            case "shift", "⇧": shift = true
            case "alt", "opt", "option", "⌥": option = true
            case "ctrl", "control", "⌃": control = true
            default: return nil
            }
        }
    }

    /// macOS menu order: ⌃⌥⇧⌘ then the key.
    public var description: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        return s + (Self.namedKeys[key] ?? key.uppercased())
    }
}

public enum Shortcuts {
    /// Action id → default combo, covering FEATURES.md §18. Context-only keys (Peek arrows, Drop Shelf 1–9,
    /// path-bar Tab/↑↓, Esc) are handled by the views that own them and are not rebindable.
    public static let defaults: [String: KeyCombo] = {
        var map: [String: String] = [
            // View
            "viewList": "Cmd+1", "viewIcons": "Cmd+2", "viewColumns": "Cmd+3",
            "sizeUp": "Cmd++", "sizeDown": "Cmd+-",
            "groupKind": "Ctrl+Cmd+K", "groupDate": "Ctrl+Cmd+D", "groupNone": "Ctrl+Cmd+0",
            "sortName": "Ctrl+Alt+Cmd+1", "sortModified": "Ctrl+Alt+Cmd+3",
            "previewPane": "Shift+Cmd+P", "insights": "Alt+Cmd+I", "toggleHidden": "Shift+Cmd+.",
            "toggleSidebar": "Ctrl+Cmd+S", "filter": "Cmd+F", "viewF3": "F3",
            // Go
            "back": "Cmd+[", "forward": "Cmd+]", "enclosingFolder": "Cmd+Up", "typePath": "Cmd+L",
            "goToFolder": "Shift+Cmd+G", "open": "Cmd+Down", "search": "Cmd+K",
            "goDocuments": "Shift+Cmd+O", "goDownloads": "Alt+Cmd+L", "goDesktop": "Shift+Cmd+D",
            "goHome": "Shift+Cmd+H", "goApplications": "Shift+Cmd+A", "goICloud": "Shift+Cmd+I",
            "bookmarks": "Alt+Cmd+B", "smartClean": "Alt+Cmd+K",
            // Files
            "peek": "Space", "quickLook": "Cmd+Y", "rename": "Return", "renameF2": "F2", "newFolder": "Shift+Cmd+N",
            "newFolderF7": "F7", "copy": "Cmd+C", "cut": "Cmd+X", "paste": "Cmd+V", "moveHere": "Alt+Cmd+V",
            "selectAll": "Cmd+A", "copyPath": "Alt+Cmd+C", "makeAlias": "Ctrl+Cmd+A", "airDrop": "Shift+Cmd+R",
            "showInFinder": "Cmd+R", "addToSidebar": "Ctrl+Cmd+T", "openInTerminal": "Alt+Shift+Cmd+T",
            "openInEditor": "Alt+Shift+Cmd+E", "editF4": "F4", "tidy": "Alt+Cmd+T",
            "trash": "Cmd+Delete", "trashF8": "F8", "undo": "Cmd+Z", "redo": "Shift+Cmd+Z", "quickActions": "Cmd+.",
            // Two panes
            "dualPane": "Cmd+D", "switchPane": "Tab", "copyToOtherPane": "F5", "moveToOtherPane": "F6",
            "swapPanes": "Cmd+U",
            // Workspaces & bookmarks
            "newWorkspace": "Alt+Cmd+N", "addBookmark": "Alt+Shift+Cmd+N", "bookmarkList": "Shift+Cmd+L",
            "bookmarksPage": "Ctrl+Alt+Cmd+B",
            // App
            "dropShelf": "Alt+Space", "settings": "Cmd+,", "quit": "Cmd+Q",
        ]
        for n in 1...6 { map["layout\(n)"] = "Alt+Cmd+\(n)"; map["pinnedWorkspace\(n)"] = "Ctrl+Alt+\(n)" }
        for n in 1...9 { map["workspace\(n)"] = "Ctrl+\(n)" }
        return map.mapValues { KeyCombo($0)! }
    }()

    /// Shortcuts users can't rebind: system-standard ones, and Space for Peek (F17.5), which the
    /// pane's key monitor handles directly.
    public static let fixed: Set<String> = ["copy", "cut", "paste", "selectAll", "undo", "redo", "settings", "quit", "peek"]

    /// The other action already using `combo`, if any.
    public static func conflict(in map: [String: KeyCombo], action: String, combo: KeyCombo) -> String? {
        map.filter { $0.key != action && $0.value == combo }.keys.sorted().first
    }

    /// Defaults with the user's overrides applied; overrides of fixed or unknown actions are ignored.
    public static func merged(_ user: [String: KeyCombo]) -> [String: KeyCombo] {
        var map = defaults
        for (action, combo) in user where map[action] != nil && !fixed.contains(action) { map[action] = combo }
        return map
    }
}
