import XCTest
@testable import FileOSCore

final class WorkspacesTests: XCTestCase {
    private func make() throws -> ([Workspace], UUID) {
        let (list, w) = try Workspaces.create([], name: " Taxes 2026 ", description: "Receipts", color: "green")
        return (list, w.id)
    }

    func testCreateTrimsAndRejectsEmptyName() throws {
        let (list, id) = try make()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, id)
        XCTAssertEqual(list[0].name, "Taxes 2026")
        XCTAssertFalse(list[0].archived)
        XCTAssertThrowsError(try Workspaces.create(list, name: "  ", description: "", color: "blue"))
    }

    func testAddingTheSameFolderTwiceKeepsOneItem() throws {
        let (list, id) = try make()
        let folder = WorkspaceItem.file("/Users/me/Taxes", isFolder: true)
        var next = Workspaces.add(list, to: id, items: [folder])
        next = Workspaces.add(next, to: id, items: [WorkspaceItem.file("/Users/me/Taxes", isFolder: true), folder])
        XCTAssertEqual(next[0].items.count, 1)
        XCTAssertEqual(next[0].items[0].kind, .folder)
        let link = WorkspaceItem.link("https://example.com")
        next = Workspaces.add(next, to: id, items: [link, WorkspaceItem.link("https://example.com")])
        XCTAssertEqual(next[0].items.count, 2)
    }

    func testRemoveOnlyUnlists() throws {
        let (list, id) = try make()
        let item = WorkspaceItem.file("/tmp/a.pdf", isFolder: false)
        let added = Workspaces.add(list, to: id, items: [item])
        let removed = Workspaces.remove(added, from: id, items: [item.id])
        XCTAssertTrue(removed[0].items.isEmpty)
    }

    func testSeventhPinThrows() throws {
        let (list, id) = try make()
        let items = (1...7).map { WorkspaceItem.file("/tmp/\($0).txt", isFolder: false) }
        var next = Workspaces.add(list, to: id, items: items)
        for item in items.prefix(6) { next = try Workspaces.pin(next, in: id, item: item.id, true) }
        XCTAssertEqual(next[0].items.filter(\.pinned).count, 6)
        XCTAssertThrowsError(try Workspaces.pin(next, in: id, item: items[6].id, true)) { error in
            XCTAssertEqual(error.localizedDescription, "You can pin up to six files")
        }
        next = try Workspaces.pin(next, in: id, item: items[0].id, false)
        XCTAssertEqual(next[0].items.filter(\.pinned).count, 5)
    }

    func testArchiveRestoreEditDeleteAndUndoByPreviousArray() throws {
        let (list, id) = try make()
        let archived = Workspaces.archive(list, id)
        XCTAssertTrue(archived[0].archived)
        XCTAssertFalse(Workspaces.restore(archived, id)[0].archived)
        let edited = Workspaces.edit(list, id, name: "Taxes", description: "d", color: "red")
        XCTAssertEqual(edited[0].name, "Taxes")
        XCTAssertEqual(edited[0].color, "red")
        let item = WorkspaceItem.file("/tmp/kept", isFolder: true)
        let previous = Workspaces.add(edited, to: id, items: [item])
        let deleted = Workspaces.delete(previous, id)
        XCTAssertTrue(deleted.isEmpty)
        // Undo puts the previous array back: the workspace, its fields and its items, all intact.
        let undone = previous
        XCTAssertEqual(undone.map(\.id), [id])
        XCTAssertEqual(undone[0].name, "Taxes")
        XCTAssertEqual(undone[0].items, [item])
    }

    func testSample() {
        let home = URL(fileURLWithPath: "/Users/me")
        let s = Workspaces.sample(home: home)
        XCTAssertEqual(s.name, "Acme Project")
        XCTAssertEqual(s.id, Workspaces.sampleID)
        XCTAssertEqual(Workspaces.sampleTips.count, 5)
        XCTAssertTrue(s.items.contains { $0.path == "/Users/me/Documents" })
    }

    func testStatus() {
        let file = WorkspaceItem.file("/Volumes/T7 Shield/Video/cut.mov", isFolder: false)
        let gone = Workspaces.status(of: file, fileExists: { _ in false }, volumeMounted: { _ in false })
        XCTAssertEqual(gone, .disconnected("T7 Shield"))
        XCTAssertEqual(gone.text, "“T7 Shield” isn't connected")
        XCTAssertEqual(Workspaces.status(of: file, fileExists: { _ in false }, volumeMounted: { _ in true }), .missing)
        XCTAssertEqual(ItemStatus.missing.text, "Can't find it")
        XCTAssertEqual(Workspaces.status(of: file, fileExists: { _ in true }, volumeMounted: { _ in false }), .ok)
        XCTAssertEqual(Workspaces.status(of: .link("https://a.com"), fileExists: { _ in false }, volumeMounted: { _ in false }), .ok)
    }

    func testTabs() {
        let pdf = WorkspaceItem.file("/a/b.pdf", isFolder: false)
        let png = WorkspaceItem.file("/a/b.png", isFolder: false)
        let dir = WorkspaceItem.file("/a/c", isFolder: true)
        let link = WorkspaceItem.link("https://a.com")
        XCTAssertTrue(WorkspaceTab.documents.matches(pdf))
        XCTAssertTrue(WorkspaceTab.images.matches(png))
        XCTAssertTrue(WorkspaceTab.folders.matches(dir))
        XCTAssertTrue(WorkspaceTab.links.matches(link))
        XCTAssertFalse(WorkspaceTab.links.matches(dir))
        XCTAssertTrue(WorkspaceTab.overview.matches(link))
        XCTAssertEqual(dir.name, "c")
        XCTAssertEqual(link.name, "a.com")
    }

    func testCodableKeepsIdAndNameForThePalette() throws {
        let (list, id) = try make()
        let data = try JSONEncoder().encode(list)
        let raw = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertEqual(raw[0]["id"] as? String, id.uuidString)
        XCTAssertEqual(raw[0]["name"] as? String, "Taxes 2026")
    }
}
