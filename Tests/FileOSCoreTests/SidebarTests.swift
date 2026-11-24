import XCTest
@testable import FileOSCore

final class SidebarTests: XCTestCase {
    func testCloudLocationsListICloudThenCloudDrives() throws {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(CloudLocations.list(home: home), [])
        let fm = FileManager.default
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let storage = home.appendingPathComponent("Library/CloudStorage")
        try fm.createDirectory(at: icloud, withIntermediateDirectories: true)
        try fm.createDirectory(at: storage.appendingPathComponent("GoogleDrive-me"), withIntermediateDirectories: true)
        try fm.createDirectory(at: storage.appendingPathComponent("Dropbox"), withIntermediateDirectories: true)
        try fm.createDirectory(at: storage.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try "x".write(to: storage.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(CloudLocations.list(home: home).map(\.lastPathComponent), ["com~apple~CloudDocs", "Dropbox", "GoogleDrive-me"])
    }

    func testTagSearchRunsMdfindAndParsesPaths() async {
        let seen = Seen()
        let runner = ScriptedRunner { exe, args in
            seen.calls.append((exe, args))
            return (0, "/Users/me/a b.txt\n/Users/me/Docs\n\nnot a path\n")
        }
        let urls = await FinderTags.files(tagged: "Red", runner: runner)
        XCTAssertEqual(urls.map(\.path), ["/Users/me/a b.txt", "/Users/me/Docs"])
        XCTAssertEqual(seen.calls.first?.0, "mdfind")
        XCTAssertEqual(seen.calls.first?.1, ["kMDItemUserTags == 'Red'"])
        _ = await FinderTags.files(tagged: nil, runner: runner)
        XCTAssertEqual(seen.calls.last?.1, ["kMDItemUserTags == '*'"])
        _ = await FinderTags.files(tagged: "it's\\", runner: runner)
        XCTAssertEqual(seen.calls.last?.1, ["kMDItemUserTags == 'its'"], "quotes can't break out of the query")
    }

    func testTagSearchFailureIsEmpty() async {
        let failing = ScriptedRunner { _, _ in throw CommandError.timedOut }
        let none = await FinderTags.files(tagged: "Red", runner: failing)
        XCTAssertEqual(none, [])
        let bad = ScriptedRunner { _, _ in (1, "/x\n") }
        let alsoNone = await FinderTags.files(tagged: "Red", runner: bad)
        XCTAssertEqual(alsoNone, [])
        XCTAssertEqual(FinderTags.colors, ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
    }

    func testStickersRoundTripLossily() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(url: dir.appendingPathComponent("s.json"))
        let star = Sticker(emoji: "⭐️", x: 10, y: 20)
        store.setArray("home.stickers", [star])
        XCTAssertEqual(Store(url: dir.appendingPathComponent("s.json")).getArray("home.stickers", of: Sticker.self), [star])
        XCTAssertFalse(Sticker.choices.isEmpty)
    }

    final class Seen: @unchecked Sendable { var calls: [(String, [String])] = [] }
}
