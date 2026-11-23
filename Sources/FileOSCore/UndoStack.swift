import Foundation

public final class UndoStack: @unchecked Sendable {
    private struct Item { let label: String; let undo: @Sendable () async -> RestoreResult }
    private let lock = NSLock()
    private var items: [Item] = []
    private let limit = 100

    public init() {}

    public func push(_ label: String, _ undo: @escaping @Sendable () async -> RestoreResult) {
        lock.withLock {
            items.append(Item(label: label, undo: undo))
            if items.count > limit { items.removeFirst(items.count - limit) }
        }
    }

    public func undo() async -> (label: String, result: RestoreResult)? {
        let item = lock.withLock { items.popLast() }
        guard let item else { return nil }
        return (item.label, await item.undo())
    }

    public var canUndo: Bool { lock.withLock { !items.isEmpty } }
    public var topLabel: String? { lock.withLock { items.last?.label } }
}
