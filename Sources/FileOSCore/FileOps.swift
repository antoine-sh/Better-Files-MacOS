import Foundation

public struct Entry: Sendable, Hashable, Identifiable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let size: Int64
    public let modified: Date
    public let created: Date
    public let added: Date
    public let kind: FileKind?
    public let isHidden: Bool
    public var id: String { url.path }

    public init(url: URL, name: String, isDirectory: Bool, isSymlink: Bool, size: Int64, modified: Date,
                created: Date, added: Date, kind: FileKind?, isHidden: Bool) {
        self.url = url; self.name = name; self.isDirectory = isDirectory; self.isSymlink = isSymlink
        self.size = size; self.modified = modified; self.created = created; self.added = added
        self.kind = kind; self.isHidden = isHidden
    }
}

public enum FileOSError: Error, Equatable, LocalizedError {
    case accessDenied(String), notFound(String), alreadyExists(String), intoItself(String), invalidName(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied(let p): return "You don’t have permission to open “\((p as NSString).lastPathComponent)”"
        case .notFound(let p): return "“\((p as NSString).lastPathComponent)” could not be found"
        case .alreadyExists(let n): return "“\(n)” already exists"
        case .intoItself(let n): return "Can't move “\(n)” into itself"
        case .invalidName: return "Invalid name"
        }
    }
}

public struct Move: Sendable, Hashable {
    public let from: URL
    public let to: URL
    public init(from: URL, to: URL) { self.from = from; self.to = to }
}

public struct RestoreResult: Sendable {
    public var restored: [URL]
    public var failed: [(url: URL, reason: String)]
    public init(restored: [URL] = [], failed: [(url: URL, reason: String)] = []) {
        self.restored = restored; self.failed = failed
    }
}

// Outside FileOps so the C rename(2) isn't shadowed by FileOps.rename.
private func posixRename(_ from: String, _ to: String) -> Int32 { rename(from, to) }


func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }

/// Maps Cocoa/POSIX permission and missing-file errors to FileOSError; other errors pass through.
private func mapped(_ error: Error, _ url: URL) -> Error {
    if error is FileOSError { return error }
    let ns = error as NSError
    let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? (ns.domain == NSPOSIXErrorDomain ? ns.code : 0)
    let cocoa = ns.domain == NSCocoaErrorDomain
    if (cocoa && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code))
        || posix == Int(EACCES) || posix == Int(EPERM) { return FileOSError.accessDenied(url.path) }
    if (cocoa && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code))
        || posix == Int(ENOENT) { return FileOSError.notFound(url.path) }
    return error
}

private func sameInode(_ a: URL, _ b: URL) -> Bool {
    guard let x = try? FileManager.default.attributesOfItem(atPath: a.path), let y = try? FileManager.default.attributesOfItem(atPath: b.path),
          let xi = x[.systemFileNumber] as? UInt, let yi = y[.systemFileNumber] as? UInt,
          let xd = x[.systemNumber] as? Int, let yd = y[.systemNumber] as? Int else { return false }
    return xi == yi && xd == yd
}

