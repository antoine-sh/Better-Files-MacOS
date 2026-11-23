import Foundation

public enum CommandError: Error, Equatable, Sendable {
    case notFound(String)
    case timedOut
}

public protocol CommandRunner: Sendable {
    func run(_ exe: String, _ args: [String], timeout: TimeInterval) async throws -> (status: Int32, stdout: String)
}

/// Runs a process with an argument array (never a shell), killing it after `timeout`.
public struct ProcessRunner: CommandRunner {
    static let searchDirs = ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"]

    public init() {}

    static func resolve(_ exe: String) -> URL? {
        let fm = FileManager.default
        if exe.contains("/") { return fm.isExecutableFile(atPath: exe) ? URL(fileURLWithPath: exe) : nil }
        return searchDirs.map { "\($0)/\(exe)" }.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public func run(_ exe: String, _ args: [String], timeout: TimeInterval) async throws -> (status: Int32, stdout: String) {
        guard let url = Self.resolve(exe) else { throw CommandError.notFound(exe) }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(with: Result { try Self.runSync(url, args, timeout: timeout) })
            }
        }
    }

    private final class Box: @unchecked Sendable {
        let process = Process()
        let pipe = Pipe()
        let exited = DispatchSemaphore(value: 0)
        let eof = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var buffer = Data()
        var output: Data { lock.withLock { buffer } }
        func append(_ d: Data) { lock.withLock { buffer.append(d) } }
        /// SIGKILL directly (Process.terminate() was ignored for ~5s on Linux Foundation).
        /// Returns whether the process was still running, i.e. whether the kill is the reason it ended.
        func stop() -> Bool {
            lock.withLock {
                guard process.isRunning else { return false }
                _ = Foundation.kill(process.processIdentifier, SIGKILL)
                return true
            }
        }
    }

    // The deadline bounds the whole call: a grandchild that inherited stdout can keep the pipe
    // open after the child is gone, so we never wait for EOF past the deadline.
    private static func runSync(_ url: URL, _ args: [String], timeout: TimeInterval) throws -> (status: Int32, stdout: String) {
        let box = Box()
        box.process.executableURL = url
        box.process.arguments = args
        box.process.standardOutput = box.pipe
        box.process.standardError = FileHandle.nullDevice
        box.process.standardInput = FileHandle.nullDevice
        box.process.terminationHandler = { _ in box.exited.signal() }
        do { try box.process.run() } catch { throw CommandError.notFound(url.lastPathComponent) }
        Thread.detachNewThread {
            let h = box.pipe.fileHandleForReading
            while case let d = h.availableData, !d.isEmpty { box.append(d) }
            box.eof.signal()
        }
        let deadline = DispatchTime.now() + timeout
        if box.exited.wait(timeout: deadline) == .timedOut {
            if box.stop() { throw CommandError.timedOut }
            box.exited.wait() // exited in the instant between the deadline and the kill: not a timeout
        }
        if box.eof.wait(timeout: deadline) == .timedOut { throw CommandError.timedOut }
        return (box.process.terminationStatus, String(decoding: box.output, as: UTF8.self))
    }
}
