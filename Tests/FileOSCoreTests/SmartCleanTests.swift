import XCTest
@testable import FileOSCore

/// Marks a file as downloaded the way macOS does (Smart Clean only offers downloaded installers there).
func markDownloaded(_ url: URL) {
    #if os(macOS)
    let value = "0081;00000000;Safari;"
    _ = value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    #endif
}

final class SmartCleanTests: XCTestCase {
    let blob = String(repeating: "x", count: 2048)

    private func scan(_ home: URL, running: Set<String> = []) -> [CardID: CleanCard] {
        let cards = SmartClean.scan(home: home, now: Date(), isAppRunning: { running.contains($0) },
                                    applications: [home.appendingPathComponent("Applications")])
        XCTAssertEqual(cards.map(\.id), CardID.allCases)
        return Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
    }

    func testDuplicatesKeepOldestAndTickDownloadsSpare() {
        let home = makeTempDir()
        touch(home, "Documents/report.pdf", blob, modified: Date().addingTimeInterval(-10 * 86_400))
        let spare = touch(home, "Downloads/report.pdf", blob, modified: Date().addingTimeInterval(-86_400))
        touch(home, "Documents/small.txt", "x")
        touch(home, "Downloads/small.txt", "x")
        touch(home, "Documents/same-size.txt", String(repeating: "y", count: 2048))
        let items = scan(home)[.duplicates]!.items
        XCTAssertEqual(items.map(\.url.path), [spare.path])
        XCTAssertEqual(items.first?.ticked, true)
        XCTAssertEqual(items.first?.bytes, 2048)
    }

    func testDuplicateSpareInDocumentsNotTickedUnlessNamedLikeACopy() {
        let home = makeTempDir()
        touch(home, "Documents/a.pdf", blob, modified: Date().addingTimeInterval(-10 * 86_400))
        touch(home, "Documents/sub/b.pdf", blob, modified: Date().addingTimeInterval(-86_400))
        touch(home, "Documents/a copy.pdf", blob, modified: Date().addingTimeInterval(-86_400))
        let items = scan(home)[.duplicates]!.items
        let ticked = Dictionary(uniqueKeysWithValues: items.map { ($0.url.lastPathComponent, $0.ticked) })
        XCTAssertEqual(ticked, ["b.pdf": false, "a copy.pdf": true])
    }

    func testDevCacheListedWithSize() {
        let home = makeTempDir()
        touch(home, "Library/Caches/Homebrew/pkg.tar.gz", blob)
        touch(home, "Library/Developer/Xcode/DerivedData/App/x.o", blob)
        let card = scan(home)[.devCaches]!
        XCTAssertEqual(card.group, .safe)
        let byName = Dictionary(uniqueKeysWithValues: card.items.map { ($0.url.lastPathComponent, $0) })
        XCTAssertEqual(byName["Homebrew"]?.bytes, 2048)
        XCTAssertEqual(byName["Homebrew"]?.ticked, true)
        XCTAssertNotNil(byName["DerivedData"])
        XCTAssertNil(scan(home, running: ["Xcode"])[.devCaches]!.items.first { $0.url.lastPathComponent == "DerivedData" },
                     "Xcode's caches are skipped while Xcode runs")
    }

    func testYourCallItemsNeverTicked() {
        let home = makeTempDir()
        let old = Date().addingTimeInterval(-100 * 86_400)
        touch(home, "Downloads/old.txt", modified: old)
        touch(home, "Desktop/Screen Recording 2026-01-01 at 10.00.00.mov", modified: old)
        touch(home, "Library/Mail Downloads/att.pdf")
        let cards = scan(home)
        for card in cards.values where card.group == .yourCall {
            XCTAssertTrue(card.items.allSatisfy { !$0.ticked }, card.title)
        }
        XCTAssertEqual(cards[.screenRecordings]?.items.count, 1)
        XCTAssertEqual(cards[.mailAttachments]?.items.count, 1)
        XCTAssertTrue(CleanCard(id: .bigFiles, items: [CleanItem(url: home, bytes: 1, ticked: true)]).items.allSatisfy { !$0.ticked })
    }

