import XCTest
@testable import FileOSCore

final class KindsTests: XCTestCase {
    func testKindOf() {
        XCTAssertEqual(FileKind.of("a.PDF"), .pdfs)
        XCTAssertEqual(FileKind.of("Screenshot 2026-11-01 at 10.00.00.png"), .screenshots)
        XCTAssertEqual(FileKind.of("x.png"), .images)
        XCTAssertEqual(FileKind.of("Screenshot x.PNG"), .screenshots)
        XCTAssertEqual(FileKind.of("x.dmg"), .installers)
        XCTAssertEqual(FileKind.of("x.tar.gz"), .archives)
        XCTAssertEqual(FileKind.of("x.mp4"), .videos)
        XCTAssertEqual(FileKind.of("x.mp3"), .audio)
        XCTAssertEqual(FileKind.of("x.docx"), .documents)
        XCTAssertEqual(FileKind.of("noext"), .other)
        XCTAssertEqual(FileKind.of(".env"), .other)
        XCTAssertEqual(FileKind.allCases.count, 9)
    }

    func testIsDownloading() {
        XCTAssertTrue(isDownloading("a.crdownload"))
        XCTAssertTrue(isDownloading("a.PART"))
        XCTAssertFalse(isDownloading("a.pdf"))
    }

    func testSplitExtension() {
        XCTAssertTrue(splitExtension("a b.tar.gz") == ("a b", ".tar.gz"))
        XCTAssertTrue(splitExtension(".env") == (".env", ""))
        XCTAssertTrue(splitExtension("report.pdf") == ("report", ".pdf"))
        XCTAssertTrue(splitExtension("noext") == ("noext", ""))
        XCTAssertTrue(splitExtension("trailing.") == ("trailing.", ""))
    }

    func testFormatBytes() {
        XCTAssertEqual(formatBytes(0), "0 bytes")
        XCTAssertEqual(formatBytes(999), "999 bytes")
        XCTAssertEqual(formatBytes(1200), "1.2 KB")
        XCTAssertEqual(formatBytes(1_200_000_000), "1.2 GB")
        XCTAssertEqual(formatBytes(999_950), "1.0 MB")
    }
}
