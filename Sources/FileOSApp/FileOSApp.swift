import SwiftUI
import AppKit
import FileOSCore

/// Asks before quitting with unsaved Markdown edits. Closing the window keeps them: the model lives as long as
/// the app, and a new window shows the page again.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        return model.mayQuit({ (name: String) -> LeaveAnswer in AppModel.askToSave(name) }) ? .terminateNow : .terminateCancel
    }
}

struct FileOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(home: AppModel.defaultHome)

    var body: some Scene {
        WindowGroup("FileOS") {
            MainWindow()
                .environment(model)
                .frame(minWidth: 760, minHeight: 460)
                .onAppear { delegate.model = model }
        }
        .commands { FileOSCommands(model: model) }
    }
}

@main @MainActor
enum AppMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            // Watchdog off the main thread, so even a main-thread hang fails CI instead of stalling it.
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                print("SELFTEST TIMEOUT")
                exit(1)
            }
            Task { @MainActor in
                let ok = await SelfTest.run(model: SelfTest.makeModel())
                exit(ok ? 0 : 1)
            }
            // Not dispatchMain(): it exits the main thread and drains the main queue on a worker,
            // which AppKit rejects ("NSWindow should only be instantiated on the main thread").
            // The main run loop drains the main queue (and so main-actor tasks) on the real main thread.
            while true { RunLoop.main.run() }
        }
        // `swift run` launches a bare executable; make it a regular, foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        FileOSApp.main()
    }
}
