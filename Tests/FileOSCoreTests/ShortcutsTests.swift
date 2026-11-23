import XCTest
@testable import FileOSCore

final class ShortcutsTests: XCTestCase {
    func testParsesAndDescribes() {
        XCTAssertEqual(KeyCombo("Cmd+Shift+N")?.description, "⇧⌘N")
        XCTAssertEqual(KeyCombo("Ctrl+Alt+Cmd+1")?.description, "⌃⌥⌘1")
        XCTAssertEqual(KeyCombo("F5")?.description, "F5")
        XCTAssertEqual(KeyCombo("Alt+Space")?.description, "⌥Space")
        XCTAssertEqual(KeyCombo("Cmd++")?.description, "⌘+")
        XCTAssertEqual(KeyCombo("Cmd+Delete")?.description, "⌘⌫")
        XCTAssertEqual(KeyCombo("cmd+up")?.description, "⌘↑")
        let combo = KeyCombo("Cmd+Shift+N")
        XCTAssertEqual(combo, KeyCombo(key: "n", command: true, shift: true))
    }

    func testRejectsGarbage() {
        XCTAssertNil(KeyCombo(""))
        XCTAssertNil(KeyCombo("Cmd+"))
        XCTAssertNil(KeyCombo("Cmd+Shift"))
        XCTAssertNil(KeyCombo("Hyper+N"))
        XCTAssertNil(KeyCombo("Cmd+NN"))
    }

    func testCodableRoundTrip() throws {
        let combo = KeyCombo("Ctrl+Alt+Cmd+1")!
        let data = try JSONEncoder().encode(combo)
        XCTAssertEqual(try JSONDecoder().decode(KeyCombo.self, from: data), combo)
    }

    func testDefaultsAreUniqueAndCoverTheKeyMap() {
        var seen: [KeyCombo: String] = [:]
        for (action, combo) in Shortcuts.defaults {
            if let other = seen[combo] { XCTFail("\(action) and \(other) share \(combo)") }
            seen[combo] = action
        }
        // Spot-check FEATURES.md §18 entries.
        let expected: [String: String] = [
            "viewList": "⌘1", "viewIcons": "⌘2", "viewColumns": "⌘3", "groupKind": "⌃⌘K", "sortName": "⌃⌥⌘1",
            "previewPane": "⇧⌘P", "toggleHidden": "⇧⌘.", "newFolder": "⇧⌘N", "moveHere": "⌥⌘V",
            "copyPath": "⌥⌘C", "makeAlias": "⌃⌘A", "trash": "⌘⌫", "goDownloads": "⌥⌘L", "copyToOtherPane": "F5",
            "dropShelf": "⌥Space", "workspace9": "⌃9", "layout6": "⌥⌘6", "pinnedWorkspace6": "⌃⌥6",
        ]
        for (action, text) in expected { XCTAssertEqual(Shortcuts.defaults[action]?.description, text, action) }
    }

    func testFixedIdsExist() {
        for id in Shortcuts.fixed { XCTAssertNotNil(Shortcuts.defaults[id], id) }
    }

    func testConflict() {
        let map = Shortcuts.defaults
        XCTAssertEqual(Shortcuts.conflict(in: map, action: "copyPath", combo: KeyCombo("Shift+Cmd+N")!), "newFolder")
        XCTAssertNil(Shortcuts.conflict(in: map, action: "newFolder", combo: KeyCombo("Shift+Cmd+N")!))
        XCTAssertNil(Shortcuts.conflict(in: map, action: "copyPath", combo: KeyCombo("Ctrl+Alt+Cmd+Z")!))
    }

    func testMergedAppliesUserOverridesExceptFixedAndUnknown() {
        let user: [String: KeyCombo] = [
            "copyPath": KeyCombo("Ctrl+Alt+Cmd+Z")!,
            "copy": KeyCombo("Ctrl+C")!,
            "nonsense": KeyCombo("Ctrl+Q")!,
        ]
        let merged = Shortcuts.merged(user)
        XCTAssertEqual(merged["copyPath"], KeyCombo("Ctrl+Alt+Cmd+Z"))
        XCTAssertEqual(merged["copy"], Shortcuts.defaults["copy"])
        XCTAssertNil(merged["nonsense"])
        XCTAssertEqual(merged.count, Shortcuts.defaults.count)
    }

    func testPeekStaysOnSpace() {
        // F17.5: Space is fixed; the pane's key monitor handles it.
        XCTAssertEqual(Shortcuts.merged(["peek": KeyCombo("Cmd+P")!])["peek"], KeyCombo("Space"))
    }
}
