import XCTest
@testable import FileOSCore

final class FolderSymbolTests: XCTestCase {
    func testSpecialFoldersAndNames() throws {
        let home = makeTempDir()
        for name in ["Desktop", "Downloads", "Invoices", "Taxes 2025", "Recipes"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let sym = { (name: String) in FolderSymbol.automatic(for: home.appendingPathComponent(name), home: home) }
        XCTAssertEqual(FolderSymbol.automatic(for: home, home: home), "house")
        XCTAssertEqual(sym("Desktop"), "menubar.dock.rectangle")
        XCTAssertEqual(sym("Downloads"), "arrow.down.circle")
        XCTAssertEqual(sym("Invoices"), "receipt")
        XCTAssertEqual(sym("Taxes 2025"), "dollarsign.circle")
        XCTAssertEqual(sym("Recipes"), "fork.knife")
    }

    func testContents() throws {
        let home = makeTempDir()
        touch(home, "proj/package.json")
        touch(home, "proj/a.jpg")
        for n in ["1.jpg", "2.jpg", "3.jpg", "x.txt"] { touch(home, "pics/\(n)") }
        touch(home, "mixed/a.pdf"); touch(home, "mixed/b.mp3")
        touch(home, "nest/sub/x.txt")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let sym = { (name: String) in FolderSymbol.automatic(for: home.appendingPathComponent(name), home: home) }
        XCTAssertEqual(sym("proj"), "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(sym("pics"), FolderSymbol.symbol(for: .images))
        XCTAssertEqual(sym("mixed"), "square.grid.2x2")
        XCTAssertEqual(sym("nest"), "folder.fill")
        XCTAssertEqual(sym("empty"), "folder")
        XCTAssertEqual(sym("missing"), "lock")
    }

    func testUnreadableIsLocked() throws {
        try XCTSkipIf(getuid() == 0, "root reads everything")
        let home = makeTempDir()
        let dir = home.appendingPathComponent("secret")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        XCTAssertEqual(FolderSymbol.automatic(for: dir, home: home), "lock")
    }
}
