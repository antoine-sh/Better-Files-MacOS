import SwiftUI
import UniformTypeIdentifiers
import FileOSCore

/// F11.1 (⌥⌘N / +): name, description, colour, and how it starts; also Edit Workspace….
struct NewWorkspaceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = WorkspaceDraft()
    @State private var problem: String?
    @State private var importing = false

    private var editing: Bool { draft.editing != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing ? "Edit Workspace" : "New Workspace").font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $draft.name, prompt: Text("Taxes 2026"))
                TextField("Description", text: $draft.description, prompt: Text("Optional"))
                ColourRow(color: $draft.color)
                if !editing { start }
            }
            Text("Nothing is copied or moved: a workspace only lists things where they are.")
                .font(.caption).foregroundStyle(.secondary)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            buttons
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { draft = model.workspaceDraft }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { (result: Result<[URL], Error>) in
            if case .success(let urls) = result { draft.urls = urls }
        }
    }

    @ViewBuilder private var start: some View {
        Picker("Start with", selection: $draft.start) {
            ForEach(WorkspaceStart.allCases, id: \.self) { (s: WorkspaceStart) in Text(s.rawValue).tag(s) }
        }
        switch draft.start {
        case .empty:
            EmptyView()
        case .files:
            HStack {
                Button("Choose…", action: { importing = true })
                Text(draft.urls.isEmpty ? "Nothing chosen" : AppModel.items(draft.urls.count)).foregroundStyle(.secondary)
            }
        case .link:
            TextField("Link", text: $draft.link, prompt: Text("https://"))
                .onAppear { if draft.link.isEmpty, let copied = Pasteboard.string() { draft.link = copied } }
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel, action: { dismiss() }).keyboardShortcut(.cancelAction)
            Button(editing ? "Save" : "Create", action: { commit() })
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func commit() {
        problem = model.commitWorkspaceDraft(draft)
        if problem == nil { dismiss() }
    }
}

private struct ColourRow: View {
    @Binding var color: String

    var body: some View {
        LabeledContent("Colour") {
            HStack(spacing: 6) {
                ForEach(AppModel.workspaceColors, id: \.self) { (c: String) in
                    Button(action: { color = c }) {
                        Circle().fill(workspaceColor(c)).frame(width: 18, height: 18)
                            .overlay { if c == color { Circle().stroke(Color.primary, lineWidth: 2) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.capitalized)
                    .accessibilityAddTraits(c == color ? .isSelected : [])
                }
            }
        }
    }
}
