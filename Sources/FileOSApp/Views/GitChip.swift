import SwiftUI
import FileOSCore

extension AppModel {
    /// F14.1: off the main actor, read-only.
    func gitStatus(_ folder: URL) async -> GitResult {
        let runner: any CommandRunner = self.runner
        return await Git.status(folder, runner: runner)
    }

    func copyBranchName(_ status: GitStatus) {
        Pasteboard.write(status.title)
        toast("Copied “\(status.title)”", undoable: false)
    }

    static func gitChipText(_ s: GitStatus) -> String {
        s.files.isEmpty || !s.countsKnown ? s.title : "\(s.title) · \(s.files.count)"
    }

    static func gitCounts(_ s: GitStatus) -> String {
        "\(s.changed) changed, \(s.added) new, \(s.deleted) deleted"
    }

    static let gitNotCounted = "Changes aren't counted here: this repository's settings would run programs."

    static let gitInstallCommand = "xcode-select --install"
}

/// F14.1: branch (or tag) and the uncommitted count at the end of the path bar; click for the panel.
struct GitChip: View {
    let result: GitResult
    let folder: URL
    let refresh: @MainActor () -> Void
    @State private var showPanel = false
    @Environment(AppModel.self) private var model

    var body: some View {
        switch result {
        case .notRepo:
            EmptyView()
        case .gitMissing:
            chip(text: "Git", symbol: "exclamationmark.triangle", label: "Git isn't installed")
        case .status(let s):
            chip(text: AppModel.gitChipText(s), symbol: "arrow.triangle.branch",
                 label: s.countsKnown ? "Git branch \(s.title), \(s.files.count) uncommitted" : "Git branch \(s.title)")
        }
    }

    private func chip(text: String, symbol: String, label: String) -> some View {
        Button(action: { open() }) {
            Label(text, systemImage: symbol)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
        .popover(isPresented: $showPanel, arrowEdge: .bottom) {
            GitPanel(result: result, folder: folder).environment(model)
        }
    }

    private func open() {
        refresh()
        showPanel = true
    }
}

private struct GitPanel: View {
    let result: GitResult
    let folder: URL
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder private var content: some View {
        switch result {
        case .notRepo:
            Text("This folder isn't a Git repository.")
        case .gitMissing:
            missing
        case .status(let s):
            GitStatusPanel(status: s, folder: folder)
        }
    }

    private var missing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Git isn't installed.").font(.headline)
            Text("Install Apple's developer tools in Terminal with:")
            Text(AppModel.gitInstallCommand).font(.body.monospaced()).textSelection(.enabled)
            Button("Copy Command", action: { copyCommand() })
        }
    }

    private func copyCommand() {
        Pasteboard.write(AppModel.gitInstallCommand)
        model.toast("Copied “\(AppModel.gitInstallCommand)”", undoable: false)
    }
}

private struct GitStatusPanel: View {
    let status: GitStatus
    let folder: URL
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(status.title, systemImage: "arrow.triangle.branch").font(.headline)
            if !status.countsKnown {
                Text(AppModel.gitNotCounted).foregroundStyle(.secondary)
            } else if status.files.isEmpty {
                Text("Everything is committed.").foregroundStyle(.secondary)
            } else {
                Text(AppModel.gitCounts(status))
                fileList
            }
            HStack {
                Button("Open in Terminal", action: { model.openIn(kind: .terminal, at: folder) })
                Button("Copy Branch Name", action: { model.copyBranchName(status) })
            }
        }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(status.files.prefix(300).enumerated()), id: \.offset) { (pair: (offset: Int, element: GitFile)) in
                    GitFileRow(file: pair.element)
                }
            }
        }
        .frame(maxHeight: 220)
    }
}

private struct GitFileRow: View {
    let file: GitFile

    var body: some View {
        HStack(spacing: 8) {
            Text(file.status)
                .font(.caption.monospaced())
                .foregroundStyle(color)
                .frame(width: 22, alignment: .leading)
            Text(file.path).font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        if file.status == "??" || file.status.contains("A") { return .green }
        if file.status.contains("D") { return .red }
        return .orange
    }
}
