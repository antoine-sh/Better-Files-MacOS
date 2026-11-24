import SwiftUI
import AppKit
import FileOSCore

/// Owns the app's one model, the Drop Shelf and its global shortcut (the self-test makes none of these).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var model = AppModel(home: AppModel.defaultHome)
    private var shelf: DropShelfController?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model: AppModel = self.model
        let shelf = DropShelfController(model: model)
        shelf.watchDrags()
        self.shelf = shelf
        model.toggleShelf = { [weak shelf] in shelf?.toggle() }
        hotKey = HotKey(action: { [weak shelf] in shelf?.toggle() })
        registerHotKey(model.dropShelfShortcut)
        model.dropShelfShortcutChanged = { [weak self] (combo: KeyCombo) in self?.registerHotKey(combo) }
    }

    private func registerHotKey(_ combo: KeyCombo) {
        guard let hotKey, !hotKey.register(combo) else { return }
        model.toast("Couldn't use \(combo) for the Drop Shelf: another app may be using it. Choose another shortcut in Settings.",
                    undoable: false)
    }

    /// F1.6: closing the last window keeps FileOS running, so the Drop Shelf shortcut keeps working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Asks before quitting with unsaved Markdown edits. Closing the window keeps them: the model lives as long as
    /// the app, and a new window shows the page again.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.mayQuit({ (name: String) -> LeaveAnswer in AppModel.askToSave(name) }) ? .terminateNow : .terminateCancel
    }

    /// ⌘Q also stops the Drop Shelf and its shortcut (F1.6).
    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.stop()
        shelf?.stop()
    }
}

struct FileOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("FileOS", id: AppMain.mainWindowID) {
            MainWindow()
                .environment(delegate.model)
                .frame(minWidth: 760, minHeight: 460)
        }
        .commands { FileOSCommands(model: delegate.model) }
        MenuBarExtra {
            MenuBarPanel().environment(delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@main @MainActor
enum AppMain {
    nonisolated static let mainWindowID = "main"
    nonisolated static let isSelfTest = CommandLine.arguments.contains("--self-test")

    static func main() {
        if isSelfTest {
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
