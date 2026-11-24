import XCTest
@testable import FileOSCore

final class ZipReaderTests: XCTestCase {
    /// A stored (uncompressed) zip built by hand: local headers, central directory, end record.
    static func makeZip(_ files: [(String, String)], unixModes: [String: Int] = [:], host: Int = 3) -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { u16(v & 0xFFFF) + u16(v >> 16) }
        func crc32(_ bytes: [UInt8]) -> Int {
            var c: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                c ^= UInt32(byte)
                for _ in 0..<8 { c = c & 1 == 1 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
            }
            return Int(c ^ 0xFFFF_FFFF)
        }
        for (name, body) in files {
            let n = Array(name.utf8), b = Array(body.utf8), offset = out.count, crc = crc32(b)
            out += u32(0x04034b50) + u16(20) + u16(0x0800) + u16(0) + u16(0) + u16(0) + u32(crc) + u32(b.count) + u32(b.count)
                + u16(n.count) + u16(0) + n + b
            central += u32(0x02014b50) + u16(host << 8 | 0x14) + u16(20) + u16(0x0800) + u16(0) + u16(0) + u16(0) + u32(crc)
                + u32(b.count) + u32(b.count) + u16(n.count) + u16(0) + u16(0) + u16(0) + u16(0)
                + u32((unixModes[name] ?? (name.hasSuffix("/") ? 0o040755 : 0o100644)) << 16) + u32(offset) + n
        }
        let cdOffset = out.count
        out += central
        out += u32(0x06054b50) + u16(0) + u16(0) + u16(files.count) + u16(files.count) + u32(central.count) + u32(cdOffset) + u16(0)
        return out
    }

    func testEntriesFromBuiltBytes() throws {
        let url = makeTempDir().appendingPathComponent("a.zip")
        try Self.makeZip([("docs/", ""), ("docs/ré sumé.txt", "hi"), ("b.md", "# b")]).write(to: url)
        XCTAssertEqual(try ZipReader.entries(url), ["docs/", "docs/ré sumé.txt", "b.md"])
        XCTAssertFalse(try ZipReader.isEncrypted(url))
    }

    func testEntriesFromZipTool() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/zip") else { throw XCTSkip("no /usr/bin/zip") }
        let dir = makeTempDir()
        touch(dir, "src/a b.txt", "hello")
        touch(dir, "src/sub/c.txt", "c")
        let zip = dir.appendingPathComponent("out.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-qr", zip.path, "src"]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(Set(try ZipReader.entries(zip)), ["src/", "src/a b.txt", "src/sub/", "src/sub/c.txt"])
    }

    func testMalformedInputThrowsWithoutCrashing() throws {
        let dir = makeTempDir()
        let good = Self.makeZip([("a.txt", "hello"), ("b.txt", "world")])
        var cases: [Data] = [Data(), Data("not a zip at all".utf8), Data(repeating: 0xFF, count: 5000)]
        for cut in [1, 10, 22, 40, good.count / 2, good.count - 1] { cases.append(good.prefix(cut)) }
        cases.append(good.suffix(30)) // end record whose directory points before the file start
        var lying = good // claims a huge directory and entry count
        let eocd = lying.count - 22
        lying.replaceSubrange((eocd + 8)..<(eocd + 16), with: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])
        cases.append(lying)
        var longName = good // first central header claims a 65535-byte name
        if let r = longName.range(of: Data([0x50, 0x4B, 0x01, 0x02])) {
            longName.replaceSubrange((r.lowerBound + 28)..<(r.lowerBound + 30), with: [0xFF, 0xFF])
        }
        cases.append(longName)
        for (i, data) in cases.enumerated() {
            let url = dir.appendingPathComponent("bad\(i).zip")
            try data.write(to: url)
            XCTAssertThrowsError(try ZipReader.entries(url), "case \(i)")
        }
        XCTAssertThrowsError(try ZipReader.entries(dir)) // a folder
    }

    func testEncryptedFlag() throws {
        var data = Self.makeZip([("a.txt", "x")])
        let r = data.range(of: Data([0x50, 0x4B, 0x01, 0x02]))!
        data[r.lowerBound + 8] |= 1
        let url = makeTempDir().appendingPathComponent("p.zip")
        try data.write(to: url)
        XCTAssertTrue(try ZipReader.isEncrypted(url))
    }

    struct FakeRunner: CommandRunner {
        let calls = Calls()
        final class Calls: @unchecked Sendable { var list: [(String, [String])] = [] }
        func run(_ exe: String, _ args: [String], timeout: TimeInterval) async throws -> (status: Int32, stdout: String) {
            calls.list.append((exe, args))
            return (args.contains { $0.hasSuffix("fail.zip") } ? 1 : 0, "")
        }
    }

    func testUnzipUsesTheSystemTool() async throws {
        let runner = FakeRunner()
        let dir = makeTempDir()
        let src = dir.appendingPathComponent("a.zip"), dest = dir.appendingPathComponent("a")
        try Self.makeZip([("x.txt", "x")]).write(to: src)
        try await ZipReader.unzip(src, to: dest, runner: runner)
        #if os(macOS)
        XCTAssertEqual(runner.calls.list.first?.0, "/usr/bin/ditto")
        XCTAssertEqual(runner.calls.list.first?.1, ["-x", "-k", src.path, dest.path])
        #else
        XCTAssertEqual(runner.calls.list.first?.0, "unzip")
        XCTAssertEqual(runner.calls.list.first?.1, ["-q", src.path, "-d", dest.path])
        #endif
        let failing = dir.appendingPathComponent("fail.zip")
        try Self.makeZip([("x.txt", "x")]).write(to: failing)
        do {
            try await ZipReader.unzip(failing, to: dest, runner: runner)
            XCTFail("a failing tool must throw")
        } catch {}
    }

    func testUnzipRefusesHostileEntries() async throws {
        let dir = makeTempDir()
        let cases: [(Data, ZipError)] = [
            (Self.makeZip([("ok.txt", "x"), ("/etc/evil", "x")]), .unsafePath("/etc/evil")),
            (Self.makeZip([("a/../../evil", "x")]), .unsafePath("a/../../evil")),
            (Self.makeZip([("..", "")]), .unsafePath("..")),
            (Self.makeZip([("link", "/etc/passwd")], unixModes: ["link": 0o120777]), .link("link")),
            (Self.makeZip([("link", "/etc/passwd")], unixModes: ["link": 0o120777], host: 19), .link("link")), // OS X host
        ]
        for (i, (data, expected)) in cases.enumerated() {
            let url = dir.appendingPathComponent("h\(i).zip")
            try data.write(to: url)
            let runner = FakeRunner()
            do {
                try await ZipReader.unzip(url, to: dir.appendingPathComponent("out\(i)"), runner: runner)
                XCTFail("case \(i) must be refused")
            } catch let error as ZipError {
                XCTAssertEqual(error, expected, "case \(i)")
            }
            XCTAssertTrue(runner.calls.list.isEmpty, "case \(i) never reaches the tool")
        }
        // A plain file whose mode is a regular file, and names merely containing dots, are fine.
        let fine = dir.appendingPathComponent("fine.zip")
        try Self.makeZip([("a..b/c.txt", "x"), ("f", "x")], unixModes: ["f": 0o100644]).write(to: fine)
        try await ZipReader.unzip(fine, to: dir.appendingPathComponent("fine"), runner: FakeRunner())
        XCTAssertEqual(try ZipReader.listing(fine).map { $0.isLink }, [false, false])
    }

    func testEndRecordMustReachTheEnd() throws {
        var data = Self.makeZip([("a.txt", "x")])
        data.append(contentsOf: [1, 2, 3]) // bytes after an end record that claims no comment
        let url = makeTempDir().appendingPathComponent("t.zip")
        try data.write(to: url)
        XCTAssertThrowsError(try ZipReader.entries(url))
    }

    func testUnzipForReal() async throws {
        #if os(macOS)
        let tool = "/usr/bin/ditto"
        #else
        let tool = "/usr/bin/unzip"
        #endif
        guard FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("no \(tool)") }
        let dir = makeTempDir()
        let zip = dir.appendingPathComponent("a.zip")
        try Self.makeZip([("x/", ""), ("x/y.txt", "hello")]).write(to: zip)
        let dest = dir.appendingPathComponent("a")
        try await ZipReader.unzip(zip, to: dest)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("x/y.txt"), encoding: .utf8), "hello")
    }
}
