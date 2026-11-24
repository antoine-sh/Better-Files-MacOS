import SwiftUI
import FileOSCore

/// The open Tidy plan and the choices made in its sheet (F9.4).
struct TidyState {
    let folder: URL
    var plan: TidyPlan
    var skip: Set<FileKind> = []
    var screenshotsToPictures = false
    var installersToTrash = false

    var count: Int { plan.count(skipping: skip) }
    var buttonTitle: String { count == 1 ? "Move 1 File" : "Move \(count) Files" }
}

extension AppModel {
    var tidyTitle: String { pane.url == downloadsURL ? "Tidy Downloads…" : "Tidy Folder…" }
    private var screenshotsFolder: URL { home.appendingPathComponent("Pictures/Screenshots") }

    /// ⌥⌘T: plans the open folder (or `folder`) and shows the sheet. Nothing moves yet.
    func beginTidy(_ folder: URL? = nil) {
        let dir: URL = FileOps.canonical(folder ?? pane.url)
        do {
            tidy = TidyState(folder: dir, plan: try Tidy.plan(dir, now: Date()))
            showTidy = true
        } catch {
            toast(error.localizedDescription, undoable: false)
        }
    }

    func setTidyOptions(screenshotsToPictures: Bool, installersToTrash: Bool) {
        guard var state = tidy else { return }
        do {
            state.plan = try Tidy.plan(state.folder, now: Date(), screenshotsToPictures: screenshotsToPictures ? screenshotsFolder : nil,
                                       installersToTrash: installersToTrash)
        } catch {
            toast(error.localizedDescription, undoable: false)
            return
        }
        state.screenshotsToPictures = screenshotsToPictures
        state.installersToTrash = installersToTrash
        tidy = state
    }

    func setTidySkip(_ kind: FileKind, _ skipped: Bool) {
        if skipped { tidy?.skip.insert(kind) } else { tidy?.skip.remove(kind) }
    }

    /// "Move 17 Files": one undo puts everything back and removes the folders Tidy made.
    func applyTidy() {
        guard let state = tidy else { return }
        showTidy = false
        tidy = nil
        do {
            let done: (moved: Int, undo: @Sendable () async -> RestoreResult) = try Tidy.apply(state.plan, skip: state.skip, trashDir: trashDir)
            reloadAll()
            guard done.moved > 0 else { return }
            undo.push("Tidy", done.undo)
            toast(Self.tidyToast(done.moved), undoable: true)
        } catch {
            reloadAll()
            toast("Couldn't tidy “\(state.folder.lastPathComponent)”: \(error.localizedDescription)", undoable: false)
        }
    }

    static func tidyToast(_ n: Int) -> String { n == 1 ? "Moved 1 file into folders" : "Moved \(n) files into folders" }

    /// Where a kind goes, as the sheet shows it ("PDFs", "Pictures › Screenshots", "Trash").
    func tidyDestination(_ kind: FileKind, _ state: TidyState) -> String {
        if kind == .installers && state.installersToTrash { return "Trash" }
        guard let dest = state.plan.byKind[kind]?.destination else { return "" }
        if dest.deletingLastPathComponent().path == state.folder.path { return dest.lastPathComponent }
        return PathBar.display(dest.path, home: home).replacingOccurrences(of: "/", with: " › ")
    }
}

struct TidySheet: View {
    @Environment(AppModel.self) private var model
    @State private var screenshotsToPictures = false
    @State private var installersToTrash = false

    var body: some View {
        if let state = model.tidy {
            content(state)
        }
    }

    private func content(_ state: TidyState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.folder == model.downloadsURL ? "Tidy Downloads" : "Tidy “\(state.folder.lastPathComponent)”")
                .font(.headline)
            if state.plan.moves.isEmpty {
                Text("There are no loose files to tidy.").foregroundStyle(.secondary)
            } else {
                kindList(state)
                options(state)
            }
            LeftList(left: state.plan.left)
            buttons(state)
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { sync(state) }
        .onChange(of: screenshotsToPictures) { optionsChanged() }
        .onChange(of: installersToTrash) { optionsChanged() }
    }

    private func kindList(_ state: TidyState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(kinds(state), id: \.self) { (kind: FileKind) in
                TidyKindRow(kind: kind, state: state)
            }
        }
    }

    /// Biggest first, like the plan's folders.
    private func kinds(_ state: TidyState) -> [FileKind] {
        state.plan.byKind.keys.sorted { (a: FileKind, b: FileKind) -> Bool in
            (state.plan.byKind[a]?.bytes ?? 0) > (state.plan.byKind[b]?.bytes ?? 0)
        }
    }

    @ViewBuilder private func options(_ state: TidyState) -> some View {
        if state.plan.byKind[.screenshots] != nil {
            Picker("Screenshots", selection: $screenshotsToPictures) {
                Text("With Images").tag(false)
                Text("Pictures › Screenshots").tag(true)
            }
        }
        if state.plan.byKind[.installers] != nil {
            Toggle("Move installers to the Trash", isOn: $installersToTrash)
        }
    }

    private func buttons(_ state: TidyState) -> some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel, action: { cancel() }).keyboardShortcut(.cancelAction)
            Button(state.buttonTitle, action: { model.applyTidy() })
                .keyboardShortcut(.defaultAction)
                .disabled(state.count == 0)
        }
    }

    private func sync(_ state: TidyState) {
        screenshotsToPictures = state.screenshotsToPictures
        installersToTrash = state.installersToTrash
    }

    private func optionsChanged() {
        model.setTidyOptions(screenshotsToPictures: screenshotsToPictures, installersToTrash: installersToTrash)
    }

    private func cancel() {
        model.showTidy = false
        model.tidy = nil
    }
}

/// "PDFs — 4 files, 12.1 MB → PDFs" with a tick to skip it.
private struct TidyKindRow: View {
    let kind: FileKind
    let state: TidyState
    @Environment(AppModel.self) private var model
    @State private var on = true

    var body: some View {
        Toggle(isOn: $on) {
            HStack {
                Text(kind.rawValue)
                Text(detail).foregroundStyle(.secondary)
                Spacer()
                Text("→ \(model.tidyDestination(kind, state))").foregroundStyle(.secondary)
            }
        }
        .onAppear { on = !state.skip.contains(kind) }
        .onChange(of: on) { model.setTidySkip(kind, !on) }
    }

    private var detail: String {
        let info: (count: Int, bytes: Int64, destination: URL)? = state.plan.byKind[kind]
        let count: Int = info?.count ?? 0
        return "\(count == 1 ? "1 file" : "\(count) files"), \(formatBytes(info?.bytes ?? 0))"
    }
}

/// "Left where they are": still downloading or just added.
private struct LeftList: View {
    let left: [(name: String, reason: String)]

    var body: some View {
        if !left.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Left where they are").font(.subheadline.weight(.semibold))
                ForEach(left.indices, id: \.self) { (i: Int) in
                    Text("\(left[i].name) — \(left[i].reason)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}
