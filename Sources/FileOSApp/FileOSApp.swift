import SwiftUI
import AppKit
import FileOSCore

/// Owns the app's one model, the Drop Shelf and its global shortcut (the self-test makes none of these).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var model = AppModel(home: AppModel.defaultHome)
    private var shelf: DropShelfController?
    private var hotKey: HotKey?
    private var services: ServiceProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model: AppModel = self.model
        model.applyAppearance()
        services = ServiceProvider(model: model)
        NSApp.servicesProvider = services
        let shelf = DropShelfController(model: model)
        shelf.watchDrags(model.settings.dropShelfOnDrag)
        self.shelf = shelf
        model.settingsApplied = { [weak shelf] (settings: AppSettings) in shelf?.watchDrags(settings.dropShelfOnDrag) }
        model.toggleShelf = { [weak shelf] in shelf?.toggle() }
        hotKey = HotKey(action: { [weak shelf] in shelf?.toggle() })
        if hotKey?.register(model.dropShelfShortcut) == false {
            model.toast("Couldn't use \(model.dropShelfShortcut) for the Drop Shelf: another app may be using it. Choose another shortcut in Settings.",
                        undoable: false)
        }
        // Settings reports a refused new shortcut itself, and the model re-registers the old one.
        model.dropShelfShortcutChanged = { [weak self] (combo: KeyCombo) -> Bool in self?.hotKey?.register(combo) ?? false }
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
        model.saveSession()
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
        Settings {
            SettingsView().modifier(AccentTint(model: delegate.model)).environment(delegate.model)
        }
        MenuBarExtra(isInserted: menuBarShown) {
            MenuBarPanel().environment(delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }

    /// Writes only a real change. SwiftUI sets `isInserted` back while it builds the scenes, and any write to
    /// `settings` (even an equal one) invalidates this body, so an unguarded binding re-ran the scene list
    /// forever and crashed at launch (stack overflow in `AppGraph.graphDidChange`).
    private var menuBarShown: Binding<Bool> {
        let model: AppModel = delegate.model
        return Binding(get: { model.settings.menuBar },
                       set: { (shown: Bool) in if model.settings.menuBar != shown { model.settings.menuBar = shown } })
    }
}

/// Reads the accent inside a view body, not `App.body`, so a settings change doesn't rebuild every scene.
private struct AccentTint: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View { content.tint(model.settings.accentColor) }
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
