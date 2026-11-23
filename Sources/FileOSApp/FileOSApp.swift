import SwiftUI
import Foundation

struct FileOSApp: App {
    var body: some Scene {
        WindowGroup { Text("FileOS") }
    }
}

@main @MainActor
enum AppMain {
    static func main() {
        // shortcut: smoke check is a no-op until the main window exists (Task 4)
        if CommandLine.arguments.contains("--self-test") { exit(0) }
        FileOSApp.main()
    }
}
