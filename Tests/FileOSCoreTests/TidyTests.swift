import XCTest
@testable import FileOSCore

final class TidyTests: XCTestCase {
    let hourAgo = Date().addingTimeInterval(-3600)

    func testLeavesDownloadingAndJustAddedFiles() throws {
        let dir = makeTempDir()
        touch(dir, "new.pdf", modified: Date().addingTimeInterval(-30))
        touch(dir, "movie.mp4.crdownload", modified: hourAgo)
        touch(dir, "old.pdf", modified: hourAgo)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        let plan = try Tidy.plan(dir, now: Date())
        let left = Dictionary(uniqueKeysWithValues: plan.left.map { ($0.name, $0.reason) })
        XCTAssertEqual(left, ["new.pdf": "Added in the last 2 minutes", "movie.mp4.crdownload": "Still downloading"])
        XCTAssertEqual(plan.moves.map { $0.from.lastPathComponent }, ["old.pdf"])
        XCTAssertEqual(plan.moves.first?.to.path, dir.appendingPathComponent("PDFs/old.pdf").path)
        XCTAssertEqual(plan.byKind[.pdfs]?.count, 1)
    }

    func testClashIsNumberedAndExistingFolderReused() throws {
        let dir = makeTempDir()
        touch(dir, "PDFs/report.pdf", "old")
        touch(dir, "report.pdf", "new", modified: hourAgo)
        let plan = try Tidy.plan(dir, now: Date())
        XCTAssertEqual(plan.moves.first?.to.lastPathComponent, "report 2.pdf")
        let (moved, _) = try Tidy.apply(plan, skip: [], trashDir: nil)
        XCTAssertEqual(moved, 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("PDFs/report 2.pdf"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("PDFs/report.pdf"), encoding: .utf8), "old")
    }

    func testApplyThenUndoRestoresAndRemovesCreatedFolders() async throws {
        let dir = makeTempDir()
        let trash = makeTempDir()
        for name in ["a.pdf", "b.jpg", "Screenshot 2026-01-01 at 10.00.png", "c.zip", "setup.dmg", "notes.txt"] {
            touch(dir, name, modified: hourAgo)
        }
        touch(dir, "Documents/keep.txt")
        let plan = try Tidy.plan(dir, now: Date(), installersToTrash: true)
        XCTAssertEqual(plan.byKind[.screenshots]?.destination.lastPathComponent, "Images")
        let (moved, undo) = try Tidy.apply(plan, skip: [.archives], trashDir: trash)
        XCTAssertEqual(moved, 5)
        XCTAssertTrue(exists(dir.appendingPathComponent("Images/Screenshot 2026-01-01 at 10.00.png")))
        XCTAssertTrue(exists(trash.appendingPathComponent("setup.dmg")))
        XCTAssertTrue(exists(dir.appendingPathComponent("c.zip")))
        let result = await undo()
        XCTAssertTrue(result.failed.isEmpty)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(names, ["a.pdf", "b.jpg", "Screenshot 2026-01-01 at 10.00.png", "c.zip", "setup.dmg", "notes.txt", "Documents"])
        XCTAssertTrue(exists(dir.appendingPathComponent("Documents/keep.txt")), "a reused folder stays")
    }

    func testUndoKeepsCreatedFolderThatGainedFiles() async throws {
        let dir = makeTempDir()
        touch(dir, "a.pdf", modified: hourAgo)
        let (_, undo) = try Tidy.apply(try Tidy.plan(dir, now: Date()), skip: [], trashDir: nil)
        touch(dir, "PDFs/later.pdf")
        _ = await undo()
        XCTAssertTrue(exists(dir.appendingPathComponent("a.pdf")))
        XCTAssertTrue(exists(dir.appendingPathComponent("PDFs/later.pdf")))
    }

    func testScreenshotsToPictures() throws {
        let dir = makeTempDir()
        let shots = makeTempDir().appendingPathComponent("Screenshots")
        touch(dir, "Screenshot 1.png", modified: hourAgo)
        let plan = try Tidy.plan(dir, now: Date(), screenshotsToPictures: shots)
        XCTAssertEqual(plan.moves.first?.to.deletingLastPathComponent().path, shots.path)
    }

    private func entry(_ name: String, added: Date, size: Int64 = 1, dir: Bool = false) -> Entry {
        Entry(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isDirectory: dir, isSymlink: false, size: size,
              modified: added, created: added, added: added, kind: dir ? nil : FileKind.of(name), isHidden: false)
    }

    func testDateGroups() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2
        // Thursday 2026-11-19 12:00 UTC.
        let now = Date(timeIntervalSince1970: 1_763_553_600 + 365 * 86_400)
        let d: (Double) -> Date = { now.addingTimeInterval(-$0 * 86_400) }
        let es = [entry("t", added: d(0)), entry("y", added: d(1)), entry("w", added: d(3)),
                  entry("m", added: d(12)), entry("o", added: d(60))]
        let groups = Tidy.groupByDate(es, now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.label), ["Today", "Yesterday", "Earlier this week", "Earlier this month", "Older"])
        XCTAssertEqual(groups.map { $0.items.map(\.name) }, [["t"], ["y"], ["w"], ["m"], ["o"]])
    }

    func testKindGroupsBiggestFirstDownloadingLast() {
        let now = Date()
        let groups = Tidy.groupByKind([entry("a.pdf", added: now, size: 10), entry("b.mp4", added: now, size: 500),
                                       entry("c.pdf", added: now, size: 10), entry("x.crdownload", added: now, size: 900),
                                       entry("Folder", added: now, dir: true)])
        XCTAssertEqual(groups.map(\.kind), [.videos, .pdfs, nil])
        XCTAssertEqual(groups[1].bytes, 20)
    }

    func testSuggestions() {
        let now = Date()
        let es = [entry("Firefox 128.0.dmg", added: now), entry("Other.dmg", added: now), entry("invoice (1).pdf", added: now),
                  entry("notes copy.txt", added: now), entry("notes copy 2.txt", added: now), entry("plan.txt", added: now),
                  entry("ancient.zip", added: now.addingTimeInterval(-91 * 86_400))]
        let s = Tidy.suggestions(es, installedApps: ["Firefox"], now: now)
        XCTAssertEqual(s.installers.map(\.name), ["Firefox 128.0.dmg"])
        XCTAssertEqual(s.duplicates.map(\.name), ["invoice (1).pdf", "notes copy.txt", "notes copy 2.txt"])
        XCTAssertEqual(s.older.map(\.name), ["ancient.zip"])
        XCTAssertFalse(Tidy.isLikelyCopyName("copy.txt"))
        XCTAssertFalse(Tidy.isLikelyCopyName("Report (final).pdf"))
    }
}
