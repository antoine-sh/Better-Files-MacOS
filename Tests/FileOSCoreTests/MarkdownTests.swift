import XCTest
@testable import FileOSCore

final class MarkdownTests: XCTestCase {
    func testOutlineSkipsFencedCode() {
        let src = "# A\n## B\n```\n# not\n```\n~~~\n## nor\n~~~\n### C ###\n#nope"
        let out = Markdown.outline(src)
        XCTAssertEqual(out.map { $0.level }, [1, 2, 3])
        XCTAssertEqual(out.map { $0.text }, ["A", "B", "C"])
        XCTAssertEqual(out.map { $0.id }, ["a", "b", "c"])
    }

    func testOutlineIdsAreUniqueSlugs() {
        let out = Markdown.outline("# Hello, World!\n# Hello World")
        XCTAssertEqual(out.map { $0.id }, ["hello-world", "hello-world-1"])
    }

    func testIsMarkdown() {
        for name in ["a.md", "A.MARKDOWN", "x.mdown", "y.mkd"] { XCTAssertTrue(Markdown.isMarkdown(name), name) }
        for name in ["a.txt", "md", ".md"] { XCTAssertFalse(Markdown.isMarkdown(name), name) }
    }

    func testCanShowAsPage() {
        XCTAssertNil(Markdown.canShowAsPage(size: 5, data: Data("# hi".utf8)))
        XCTAssertEqual(Markdown.canShowAsPage(size: 6_000_000, data: Data("# hi".utf8)), "it's over 5 MB")
        XCTAssertEqual(Markdown.canShowAsPage(size: 2, data: Data([0xFF, 0xFE])), "it isn't UTF-8 text")
    }

    func testCRLFLineEndings() {
        let src = "# A\r\nIntro\r\n\r\n## B\r\n```\r\n# not\r\n```\r\n- [x] done\r\n"
        XCTAssertEqual(Markdown.outline(src).map { $0.id }, ["a", "b"])
        XCTAssertEqual(Markdown.blocks(src), [
            .heading(level: 1, text: "A", id: "a"), .paragraph("Intro"), .heading(level: 2, text: "B", id: "b"),
            .code("# not"), .task(done: true, text: "done"),
        ])
    }

    func testLoadRefusesFoldersAndLinks() throws {
        let dir = makeTempDir()
        let file = touch(dir, "a.md", "# A")
        XCTAssertEqual(try Markdown.load(file).get(), "# A")
        let link = dir.appendingPathComponent("l.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try Markdown.load(link).get())
        XCTAssertThrowsError(try Markdown.load(dir).get())
    }

    func testBlocks() {
        let src = "# Title\nIntro line\nmore\n\n- [ ] todo\n- [x] done\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n"
        let blocks = Markdown.blocks(src)
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title", id: "title"),
            .paragraph("Intro line\nmore"),
            .task(done: false, text: "todo"),
            .task(done: true, text: "done"),
            .code("let a = 1\n\nlet b = 2"),
        ])
    }
}
