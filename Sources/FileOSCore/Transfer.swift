import Foundation

public enum ClashChoice: Sendable { case keepBoth, replace, skip, stop }
public enum TransferMode: Sendable { case copy, move }

public struct Clash: Sendable {
    public let name: String
    public let destination: URL
    public let remaining: Int
    public init(name: String, destination: URL, remaining: Int) {
        self.name = name; self.destination = destination; self.remaining = remaining
    }
}

public struct TransferProgress: Sendable {
    public let currentName: String
    public let bytesDone: Int64, bytesTotal: Int64
    public let itemsDone: Int, itemsTotal: Int
}

public struct TransferResult: Sendable {
    public enum Action: Sendable { case copied, moved, replaced }
    public var results: [(from: URL, to: URL, action: Action)]
    public var stopped: Bool
    /// Set when an error ended the batch early; `results` and `undo` still cover what was done.
    public var failure: Error?
    public var undo: @Sendable () async -> RestoreResult
}

/// A failure, plus any replaced item that couldn't be put back after it.
public struct TransferFailure: LocalizedError {
    public let underlying: Error
    public let notRestored: [(url: URL, reason: String)]
    public init(underlying: Error, notRestored: [(url: URL, reason: String)]) { self.underlying = underlying; self.notRestored = notRestored }

    public var errorDescription: String? {
        let lost = notRestored.map { "Couldn’t put back “\($0.url.lastPathComponent)”: \($0.reason)" }
        return ([underlying.localizedDescription] + lost).joined(separator: ". ")
    }
}

/// Path used to compare locations: symlinks in the directory part resolved, case-folded on macOS (case-insensitive APFS).
private func comparable(_ url: URL) -> String {
    let p = url.standardizedFileURL.resolvingSymlinksInPath().path
    #if os(macOS)
    return p.lowercased()
    #else
    return p
    #endif
}

private func comparableItem(_ url: URL) -> String {
    // Resolve only the parent, so a symlink source is the link itself, not its target.
    comparable(url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent))
}

private func size(of url: URL) -> Int64 {
    guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
    if a[.type] as? FileAttributeType == .typeDirectory { return FileOps.directorySize(url).bytes }
    return (a[.size] as? NSNumber)?.int64Value ?? 0
}

public func transfer(
    _ sources: [URL], to dest: URL, mode: TransferMode, trashDir: URL?,
    resolve: @Sendable (Clash) async -> (ClashChoice, applyToAll: Bool),
    progress: @Sendable (TransferProgress) -> Void = { _ in },
    isCancelled: @Sendable () -> Bool = { false }
) async throws -> TransferResult {
    let destPath = comparable(dest)
    for s in sources {
        let sp = comparableItem(s)
        if destPath == sp || destPath.hasPrefix(sp + "/") { throw FileOSError.intoItself(s.lastPathComponent) }
    }
    let sizes = sources.map(size(of:))
    let bytesTotal = sizes.reduce(0, +)
    var results: [(from: URL, to: URL, action: TransferResult.Action)] = []
    var made: [Move] = [], replaced: [Move] = []
    var stopped = false, failure: Error?
    var remembered: ClashChoice?
    var bytesDone: Int64 = 0, itemsDone = 0
    func report(_ name: String) {
        progress(TransferProgress(currentName: name, bytesDone: bytesDone, bytesTotal: bytesTotal, itemsDone: itemsDone, itemsTotal: sources.count))
    }

    for (i, from) in sources.enumerated() {
        let name = from.lastPathComponent
        if isCancelled() { stopped = true; break }
        report(name)
        var to = dest.appendingPathComponent(name)
        var action: TransferResult.Action = mode == .move ? .moved : .copied
        if mode == .move && comparable(from.deletingLastPathComponent()) == destPath { // already here
            itemsDone += 1; bytesDone += sizes[i]; report(name); continue
        }
        var trashedForThis: [Move] = []
        do {
            if exists(to) {
                // Copying onto itself can only mean "make another one".
                let choice: ClashChoice
                if comparableItem(to) == comparableItem(from) { choice = .keepBoth }
                else if let remembered { choice = remembered }
                else {
                    let (c, all) = await resolve(Clash(name: name, destination: dest, remaining: sources.count - i - 1))
                    if all { remembered = c }
                    choice = c
                }
                switch choice {
                case .stop: stopped = true
                case .skip: break
                case .keepBoth: to = dest.appendingPathComponent(FileOps.uniqueName(in: dest, for: name))
                case .replace:
                    trashedForThis = try FileOps.trash([to], trashDir: trashDir)
                    replaced += trashedForThis
                    action = .replaced
                }
                if stopped { break }
                if choice == .skip { itemsDone += 1; bytesDone += sizes[i]; report(name); continue }
            }
            if mode == .move { try FileOps.move(from, to: to) }
            else {
                do { try FileManager.default.copyItem(at: from, to: to) }
                catch { // don't leave a half-written copy, but never remove what someone else put there
                    if !isFileExists(error, at: to) { try? FileManager.default.removeItem(at: to) }
                    throw error
                }
            }
        } catch {
            // The operation failed after the old item was trashed: put it back so nothing is lost.
            var notRestored: [(url: URL, reason: String)] = []
            if !trashedForThis.isEmpty {
                let back = FileOps.restore(trashedForThis)
                notRestored = back.failed
                replaced.removeLast(trashedForThis.count)
                // Still in the trash: keep it in the undo so it can be put back once the slot is free.
                replaced += trashedForThis.filter { m in back.failed.contains { $0.url == m.from } }
            }
            stopped = true; failure = notRestored.isEmpty ? error : TransferFailure(underlying: error, notRestored: notRestored)
            break
        }
        // Replaced an item this batch put there (two sources with one name): it isn't someone else's to put
        // back. A moved one's undo now fetches it from the Trash; a copy of ours just stays there.
        if let trashed = trashedForThis.first, let i = made.firstIndex(where: { $0.to.path == to.path }) {
            replaced.removeLast()
            if mode == .move { made[i] = Move(from: made[i].from, to: trashed.to) }
            else { made.remove(at: i); results.remove(at: i) }
        }
        made.append(Move(from: from, to: to))
        results.append((from, to, action))
        itemsDone += 1; bytesDone += sizes[i]; report(name)
    }

    let madeFinal = made, replacedFinal = replaced
    let undo: @Sendable () async -> RestoreResult = {
        var r = RestoreResult()
        if mode == .move {
            r = FileOps.restore(madeFinal.reversed())
        } else {
            for m in madeFinal.reversed() { // one by one: a copy the user already deleted must not block the rest
                do { _ = try FileOps.trash([m.to], trashDir: trashDir); r.restored.append(m.to) }
                catch { r.failed.append((m.to, error.localizedDescription)) }
            }
        }
        let back = FileOps.restore(replacedFinal.reversed()) // slots are free again now
        r.restored += back.restored; r.failed += back.failed
        return r
    }
    return TransferResult(results: results, stopped: stopped, failure: failure, undo: undo)
}
