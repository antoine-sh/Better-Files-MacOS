import SwiftUI
import FileOSCore

/// F14.2: the toolbar's and the right-click menu's Open In: installed terminals and editors, and Choose Defaults….
struct OpenInMenu: View {
    /// The right-clicked items; nil in the toolbar (the selection, else the folder).
    let urls: [URL]?
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            OpenInSection(title: "Terminal", kind: .terminal, urls: urls)
            OpenInSection(title: "Editor", kind: .editor, urls: urls)
            Divider()
            Button("Choose Defaults…", action: { model.showOpenInDefaults = true })
        } label: {
            Label("Open In", systemImage: "arrow.up.forward.app")
        }
        .help("Open In (⌥⇧⌘T terminal, ⌥⇧⌘E editor)")
    }
}

private struct OpenInSection: View {
    let title: String
    let kind: ExternalApp.Kind
    let urls: [URL]?
    @Environment(AppModel.self) private var model

    private var apps: [ExternalApp] { model.openInApps.filter { (a: ExternalApp) -> Bool in a.kind == kind } }

    var body: some View {
        Section(title) {
            if apps.isEmpty { Text("None installed") }
            ForEach(apps) { (app: ExternalApp) in
                Button(app.name, action: { open(app) })
            }
        }
    }

    private func open(_ app: ExternalApp) {
        let selection: [URL] = urls ?? model.targets
        let target: URL = OpenIn.target(kind: kind, selection: selection, cwd: model.pane.currentFolder)
        model.openIn(appID: app.id, target: target)
    }
}

/// Choose Defaults…: which terminal ⌥⇧⌘T and which editor ⌥⇧⌘E open.
struct OpenInDefaultsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var terminal = ""
    @State private var editor = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open In Defaults").font(.headline)
            DefaultPicker(title: "Terminal", kind: .terminal, choice: $terminal)
            DefaultPicker(title: "Editor", kind: .editor, choice: $editor)
            HStack {
                Spacer()
                Button("Done", action: { dismiss() }).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { load() }
        .onChange(of: terminal) { model.setDefaultApp(.terminal, id: terminal) }
        .onChange(of: editor) { model.setDefaultApp(.editor, id: editor) }
    }

    private func load() {
        terminal = model.defaultApp(.terminal)?.id ?? ""
        editor = model.defaultApp(.editor)?.id ?? ""
    }
}

private struct DefaultPicker: View {
    let title: String
    let kind: ExternalApp.Kind
    @Binding var choice: String
    @Environment(AppModel.self) private var model

    private var apps: [ExternalApp] { model.openInApps.filter { (a: ExternalApp) -> Bool in a.kind == kind } }

    var body: some View {
        Picker(title, selection: $choice) {
            if apps.isEmpty { Text("None installed").tag("") }
            ForEach(apps) { (app: ExternalApp) in Text(app.name).tag(app.id) }
        }
    }
}
