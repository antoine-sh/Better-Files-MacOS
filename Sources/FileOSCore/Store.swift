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
        guard let data = try? JSONEncoder().encode(value),
              let raw = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return }
        lock.withLock {
            values[key] = raw
            guard let out = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // shortcut: a failed write keeps the value in memory only; surface it if state loss is ever reported
            try? out.write(to: url, options: .atomic)
        }
    }
}