    private func app(_ home: URL, _ name: String, daysOld: Double) throws {
        let url = home.appendingPathComponent("Applications/\(name).app")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: url.path)
    }

    private func installer(_ home: URL, _ name: String, daysOld: Double) {
        markDownloaded(touch(home, "Downloads/\(name)", modified: Date().addingTimeInterval(-daysOld * 86_400)))
    }

    func testInstallerForInstalledApp() throws {
        let home = makeTempDir()
        try app(home, "Firefox", daysOld: 20)
        try app(home, "Arc", daysOld: 20)
        installer(home, "Firefox 128.0.dmg", daysOld: 30)
        installer(home, "Other.dmg", daysOld: 30)
        installer(home, "ArcGIS.dmg", daysOld: 30) // Arc is installed, ArcGIS isn't
        let items = scan(home)[.installers]!.items
        XCTAssertEqual(items.map(\.url.lastPathComponent), ["Firefox 128.0.dmg"])
        XCTAssertEqual(items.first?.ticked, true)
    }

    func testInstallerNewerThanTheAppIsNotOffered() throws {
        let home = makeTempDir()
        try app(home, "Firefox", daysOld: 20)
        installer(home, "Firefox 129.0.dmg", daysOld: 10)
        XCTAssertTrue(scan(home)[.installers]!.items.isEmpty)
    }

    func testInstallerNewerThanAWeekIsNotOffered() throws {
        let home = makeTempDir()
        try app(home, "Firefox", daysOld: 20)
        installer(home, "Firefox 128.0.dmg", daysOld: 3)
        XCTAssertTrue(scan(home)[.installers]!.items.isEmpty)
    }

    func testReadFailureIsNeverIdentical() {
        let home = makeTempDir()
        let a = touch(home, "a.bin", blob), b = touch(home, "b.bin", blob)
        XCTAssertTrue(SmartClean.identical(a, b))
        struct ReadFailed: Error {}
        XCTAssertFalse(SmartClean.identical(a, b, read: { _ in throw ReadFailed() }))
        XCTAssertFalse(SmartClean.identical(a, home.appendingPathComponent("missing")))
    }

    func testTickTheseTooKeepsOneCopy() {
        let home = makeTempDir()
        let kept = touch(home, "Documents/a.pdf", blob, modified: Date().addingTimeInterval(-10 * 86_400))
        touch(home, "Documents/sub/b.pdf", blob, modified: Date().addingTimeInterval(-86_400))
        touch(home, "Downloads/a.pdf", blob, modified: Date().addingTimeInterval(-86_400))
        var card = scan(home)[.duplicates]!
        XCTAssertEqual(card.items.filter(\.ticked).count, 1)
        card.tickTheseToo()
        XCTAssertEqual(card.items.count, 2)
        XCTAssertTrue(card.items.allSatisfy(\.ticked))
        XCTAssertFalse(card.items.contains { $0.url.path == kept.path })
    }

    func testKeptDuplicateIsNotOfferedByLaterCards() {
        let home = makeTempDir()
        let old = Date().addingTimeInterval(-100 * 86_400)
        let kept = touch(home, "Downloads/report.pdf", blob, modified: old)
        let copy = touch(home, "Downloads/report copy.pdf", blob, modified: old.addingTimeInterval(86_400))
        // Where creation dates can be set (macOS), both are old downloads too.
        for url in [kept, copy] { try? FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: url.path) }
        let cards = scan(home)
        XCTAssertEqual(cards[.duplicates]!.items.map(\.url.lastPathComponent), ["report copy.pdf"])
        XCTAssertFalse(cards[.oldDownloads]!.items.contains { $0.url.path == kept.path })
    }

    func testDuplicateTieKeepsTheNameThatIsNotACopy() {
        let home = makeTempDir()
        let date = Date().addingTimeInterval(-86_400)
        touch(home, "Documents/a copy.pdf", blob, modified: date)
        touch(home, "Documents/a.pdf", blob, modified: date)
        // Same dates: creation dates differ by microseconds, so only check where they could be set equal.
        let files = SmartClean.walk([home.appendingPathComponent("Documents")], maxDepth: 4).files
            .map { SmartClean.FileRecord(url: $0.url, size: $0.size, created: date, modified: date) }
        let result = SmartClean.duplicates(files, inDownloadsOrDesktop: { _ in false })
        XCTAssertEqual(result.kept.map(\.lastPathComponent), ["a.pdf"])
        XCTAssertEqual(result.items.first?.ticked, true, "named like a copy")
    }

    func testStaleNodeModulesListedApartUnticked() throws {
        let home = makeTempDir()
        touch(home, "Documents/web/node_modules/left-pad/index.js", blob)
        touch(home, "Documents/fresh/node_modules/x.js", blob)
        let stale = home.appendingPathComponent("Documents/web/node_modules")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-200 * 86_400)], ofItemAtPath: stale.path)
        let items = scan(home)[.devCaches]!.items
        XCTAssertEqual(items.map(\.url.path), [stale.path])
        XCTAssertEqual(items.first?.ticked, false)
        XCTAssertEqual(items.first?.note, SmartClean.staleNodeModulesNote)
        XCTAssertEqual(items.first?.bytes, 2048)
    }

    func testSymlinkLoopIsNotFollowed() throws {
        let home = makeTempDir()
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Documents/loop"), withDestinationURL: home)
        touch(home, "Documents/a.bin", blob)
        let files = SmartClean.walk([home.appendingPathComponent("Documents")], maxDepth: 4).files
        XCTAssertEqual(files.map(\.url.lastPathComponent), ["a.bin"])
    }

    func testDiskSummary() {
        let home = makeTempDir()
        touch(home, ".Trash/x", blob)
        let s = SmartClean.diskSummary(home: home)
        XCTAssertEqual(s.trash, 2048)
        XCTAssertEqual(s.used, s.total - s.free)
    }

    func testDiskSummaryTrashIsUnknownWhenItCantBeListed() {
        let home = makeTempDir()
        touch(home, ".Trash") // a Trash we can't list (root ignores permissions, so a file stands in)
        XCTAssertNil(SmartClean.diskSummary(home: home).trash)
    }

    func testLeftoversSkipSystemDataAndFoldersChangedDeepInside() {
        let home = makeTempDir()
        let old = Date().addingTimeInterval(-200 * 86_400)
        let support = home.appendingPathComponent("Library/Application Support")
        touch(home, "Library/Application Support/GoneApp/data.db", modified: old)
        touch(home, "Library/Application Support/AddressBook/Sources/db.sqlite", modified: old)
        touch(home, "Library/Application Support/BusyApp/cache/today.db") // changed now, deep inside
        for dir in ["GoneApp", "AddressBook", "AddressBook/Sources", "BusyApp/cache", "BusyApp"] {
            try! FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: support.appendingPathComponent(dir).path)
        }
        XCTAssertEqual(scan(home)[.appLeftovers]!.items.map(\.url.lastPathComponent), ["GoneApp"])
    }

    func testDuplicateSpareNotSafeOnceKeptCopyGoesAndHardLinksAreNotDuplicates() throws {
        let home = makeTempDir()
        let kept = touch(home, "Documents/a.pdf", blob, modified: Date().addingTimeInterval(-10 * 86_400))
        touch(home, "Downloads/a.pdf", blob)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: kept, to: home.appendingPathComponent("Desktop/link.pdf"))
        let items = scan(home)[.duplicates]!.items
        XCTAssertEqual(items.map(\.url.lastPathComponent), ["a.pdf"])
        XCTAssertTrue(items[0].stillSafeToTrash)
        let keep = try XCTUnwrap(items[0].keep) // a.pdf or its hard link: one file either way
        try "changed".write(to: keep, atomically: true, encoding: .utf8)
        XCTAssertFalse(items[0].stillSafeToTrash)
        try FileManager.default.removeItem(at: keep)
        XCTAssertFalse(items[0].stillSafeToTrash)
    }
}
