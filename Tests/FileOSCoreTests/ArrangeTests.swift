import XCTest
@testable import FileOSCore

final class ArrangeTests: XCTestCase {
    private func entry(_ name: String, dir: Bool = false, size: Int64 = 0, modified: TimeInterval = 0, added: Date? = nil) -> Entry {
        let date = Date(timeIntervalSince1970: modified)
        return Entry(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isDirectory: dir, isSymlink: false, size: size,
                     modified: date, created: date, added: added ?? date, kind: dir ? nil : FileKind.of(name), isHidden: false)
    }

    private func names(_ e: [Entry]) -> [String] { e.map(\.name) }

    func testSortsByNameNaturallyAndFilesFirst() {
        let items = [entry("b10.txt"), entry("Zeta", dir: true), entry("b2.txt"), entry("a.pdf")]
        var prefs = FolderPrefs()
        XCTAssertEqual(names(Arrange.sorted(items, prefs)), ["a.pdf", "b2.txt", "b10.txt", "Zeta"])
        prefs.ascending = false
        XCTAssertEqual(names(Arrange.sorted(items, prefs)), ["Zeta", "b10.txt", "b2.txt", "a.pdf"])
        prefs = FolderPrefs(filesFirst: true)
        let mixed = [entry("a", dir: true), entry("b.txt"), entry("c", dir: true)]
        XCTAssertEqual(names(Arrange.sorted(mixed, prefs)), ["b.txt", "a", "c"])
    }

    func testSortsBySizeAndDateWithNameTieBreak() {
        let items = [entry("b", size: 5, modified: 10), entry("a", size: 5, modified: 30), entry("c", size: 1, modified: 20)]
        XCTAssertEqual(names(Arrange.sorted(items, FolderPrefs(sortKey: .size))), ["c", "a", "b"])
        XCTAssertEqual(names(Arrange.sorted(items, FolderPrefs(sortKey: .modified, ascending: false))), ["a", "c", "b"])
    }

    func testGroupsByKind() {
        let items = [entry("x.pdf"), entry("Folder", dir: true), entry("y.png"), entry("z.pdf")]
        let groups = Arrange.groups(items, by: .kind, now: Date())
        XCTAssertEqual(groups.map(\.title), ["Folders", "PDFs", "Images"])
        XCTAssertEqual(groups[1].entries.map(\.name), ["x.pdf", "z.pdf"])
    }

    func testGroupsByDateAdded() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 12))!
        let items = [
            entry("old", added: now.addingTimeInterval(-90 * 86400)),
            entry("today", added: now.addingTimeInterval(-3600)),
            entry("yesterday", added: now.addingTimeInterval(-86400)),
            entry("week", added: now.addingTimeInterval(-4 * 86400)),
        ]
        let groups = Arrange.groups(items, by: .date, now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday", "Previous 7 Days", "Earlier"])
    }

    func testNoGroupingIsOneUntitledGroup() {
        let groups = Arrange.groups([entry("a")], by: .none, now: Date())
        XCTAssertEqual(groups.map(\.title), [""])
        XCTAssertTrue(Arrange.groups([], by: .none, now: Date()).isEmpty)
    }

    func testPrefsCodable() throws {
        let prefs = FolderPrefs(sortKey: .size, ascending: false, filesFirst: true, group: .kind)
        let data = try JSONEncoder().encode(prefs)
        XCTAssertEqual(try JSONDecoder().decode(FolderPrefs.self, from: data), prefs)
    }
}
