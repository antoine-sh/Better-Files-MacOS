import XCTest
@testable import FileOSCore

final class HomeTests: XCTestCase {
    func testGreetingByHour() {
        XCTAssertEqual(Greeting.text(hour: 5), "Good morning")
        XCTAssertEqual(Greeting.text(hour: 14), "Good afternoon")
        XCTAssertEqual(Greeting.text(hour: 20), "Good evening")
        XCTAssertEqual(Greeting.text(hour: 11), "Good morning")
        XCTAssertEqual(Greeting.text(hour: 12), "Good afternoon")
        XCTAssertEqual(Greeting.text(hour: 17), "Good afternoon")
        XCTAssertEqual(Greeting.text(hour: 18), "Good evening")
        XCTAssertEqual(Greeting.text(hour: 2), "Good evening")
    }

    func testHomePartsDefaultToShown() {
        XCTAssertTrue(HomePart.photoFrame.isShown(in: [:]))
        XCTAssertFalse(HomePart.photoFrame.isShown(in: ["photoFrame": false]))
        XCTAssertEqual(HomePart.allCases.map(\.title), ["World Clock", "Today", "Disk Space", "Downloads Inbox",
                                                        "Photo Frame", "Pinned Folder", "Recent Files"])
    }

    func testRecentsNewestFirstSkippingHidden() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        touch(dir, "old.txt", modified: now.addingTimeInterval(-300))
        touch(dir, "new.txt", modified: now.addingTimeInterval(-10))
        touch(dir, "mid.txt", modified: now.addingTimeInterval(-100))
        touch(dir, ".hidden", modified: now)
        try! FileManager.default.createDirectory(at: dir.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        let files = Recents.latest(in: [dir, dir.appendingPathComponent("missing")], limit: 2, includeFolders: false)
        XCTAssertEqual(files.map(\.lastPathComponent), ["new.txt", "mid.txt"])
        let all = Recents.latest(in: [dir], limit: 10, includeFolders: true)
        XCTAssertTrue(all.map(\.lastPathComponent).contains("Folder"))
        XCTAssertEqual(all.count, 4)
    }

    func testQuickActionsOrder() {
        XCTAssertEqual(QuickAction.ordered(nil), QuickAction.defaults)
        XCTAssertEqual(QuickAction.defaults.count, 6)
        // Unknown ids and repeats are dropped; at most six.
        XCTAssertEqual(QuickAction.ordered(["trash", "nope", "trash", "rename"]), [.trash, .rename])
        let many = QuickAction.allCases.map(\.rawValue)
        XCTAssertEqual(QuickAction.ordered(many).count, 6)
        XCTAssertEqual(QuickAction.ordered([]), [])
    }

    func testDropShelfResultLine() {
        XCTAssertEqual(DropShelfText.result(names: ["a.txt"], folder: "Documents", copied: false),
                       "Just now: Moved “a.txt” to Documents")
        XCTAssertEqual(DropShelfText.result(names: ["a", "b", "c"], folder: "Inbox", copied: true),
                       "Just now: Copied 3 items to Inbox")
    }

    func testGlobalShortcutNeedsCommandOptionOrControl() {
        XCTAssertTrue(KeyCombo("Alt+Space")!.canBeGlobal)
        XCTAssertTrue(KeyCombo("Ctrl+D")!.canBeGlobal)
        XCTAssertFalse(KeyCombo("Shift+Space")!.canBeGlobal)
        XCTAssertFalse(KeyCombo("F5")!.canBeGlobal)
    }
}
