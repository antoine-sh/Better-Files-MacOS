import XCTest
@testable import FileOSCore

final class UndoStackTests: XCTestCase {
    func testLIFOAndEmpty() async {
        let s = UndoStack()
        let none = await s.undo()
        XCTAssertNil(none)
        XCTAssertFalse(s.canUndo)
        s.push("one") { RestoreResult(restored: [URL(fileURLWithPath: "/1")]) }
        s.push("two") { RestoreResult() }
        XCTAssertTrue(s.canUndo)
        XCTAssertEqual(s.topLabel, "two")
        let a = await s.undo()
        XCTAssertEqual(a?.label, "two")
        let b = await s.undo()
        XCTAssertEqual(b?.label, "one")
        XCTAssertEqual(b?.result.restored.count, 1)
        let c = await s.undo()
        XCTAssertNil(c)
        XCTAssertNil(s.topLabel)
    }

    func testMax100() async {
        let s = UndoStack()
        for i in 0..<105 { s.push("\(i)") { RestoreResult() } }
        var n = 0
        var last = ""
        while let r = await s.undo() { n += 1; last = r.label }
        XCTAssertEqual(n, 100)
        XCTAssertEqual(last, "5")
    }
}
