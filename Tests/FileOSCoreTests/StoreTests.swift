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

    func testArraysDecodeElementByElementAndKeepWhatTheyCannotRead() throws {
        let url = makeTempDir().appendingPathComponent("state.json")
        let json = #"{"list": [{"view": "list", "size": 1}, {"view": "future", "size": "huge"}, {"view": "icons", "size": 2}]}"#
        try json.write(to: url, atomically: true, encoding: .utf8)
        let s = Store(url: url)
        XCTAssertNil(s.getArray("absent", of: Prefs.self))
        XCTAssertEqual(s.getArray("list", of: Prefs.self), [Prefs(view: "list", size: 1), Prefs(view: "icons", size: 2)])
        s.setArray("list", [Prefs(view: "cards", size: 3)])
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let list = raw["list"] as! [[String: Any]]
        XCTAssertEqual(list.count, 2) // the new value plus the unreadable one, never dropped
        XCTAssertEqual(list[1]["view"] as? String, "future")
        XCTAssertEqual(Store(url: url).getArray("list", of: Prefs.self), [Prefs(view: "cards", size: 3)])
    }

    func testCorruptFileIsKeptAsideBeforeTheFirstWrite() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("state.json")
        try "{not json".write(to: url, atomically: true, encoding: .utf8)
        let s = Store(url: url)
        s.set("x", 1)
        s.set("y", 2)
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("state.corrupt-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertTrue(aside[0].hasSuffix(".json"))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(aside[0]), encoding: .utf8), "{not json")
        XCTAssertEqual(Store(url: url).get("y", default: 0), 2)
    }

    func testReadableFileIsNotKeptAside() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("state.json")
        Store(url: url).set("x", 1)
        Store(url: url).set("x", 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["state.json"])
    }
}
