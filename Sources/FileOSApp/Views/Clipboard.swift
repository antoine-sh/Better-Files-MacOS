import AppKit

/// What ⌘C / ⌘X put on the clipboard. The general pasteboard holds the file URLs too (so other apps
/// can paste them); `changeCount` tells whether another app has replaced them since.
struct Clipboard: Equatable {
    var urls: [URL]
    var cut: Bool
    var changeCount: Int
}

@MainActor
enum Pasteboard {
    /// The self-test swaps in a private named pasteboard so it never touches the user's clipboard.
    static var board: NSPasteboard = .general

    static var changeCount: Int { board.changeCount }

    static func clear() { board.clearContents() }

    /// Returns the pasteboard's change count after writing.
    static func write(_ urls: [URL]) -> Int {
        let pb = board
        pb.clearContents()
        pb.writeObjects(urls.map { (u: URL) -> NSURL in u as NSURL })
        return pb.changeCount
    }

    static func write(_ text: String) {
        let pb = board
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func fileURLs() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects: [Any] = board.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { (o: Any) -> URL? in o as? URL }
    }
}

/// Our Edit menu replaces the system Cut/Copy/Paste/Select All/Undo items, so while a text field is
/// being edited (path bar, rename, filter) those commands are handed to it instead of the files.
@MainActor
enum TextEditing {
    static var isActive: Bool { NSApp.keyWindow?.firstResponder is NSText }

    /// Sends `action` to the field being edited; false when no field is being edited.
    static func forward(_ action: Selector) -> Bool {
        guard isActive else { return false }
        return NSApp.sendAction(action, to: nil, from: nil)
    }

    static let copy = #selector(NSText.copy(_:))
    static let cut = #selector(NSText.cut(_:))
    static let paste = #selector(NSText.paste(_:))
    static let selectAll = #selector(NSText.selectAll(_:))
    static let undo = Selector(("undo:"))
    static let redo = Selector(("redo:"))
}
