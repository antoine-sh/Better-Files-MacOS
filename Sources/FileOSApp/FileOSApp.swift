import SwiftUI
import AppKit
import FileOSCore

struct FileOSApp: App {
    @State private var model = AppModel(home: AppModel.defaultHome)

    var body: some Scene {
        WindowGroup("FileOS") {
            MainWindow()
                .environment(model)
                .frame(minWidth: 760, minHeight: 460)
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
