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

struct FileOSCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(hiddenTitle, action: toggleHidden)
                .keyboardShortcut(".", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            Button("Back", action: back)
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.pane.canGoBack)
            Button("Forward", action: forward)
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.pane.canGoForward)
            Button("Enclosing Folder", action: up)
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!model.pane.canGoUp)
            Button("Open", action: openSelection)
                .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            Button("Go to Folder…", action: editPath)
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Type a Path", action: editPath)
                .keyboardShortcut("l", modifiers: .command)
        }
    }

    private var hiddenTitle: String { model.showHidden ? "Hide Hidden Files" : "Show Hidden Files" }
    private func toggleHidden() { model.toggleHidden() }
    private func back() {
        model.page = .browser
        model.pane.back()
    }

    private func forward() {
        model.page = .browser
        model.pane.forward()
    }

    private func openSelection() {
        model.page = .browser
        model.openSelection()
    }

    private func up() {
        model.page = .browser
        model.pane.up()
    }

    private func editPath() {
        model.page = .browser
        model.editingPath = true
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
            dispatchMain() // services the main queue, which runs main-actor tasks
        }
        // `swift run` launches a bare executable; make it a regular, foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        FileOSApp.main()
    }
}
