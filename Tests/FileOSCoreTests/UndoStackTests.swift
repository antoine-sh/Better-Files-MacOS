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

    func testConcurrentUndosRunOneAtATime() async {
        let s = UndoStack()
        let log = Log()
        for name in ["a", "b", "c"] {
            s.push(name) {
                log.add("start \(name)")
                try? await Task.sleep(nanoseconds: 20_000_000)
                log.add("end \(name)")
                return RestoreResult()
            }
        }
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<3 { g.addTask { _ = await s.undo() } }
        }
        XCTAssertEqual(log.lines, ["start c", "end c", "start b", "end b", "start a", "end a"])
    }
}

final class Log: @unchecked Sendable {
    private let lock = NSLock(); private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var lines: [String] { lock.withLock { items } }
}
