import XCTest
@testable import FileOSCore

final class StoreTests: XCTestCase {
    struct Prefs: Codable, Equatable { var view: String; var size: Int }

    func testRoundTripAcrossInstances() {
        let url = makeTempDir().appendingPathComponent("state.json")
        let a = Store(url: url)
        a.set("showHidden", true)
        a.set("prefs", Prefs(view: "list", size: 3))
        a.set("favorites", ["/a b", "/ü"])
        let b = Store(url: url)
        XCTAssertEqual(b.get("showHidden", default: false), true)
        XCTAssertEqual(b.get("prefs", default: Prefs(view: "", size: 0)), Prefs(view: "list", size: 3))
        XCTAssertEqual(b.get("favorites", default: [String]()), ["/a b", "/ü"])
    }

    func testMissingFileGivesDefault() {
        let url = makeTempDir().appendingPathComponent("nested/none.json")
        let s = Store(url: url)
        XCTAssertEqual(s.get("x", default: 7), 7)
        s.set("x", 8) // creates parent dirs
        XCTAssertEqual(Store(url: url).get("x", default: 7), 8)
    }

    func testCorruptFileGivesDefault() throws {
        let url = makeTempDir().appendingPathComponent("state.json")
        try "{not json".write(to: url, atomically: true, encoding: .utf8)
        let s = Store(url: url)
        XCTAssertEqual(s.get("x", default: "d"), "d")
        s.set("x", "v")
        XCTAssertEqual(Store(url: url).get("x", default: "d"), "v")
    }

    func testWrongTypeGivesDefault() {
        let url = makeTempDir().appendingPathComponent("state.json")
        let s = Store(url: url)
        s.set("x", "text")
        XCTAssertEqual(s.get("x", default: 5), 5)
    }
}
