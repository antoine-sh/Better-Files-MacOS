import XCTest
@testable import FileOSCore

final class RenameTests: XCTestCase {
    func testValidate() {
        XCTAssertNil(Rename.validate("ok.txt"))
        XCTAssertEqual(Rename.validate(""), "Name can't be empty")
        XCTAssertEqual(Rename.validate("   "), "Name can't be empty")
        XCTAssertEqual(Rename.validate("a/b"), "Names can't contain / or :")
        XCTAssertEqual(Rename.validate("a:b"), "Names can't contain / or :")
        XCTAssertNil(Rename.validate(".env")) // allowed; the UI asks first (Rename.hidesItem)
        XCTAssertEqual(Rename.validate(".."), "Names can't be “.” or “..”")
        XCTAssertTrue(Rename.hidesItem(".env"))
        XCTAssertFalse(Rename.hidesItem("env"))
        XCTAssertNil(Rename.validate("a b “q” ü.tar.gz"))
        XCTAssertNil(Rename.validate(String(repeating: "a", count: 255)))
        XCTAssertEqual(Rename.validate(String(repeating: "a", count: 256)), "Name is too long")
        XCTAssertEqual(Rename.validate(String(repeating: "é", count: 128)), "Name is too long") // 256 bytes
    }

    func testExtensionChange() {
        let c = Rename.extensionChange(from: "a.pdf", to: "a.docx")
        XCTAssertEqual(c?.from, ".pdf"); XCTAssertEqual(c?.to, ".docx")
        XCTAssertNil(Rename.extensionChange(from: "a.pdf", to: "b.PDF"))
        XCTAssertNil(Rename.extensionChange(from: "a", to: "b"))
        XCTAssertNotNil(Rename.extensionChange(from: "a.pdf", to: "a"))
    }

    func testReplaceKeepsExtension() {
        let rows = Rename.plan(["IMG a.tar.gz", "x.jpg"], rule: .replace(find: "IMG ", with: ""), existing: [])
        XCTAssertEqual(rows.map(\.to), ["a.tar.gz", "x.jpg"])
        XCTAssertTrue(rows.allSatisfy { $0.error == nil })
        let same = Rename.plan(["jpg.jpg"], rule: .replace(find: "", with: "z"), existing: [])
        XCTAssertEqual(same[0].to, "jpg.jpg")
    }

    func testAddBeforeAfter() {
        XCTAssertEqual(Rename.plan(["a.txt"], rule: .add(text: "X-", before: true), existing: []).map(\.to), ["X-a.txt"])
        XCTAssertEqual(Rename.plan(["a.txt"], rule: .add(text: "-X", before: false), existing: []).map(\.to), ["a-X.txt"])
    }

    func testNumberRule() {
        let rows = Rename.plan(["a.jpg", "b.jpg", "c.png"], rule: .number(name: "Lisbon", start: 1), existing: [])
        XCTAssertEqual(rows.map(\.to), ["Lisbon 01.jpg", "Lisbon 02.jpg", "Lisbon 03.png"])
        let big = Rename.plan((0..<3).map { "f\($0)" }, rule: .number(name: "N", start: 99), existing: [])
        XCTAssertEqual(big.map(\.to), ["N 99", "N 100", "N 101"])
    }

    func testDuplicatesAreCaseInsensitive() {
        let rows = Rename.plan(["a.txt", "b.txt"], rule: .replace(find: "a", with: "B"), existing: [])
        // "a.txt" -> "B.txt" collides with the unchanged-looking "b.txt" row
        XCTAssertEqual(rows.map(\.error), ["Duplicate name", "Duplicate name"])
        let nums = Rename.plan(["a.jpg", "b.jpg"], rule: .replace(find: "", with: ""), existing: [])
        XCTAssertTrue(nums.allSatisfy { $0.error == nil })
    }

    func testAlreadyInFolderCaseInsensitive() {
        let rows = Rename.plan(["x.txt"], rule: .replace(find: "x", with: "A"), existing: ["a.txt", "x.txt"])
        XCTAssertEqual(rows[0].to, "A.txt"); XCTAssertEqual(rows[0].error, "Already in this folder")
    }

    func testCaseOnlyRenameOfSameFileIsNotAClash() {
        let rows = Rename.plan(["a.txt"], rule: .replace(find: "a", with: "A"), existing: ["a.txt"])
        XCTAssertNil(rows[0].error)
    }

    func testDownloadingAndInvalid() {
        let rows = Rename.plan(["a.crdownload", "b.txt"], rule: .add(text: ":", before: false), existing: [])
        XCTAssertEqual(rows[0].error, "Still downloading"); XCTAssertEqual(rows[0].to, "a.crdownload")
        XCTAssertEqual(rows[1].error, "Names can't contain / or :")
        let dot = Rename.plan(["b.txt"], rule: .add(text: ".", before: true), existing: [])
        XCTAssertEqual(dot[0].error, "Names can't start with a dot")
    }

    func testApplyRenamesAndUndoes() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, "a.jpg", "A"); touch(dir, "b.jpg", "B")
        let rows = Rename.plan(["a.jpg", "b.jpg"], rule: .number(name: "Trip", start: 1), existing: ["a.jpg", "b.jpg"])
        let r = Rename.apply(rows, in: dir)
        XCTAssertEqual(r.renamed, 2); XCTAssertTrue(r.failed.isEmpty)
        XCTAssertTrue(exists(dir.appendingPathComponent("Trip 02.jpg")))
        let u = await r.undo()
        XCTAssertEqual(u.restored.count, 2); XCTAssertTrue(u.failed.isEmpty)
        XCTAssertTrue(exists(dir.appendingPathComponent("a.jpg")))
    }

    func testApplyContinuesPastFailureAndKeepsUndo() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, "a.txt"); touch(dir, "c.txt")
        let rows = [Rename.BatchRow(from: "a.txt", to: "a2.txt"), Rename.BatchRow(from: "gone.txt", to: "g2.txt"),
                    Rename.BatchRow(from: "c.txt", to: "c2.txt"), Rename.BatchRow(from: "d.txt", to: "d2.txt", error: "Duplicate name")]
        let r = Rename.apply(rows, in: dir)
        XCTAssertEqual(r.renamed, 2); XCTAssertEqual(r.failed.map(\.0), ["gone.txt"])
        let u = await r.undo()
        XCTAssertEqual(u.restored.count, 2)
        XCTAssertTrue(exists(dir.appendingPathComponent("a.txt"))); XCTAssertTrue(exists(dir.appendingPathComponent("c.txt")))
    }

    func testUndoReportsWhenOriginalNameTaken() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, "a.txt", "A")
        let r = Rename.apply([Rename.BatchRow(from: "a.txt", to: "b.txt")], in: dir)
        touch(dir, "a.txt", "squatter")
        let u = await r.undo()
        XCTAssertEqual(u.failed.count, 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8), "squatter")
    }
}
