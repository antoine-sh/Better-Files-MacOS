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
        private let lock = NSLock()
        private var _timedOut = false
        var timedOut: Bool { lock.withLock { _timedOut } }
        // SIGKILL directly: Process.terminate() was ignored for ~5s on Linux Foundation.
        func stop() { lock.withLock { _timedOut = true }; if process.isRunning { _ = Foundation.kill(process.processIdentifier, SIGKILL) } }
    }

    private static func runSync(_ url: URL, _ args: [String], timeout: TimeInterval) throws -> (status: Int32, stdout: String) {
        let box = Box(), pipe = Pipe()
        box.process.executableURL = url
        box.process.arguments = args
        box.process.standardOutput = pipe
        box.process.standardError = FileHandle.nullDevice
        box.process.standardInput = FileHandle.nullDevice
        do { try box.process.run() } catch { throw CommandError.notFound(url.lastPathComponent) }
        let timer = DispatchWorkItem { box.stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // Reading to EOF before waiting avoids a full-pipe deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        box.process.waitUntilExit()
        timer.cancel()
        if box.timedOut { throw CommandError.timedOut }
        return (box.process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
