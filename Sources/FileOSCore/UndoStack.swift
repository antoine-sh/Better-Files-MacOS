import Foundation

public final class UndoStack: @unchecked Sendable {
    private struct Item { let label: String; let undo: @Sendable () async -> RestoreResult }
    private let lock = NSLock()
    private var items: [Item] = []
    private let limit = 100
    private var tail: Task<Void, Never>?

    public init() {}

    public func push(_ label: String, _ undo: @escaping @Sendable () async -> RestoreResult) {
        lock.withLock {
            items.append(Item(label: label, undo: undo))
            if items.count > limit { items.removeFirst(items.count - limit) }
        }
    }

    /// Undos run one at a time, newest first, however many are asked for at once: two restores racing over
    /// the same files could each see the other's half-done work.
    public func undo() async -> (label: String, result: RestoreResult)? {
        let run: Task<(label: String, result: RestoreResult)?, Never> = lock.withLock {
            let previous = tail
            let run = Task { () -> (label: String, result: RestoreResult)? in
                await previous?.value
                guard let item = self.pop() else { return nil }
                return (item.label, await item.undo())
            }
            tail = Task { _ = await run.value }
            return run
        }
        return await run.value
    }

    private func pop() -> Item? { lock.withLock { items.popLast() } }

    public var canUndo: Bool { lock.withLock { !items.isEmpty } }
    public var topLabel: String? { lock.withLock { items.last?.label } }
}
