import XCTest
@testable import FileOSCore

final class CommandRunnerTests: XCTestCase {
    func testRunsAndCaptures() async throws {
        let r = try await ProcessRunner().run("/bin/echo", ["hi"], timeout: 5)
        XCTAssertEqual(r.status, 0); XCTAssertEqual(r.stdout, "hi\n")
    }

    func testTimeoutKills() async {
        let t = Date()
        do { _ = try await ProcessRunner().run("/bin/sleep", ["5"], timeout: 0.2); XCTFail() } catch CommandError.timedOut {} catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(t), 1)
    }

    func testTimeoutBoundsCallWhenGrandchildHoldsPipe() async {
        let t = Date()
        do { _ = try await ProcessRunner().run("/bin/sh", ["-c", "sleep 5 & wait"], timeout: 0.3); XCTFail() } catch CommandError.timedOut {} catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(t), 1)
    }

    func testNotFound() async {
        do { _ = try await ProcessRunner().run("no-such-exe-xyz", [], timeout: 1); XCTFail() }
        catch CommandError.notFound(let n) { XCTAssertEqual(n, "no-such-exe-xyz") } catch { XCTFail("\(error)") }
    }
}
