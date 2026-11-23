import Foundation

public enum ZipError: Error, Equatable, LocalizedError {
    case notAZip
    case damaged
    case unsupported
    case toolFailed(Int32)
    /// An absolute name or one with a ".." component: it could write outside the new folder.
    case unsafePath(String)
    /// Links can point anywhere, so a later entry could write through one.
    case link(String)

    public var errorDescription: String? {
        switch self {
        case .notAZip: return "This isn't a zip archive"
        case .damaged: return "The archive is damaged"
        case .unsupported: return "This archive is too large to list"
        case .toolFailed(let status): return "Unpacking failed (\(status))"
        case .unsafePath(let name): return "it holds “\(name)”, which would land outside its folder"
        case .link(let name): return "it holds a link, “\(name)”"
        }
    }
}

public struct ZipEntry: Sendable, Equatable {
    public let name: String
    public let encrypted: Bool
    /// A Unix symlink (from the entry's external attributes).
    public let isLink: Bool
}

/// Lists a zip from its central directory without unpacking it (F5.14). Every length read from the file
/// is checked against what was read, so truncated or hostile archives throw instead of crashing.
public enum ZipReader {
    static let maxDirectoryBytes = 64 * 1024 * 1024

    public static func entries(_ url: URL) throws -> [String] {
        try listing(url).map { $0.name }
    }

    /// Whether any entry needs a password (those archives go to Archive Utility).
    public static func isEncrypted(_ url: URL) throws -> Bool {
        try listing(url).contains { $0.encrypted }
    }

    /// Throws for the first entry that could write outside the destination: absolute, "..", or a link.
    public static func checkSafe(_ entries: [ZipEntry]) throws {
        for e in entries {
            if e.isLink { throw ZipError.link(e.name) }
            let parts = e.name.split(separator: "/", omittingEmptySubsequences: false)
            if e.name.hasPrefix("/") || parts.contains("..") { throw ZipError.unsafePath(e.name) }
        }
    }

    /// Unpacks into `dest` with the system tool (`ditto` on macOS, `unzip` elsewhere), after refusing
    /// archives whose entries could land outside `dest`.
    public static func unzip(_ url: URL, to dest: URL, runner: CommandRunner = ProcessRunner()) async throws {
        try checkSafe(listing(url))
        #if os(macOS)
        let result = try await runner.run("/usr/bin/ditto", ["-x", "-k", url.path, dest.path], timeout: 600)
        #else
        let result = try await runner.run("unzip", ["-q", url.path, "-d", dest.path], timeout: 600)
        #endif
        if result.status != 0 { throw ZipError.toolFailed(result.status) }
    }

    public static func listing(_ url: URL) throws -> [ZipEntry] {
        guard let size = FileInfo.regularFileSize(url), size >= 22,
              let handle = try? FileHandle(forReadingFrom: url) else { throw ZipError.notAZip }
        defer { try? handle.close() }
        // The end record (22 bytes + a comment of up to 65535) is at the very end.
        let tailStart = UInt64(max(0, size - 22 - 65_535))
        try handle.seek(toOffset: tailStart)
        let tail = [UInt8](try handle.readToEnd() ?? Data())
        guard tail.count >= 22 else { throw ZipError.notAZip }
        // The real record's comment runs exactly to the end; a signature inside the comment doesn't.
        var e = tail.count - 22
        while e >= 0, !(tail[e] == 0x50 && tail[e + 1] == 0x4B && tail[e + 2] == 0x05 && tail[e + 3] == 0x06
                        && e + 22 + u16(tail, e + 20) == tail.count) { e -= 1 }
        guard e >= 0 else { throw ZipError.notAZip }
        let count = u16(tail, e + 10), cdSize = u32(tail, e + 12), cdOffset = u32(tail, e + 16)
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF { throw ZipError.unsupported } // shortcut: no Zip64; parse its locator when huge archives matter
        let endOffset = Int64(tailStart) + Int64(e)
        guard Int64(cdOffset) + Int64(cdSize) <= endOffset else { throw ZipError.damaged }
        guard cdSize <= maxDirectoryBytes else { throw ZipError.unsupported }
        try handle.seek(toOffset: UInt64(cdOffset))
        let cd = [UInt8](try handle.read(upToCount: cdSize) ?? Data())
        guard cd.count == cdSize else { throw ZipError.damaged }
        var out: [ZipEntry] = []
        out.reserveCapacity(count)
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, u32(cd, p) == 0x0201_4B50 else { throw ZipError.damaged }
            let flags = u16(cd, p + 8), n = u16(cd, p + 28), extra = u16(cd, p + 30), comment = u16(cd, p + 32)
            let next = p + 46 + n + extra + comment
            guard next <= cd.count else { throw ZipError.damaged }
            let raw = cd[(p + 46)..<(p + 46 + n)]
            let name = String(bytes: raw, encoding: .utf8) ?? String(bytes: raw, encoding: .isoLatin1) ?? ""
            let mode = u32(cd, p + 38) >> 16
            out.append(ZipEntry(name: name, encrypted: flags & 1 != 0, isLink: mode & 0o170000 == 0o120000))
            p = next
        }
        return out
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> Int { u16(b, i) | u16(b, i + 2) << 16 }
}