public enum FileOps {
    /// One spelling per folder: no "..", ".", or trailing-slash differences, so URLs compare with ==.
    /// (appendingPathComponent adds a trailing slash when the folder exists; standardizedFileURL keeps it.)
    public static func canonical(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

    public static func listDirectory(_ dir: URL, showHidden: Bool = false) throws -> [Entry] {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: dir.path) } catch { throw mapped(error, dir) }
        var out: [Entry] = []
        for name in names {
            let hidden = name.hasPrefix(".")
            if hidden && !showHidden { continue }
            let url = dir.appendingPathComponent(name)
            guard let link = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue } // vanished
            let isLink = link[.type] as? FileAttributeType == .typeSymbolicLink
            // Describe the target for symlinks; a broken link describes itself.
            let attrs = isLink ? ((try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)) ?? link) : link
            let isDir = attrs[.type] as? FileAttributeType == .typeDirectory
            let created = attrs[.creationDate] as? Date ?? .distantPast
            out.append(Entry(
                url: url, name: name, isDirectory: isDir, isSymlink: isLink,
                size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                modified: attrs[.modificationDate] as? Date ?? .distantPast,
                created: created,
                added: created, // shortcut: macOS "Date Added" is Spotlight metadata; creation date is close for downloads, upgrade if exactness matters
                kind: isDir ? nil : FileKind.of(name), isHidden: hidden))
        }
        return out
    }

    public static func uniqueName(in dir: URL, for name: String) -> String {
        if !exists(dir.appendingPathComponent(name)) { return name }
        let (base, ext) = splitExtension(name)
        var n = 2
        while exists(dir.appendingPathComponent("\(base) \(n)\(ext)")) { n += 1 }
        return "\(base) \(n)\(ext)"
    }

    public static func newFolder(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(uniqueName(in: dir, for: "untitled folder"))
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) } catch { throw mapped(error, dir) }
        return url
    }

    public static func duplicate(_ url: URL) throws -> URL {
        let dir = url.deletingLastPathComponent()
        let (base, ext) = splitExtension(url.lastPathComponent)
        let to = dir.appendingPathComponent(uniqueName(in: dir, for: "\(base) copy\(ext)"))
        do { try FileManager.default.copyItem(at: url, to: to) } catch { throw mapped(error, url) }
        return to
    }

    public static func makeAlias(_ url: URL) throws -> URL {
        let dir = url.deletingLastPathComponent()
        let (base, ext) = splitExtension(url.lastPathComponent)
        let to = dir.appendingPathComponent(uniqueName(in: dir, for: "\(base) alias\(ext)"))
        do {
            #if os(macOS)
            let data = try url.bookmarkData(options: .suitableForBookmarkFile)
            try URL.writeBookmarkData(data, to: to)
            #else
            try FileManager.default.createSymbolicLink(at: to, withDestinationURL: url)
            #endif
        } catch { throw mapped(error, url) }
        return to
    }

    public static func rename(_ url: URL, to newName: String) throws -> URL {
        if newName.isEmpty || newName == "." || newName == ".." || newName.contains("/") || newName.contains("\\") {
            throw FileOSError.invalidName(newName)
        }
        let to = url.deletingLastPathComponent().appendingPathComponent(newName)
        if to.path != url.path, exists(to) {
            // An existing target is only OK for a case-only rename of the same file (case-insensitive APFS).
            let caseOnly = url.lastPathComponent.caseInsensitiveCompare(newName) == .orderedSame
            if !(caseOnly && sameInode(url, to)) { throw FileOSError.alreadyExists(newName) }
        }
        if posixRename(url.path, to.path) != 0 {
            throw mapped(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), url)
        }
        return to
    }

    public static func trash(_ urls: [URL], trashDir: URL?) throws -> [Move] {
        var moves: [Move] = []
        var current = urls.first ?? URL(fileURLWithPath: "/")
        do {
            for from in urls {
                current = from
                if let trashDir {
                    try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
                    let to = trashDir.appendingPathComponent(uniqueName(in: trashDir, for: from.lastPathComponent))
                    try move(from, to: to)
                    moves.append(Move(from: from, to: to))
                } else {
                    #if os(macOS)
                    var result: NSURL?
                    try FileManager.default.trashItem(at: from, resultingItemURL: &result)
                    moves.append(Move(from: from, to: (result as URL?) ?? from))
                    #else
                    throw FileOSError.notFound("Trash") // no system Trash on Linux: callers pass trashDir
                    #endif
                }
            }
        } catch {
            _ = restore(moves) // don't leave a half-trashed selection the caller can't undo
            throw mapped(error, current)
        }
        return moves
    }

    public static func restore(_ moves: [Move]) -> RestoreResult {
        var result = RestoreResult()
        for m in moves {
            if exists(m.from) {
                result.failed.append((m.from, "An item with that name already exists"))
                continue
            }
            do {
                try FileManager.default.createDirectory(at: m.from.deletingLastPathComponent(), withIntermediateDirectories: true)
                try move(m.to, to: m.from)
                result.restored.append(m.from)
            } catch {
                result.failed.append((m.from, error.localizedDescription))
            }
        }
        return result
    }

    /// Never overwrites; falls back to copy + remove across volumes.
    public static func move(_ from: URL, to: URL) throws {
        if exists(to) { throw FileOSError.alreadyExists(to.lastPathComponent) }
        if posixRename(from.path, to.path) == 0 { return }
        let code = errno
        guard code == EXDEV else { throw mapped(NSError(domain: NSPOSIXErrorDomain, code: Int(code)), from) }
        try copyThenRemove(from, to: to)
    }

    /// The cross-volume move. `to` is known not to exist, so whatever is there after a failed copy is ours to remove.
    // shortcut: if removing the source fails midway, both the full copy and what's left of the source stay
    static func copyThenRemove(_ from: URL, to: URL,
                               copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) throws {
        do { try copy(from, to) } catch {
            try? FileManager.default.removeItem(at: to)
            throw mapped(error, from)
        }
        do { try FileManager.default.removeItem(at: from) } catch { throw mapped(error, from) }
    }

    public static func emptyTrash(_ trashDir: URL) throws -> (count: Int, bytes: Int64) {
        var count = 0, bytes: Int64 = 0
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: trashDir.path) } catch { throw mapped(error, trashDir) }
        for name in names {
            let url = trashDir.appendingPathComponent(name)
            guard let size = itemSize(url) else { continue } // vanished
            do { try FileManager.default.removeItem(at: url) } catch { throw mapped(error, url) }
            count += 1; bytes += size
        }
        return (count, bytes)
    }

    /// A missing Trash is empty; one that can't be listed (no Full Disk Access) throws, so it's never shown as empty.
    public static func trashSummary(_ trashDir: URL) throws -> (count: Int, bytes: Int64) {
        var count = 0, bytes: Int64 = 0
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: trashDir.path) } catch {
            let e = mapped(error, trashDir)
            if case FileOSError.notFound = e { return (0, 0) }
            throw e
        }
        for name in names {
            guard let size = itemSize(trashDir.appendingPathComponent(name)) else { continue }
            count += 1; bytes += size
        }
        return (count, bytes)
    }

    /// nil when the item no longer exists.
    private static func itemSize(_ url: URL) -> Int64? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        switch a[.type] as? FileAttributeType {
        case .typeDirectory: return directorySize(url).bytes
        case .typeSymbolicLink: return 0
        default: return (a[.size] as? NSNumber)?.int64Value ?? 0
        }
    }

    /// Never follows symlinks, so loops can't recurse; stops after `maxEntries` items.
    public static func directorySize(_ dir: URL, maxEntries: Int = 200_000) -> (bytes: Int64, items: Int) {
        var bytes: Int64 = 0, items = 0
        var stack = [dir]
        while let d = stack.popLast(), items < maxEntries {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: d.path) else { continue }
            for name in names {
                if items >= maxEntries { break }
                items += 1
                let url = d.appendingPathComponent(name)
                guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
                switch a[.type] as? FileAttributeType {
                case .typeDirectory: stack.append(url)
                case .typeSymbolicLink: break
                default: bytes += (a[.size] as? NSNumber)?.int64Value ?? 0
                }
            }
        }
        return (bytes, items)
    }

    public static func diskInfo(for url: URL) -> (total: Int64, free: Int64) {
        let a = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        return ((a?[.systemSize] as? NSNumber)?.int64Value ?? 0, (a?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0)
    }
}
