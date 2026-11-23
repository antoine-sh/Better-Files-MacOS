import Foundation

/// What the Peek info drawer shows for one item (F6.2).
public struct FileInfoSummary: Sendable {
    /// nil for folders.
    public var kind: FileKind?
    /// Bytes; for a folder, the total of what it holds (bounded, links not followed).
    public var size: Int64
    /// Folders only.
    public var items: Int?
    public var words: Int?
    public var lines: Int?
    public var pixelSize: (width: Int, height: Int)?
    public var zipEntries: [String]?
}

public enum FileInfo {
    /// Text larger than this gets no word/line counts (the same cap as ⌘K contents).
    public static let maxTextBytes = 2_000_000
    /// JPEG frame headers can sit behind large EXIF blocks; look this far in.
    static let maxHeaderBytes = 512 * 1024

    /// Reads the file and parses headers: call it off the main actor.
    public static func summary(_ url: URL) -> FileInfoSummary {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let type = attrs?[.type] as? FileAttributeType
        if type == .typeDirectory {
            let total = FileOps.directorySize(url)
            return FileInfoSummary(kind: nil, size: total.bytes, items: total.items)
        }
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let kind = FileKind.of(url.lastPathComponent)
        var out = FileInfoSummary(kind: kind, size: size)
        guard regularFileSize(url) != nil else { return out } // links, FIFOs, devices: nothing is opened
        switch kind {
        case .images, .screenshots:
            out.pixelSize = read(url, upTo: maxHeaderBytes).flatMap(pixelSize)
        case .archives:
            if url.pathExtension.lowercased() == "zip" { out.zipEntries = try? ZipReader.entries(url) }
        default:
            if let text = text(url) {
                out.words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
                out.lines = text.isEmpty ? 0 : text.filter { $0 == "\n" }.count + (text.hasSuffix("\n") ? 0 : 1)
            }
        }
        return out
    }

    /// The size of a regular file, or nil for folders, symlinks (not followed), FIFOs and devices.
    public static func regularFileSize(_ url: URL) -> Int64? {
        // attributesOfItem does not follow a final symlink, so this is the item itself.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// At most `count` bytes from the start of a regular file.
    public static func read(_ url: URL, upTo count: Int) -> Data? {
        guard regularFileSize(url) != nil, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: count) ?? Data()
    }

    /// UTF-8 text without NUL bytes, from a regular file of at most `limit` bytes.
    public static func text(_ url: URL, limit: Int = maxTextBytes) -> String? {
        guard let size = regularFileSize(url), size <= Int64(limit),
              let data = read(url, upTo: limit + 1), data.count <= limit, !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Width and height from a PNG, GIF or JPEG header.
    public static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](data)
        func be16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        func be32(_ i: Int) -> Int { be16(i) << 16 | be16(i + 2) }
        if b.count >= 24, b.starts(with: [0x89, 0x50, 0x4E, 0x47]), b[12...15].elementsEqual([0x49, 0x48, 0x44, 0x52]) {
            return (be32(16), be32(20))
        }
        if b.count >= 10, b.starts(with: [0x47, 0x49, 0x46, 0x38]) { // "GIF8", little-endian sizes
            return (Int(b[6]) | Int(b[7]) << 8, Int(b[8]) | Int(b[9]) << 8)
        }
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue } // fill byte
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            let length = be16(i + 2)
            guard length >= 2 else { return nil }
            // SOF0–SOF15 except DHT (C4), JPG (C8) and DAC (CC) carry the frame size.
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                guard i + 9 <= b.count else { return nil }
                return (be16(i + 7), be16(i + 5))
            }
            i += 2 + length
        }
        return nil
    }
}
