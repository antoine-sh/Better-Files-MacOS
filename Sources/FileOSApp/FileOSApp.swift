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
            Button(model.showHidden ? "Hide Hidden Files" : "Show Hidden Files") { model.toggleHidden() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            Button("Back") { model.pane.back() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.pane.canGoBack)
            Button("Forward") { model.pane.forward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.pane.canGoForward)
            Button("Enclosing Folder") { model.page = .browser; model.pane.up() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!model.pane.canGoUp)
            Button("Open") { model.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            Button("Go to Folder…") { editPath() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Type a Path") { editPath() }
                .keyboardShortcut("l", modifiers: .command)
        }
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
