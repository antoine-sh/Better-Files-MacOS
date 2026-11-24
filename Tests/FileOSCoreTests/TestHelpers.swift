import Foundation
import XCTest
@testable import FileOSCore

func makeTempDir() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fileos-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
func touch(_ dir: URL, _ rel: String, _ content: String = "x", modified: Date? = nil) -> URL {
    let url = dir.appendingPathComponent(rel)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! content.write(to: url, atomically: true, encoding: .utf8)
    if let modified { try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    return url
}


/// Answers each command from a closure; records nothing and runs nothing.
struct ScriptedRunner: CommandRunner {
    let answer: @Sendable (String, [String]) throws -> (status: Int32, stdout: String)
    func run(_ exe: String, _ args: [String], timeout: TimeInterval) async throws -> (status: Int32, stdout: String) {
        try answer(exe, args)
    }
}
