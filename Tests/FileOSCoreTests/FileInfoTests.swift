import XCTest
@testable import FileOSCore

final class FileInfoTests: XCTestCase {
    func testTextCounts() {
        let dir = makeTempDir()
        let url = touch(dir, "notes.txt", "one two three\nfour\n\nfive")
        let s = FileInfo.summary(url)
        XCTAssertEqual(s.words, 5)
        XCTAssertEqual(s.lines, 4)
        XCTAssertEqual(s.size, 24)
        XCTAssertNil(s.pixelSize)
    }

    func testCRLFTextCounts() {
        let url = touch(makeTempDir(), "win.txt", "one two\r\nthree\r\n\r\nfour")
        XCTAssertEqual(FileInfo.summary(url).lines, 4)
        XCTAssertEqual(FileInfo.summary(url).words, 4)
        let trailing = touch(makeTempDir(), "t.txt", "a\r\nb\r\n")
        XCTAssertEqual(FileInfo.summary(trailing).lines, 2)
    }

    func testPNGHeader() throws {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
        bytes += [0, 0, 0x02, 0x80, 0, 0, 0x01, 0xE0, 8, 6, 0, 0, 0]
        let url = makeTempDir().appendingPathComponent("p.png")
        try Data(bytes).write(to: url)
        let s = FileInfo.summary(url)
        XCTAssertEqual(s.pixelSize?.width, 640)
        XCTAssertEqual(s.pixelSize?.height, 480)
        XCTAssertNil(s.words)
    }

    func testGIFAndJPEGHeaders() {
        let gif = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x0A, 0x00, 0x14, 0x00])
        XCTAssertEqual(FileInfo.pixelSize(gif)?.width, 10)
        XCTAssertEqual(FileInfo.pixelSize(gif)?.height, 20)
        // SOI, an APP0 segment of 4 bytes, then SOF0 with height 300, width 400.
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0x2C, 0x01, 0x90])
        XCTAssertEqual(FileInfo.pixelSize(jpeg)?.width, 400)
        XCTAssertEqual(FileInfo.pixelSize(jpeg)?.height, 300)
        XCTAssertNil(FileInfo.pixelSize(Data([0xFF, 0xD8, 0xFF, 0xE0, 0xFF, 0xFF])))
    }

    func testBinaryAndLinksHaveNoCounts() throws {
        let dir = makeTempDir()
        let bin = dir.appendingPathComponent("b.txt")
        try Data([0x61, 0, 0x62]).write(to: bin)
        XCTAssertNil(FileInfo.summary(bin).words)
        let link = dir.appendingPathComponent("l.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: touch(dir, "t.txt", "a b"))
        XCTAssertNil(FileInfo.summary(link).words)
    }
}
