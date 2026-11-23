import XCTest
@testable import FileOSCore

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

    func testInstallerForInstalledApp() throws {
        let home = makeTempDir()
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Applications/Firefox.app"), withIntermediateDirectories: true)
        touch(home, "Downloads/Firefox 128.0.dmg", modified: Date().addingTimeInterval(-30 * 86_400))
        touch(home, "Downloads/Firefox 129.0.dmg", modified: Date().addingTimeInterval(86_400)) // newer than the app
        touch(home, "Downloads/Other.dmg", modified: Date().addingTimeInterval(-30 * 86_400))
        let items = scan(home)[.installers]!.items
        XCTAssertEqual(items.map(\.url.lastPathComponent), ["Firefox 128.0.dmg"])
        XCTAssertEqual(items.first?.ticked, true)
    }

    func testSymlinkLoopIsNotFollowed() throws {
        let home = makeTempDir()
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Documents/loop"), withDestinationURL: home)
        touch(home, "Documents/a.bin", blob)
        let files = SmartClean.walk([home.appendingPathComponent("Documents")], maxDepth: 4)
        XCTAssertEqual(files.map(\.url.lastPathComponent), ["a.bin"])
    }

    func testDiskSummary() {
        let home = makeTempDir()
        touch(home, ".Trash/x", blob)
        let s = SmartClean.diskSummary(home: home)
        XCTAssertEqual(s.trash, 2048)
        XCTAssertEqual(s.used, s.total - s.free)
    }
}
