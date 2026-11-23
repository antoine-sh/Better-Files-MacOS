import Foundation

/// A small JSON key-value file for app state. Reads once; every `set` rewrites the file atomically.
/// A missing or corrupt file, or a value of the wrong type, reads as the default.
public final class Store: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var values: [String: Any]

    public init(url: URL) {
        self.url = url
        let object = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        values = object as? [String: Any] ?? [:]
    }

    public func get<T: Codable>(_ key: String, default fallback: T) -> T {
        lock.withLock {
            guard let raw = values[key],
                  let data = try? JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed),
                  let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
            return value
        }
    }

    public func set<T: Codable>(_ key: String, _ value: T) {
        guard let raw = Self.raw(value) else { return }
        lock.withLock {
            values[key] = raw
            write()
        }
    }

    /// A list read element by element: one damaged element (or one written by a newer version) is skipped,
    /// not the whole list. nil only when the key is absent.
    public func getArray<T: Codable>(_ key: String, of type: T.Type) -> [T]? {
        lock.withLock {
            guard let raw = values[key] else { return nil }
            return (raw as? [Any] ?? []).compactMap { (element: Any) -> T? in Self.decode(T.self, element) }
        }
    }

    /// Writes `items`, keeping after them the stored elements that don't decode as `T`, so data this
    /// version can't read is never thrown away.
    public func setArray<T: Codable>(_ key: String, _ items: [T]) {
        guard let raw = Self.raw(items) as? [Any] else { return }
        lock.withLock {
            let unreadable: [Any] = (values[key] as? [Any] ?? []).filter { (element: Any) -> Bool in Self.decode(T.self, element) == nil }
            values[key] = raw + unreadable
            write()
        }
    }

    private static func raw<T: Codable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    private static func decode<T: Codable>(_ type: T.Type, _ raw: Any) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Call with the lock held.
    private func write() {
        guard let out = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // shortcut: a failed write keeps the value in memory only; surface it if state loss is ever reported
        try? out.write(to: url, options: .atomic)
    }
}
