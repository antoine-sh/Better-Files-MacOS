import SwiftUI
import FileOSCore

/// F5.7: Replace Text, Add Text, Name and Number, with a live preview; invalid rows are red with the reason.
struct BatchRenameSheet: View {
    let urls: [URL]
    @Environment(AppModel.self) private var model

    enum Kind: String, CaseIterable, Identifiable {
        case replace = "Replace Text", add = "Add Text", number = "Name and Number"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .replace
    @State private var find = ""
    @State private var replacement = ""
    @State private var added = ""
    @State private var before = false
    @State private var baseName = ""
    @State private var start = 1
    @State private var existing: Set<String> = []

    /// Items outside the first item's folder (expanded children) are left alone.
    private var dir: URL { urls.first?.deletingLastPathComponent() ?? model.pane.url }

    private var names: [String] {
        urls.filter { (u: URL) -> Bool in u.deletingLastPathComponent().path == dir.path }
            .map { (u: URL) -> String in u.lastPathComponent }
    }

    private var rule: Rename.BatchRule {
        switch kind {
        case .replace: return .replace(find: find, with: replacement)
        case .add: return .add(text: added, before: before)
        case .number: return .number(name: baseName, start: start)
        }
    }

    private var rows: [Rename.BatchRow] { Rename.plan(names, rule: rule, existing: existing) }

    private var changes: Int {
        rows.filter { (r: Rename.BatchRow) -> Bool in r.error == nil && r.from != r.to }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(names.count) Items").font(.headline)
            Picker("Rule", selection: $kind) {
                ForEach(Kind.allCases) { (k: Kind) in Text(k.rawValue).tag(k) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            fields
            BatchPreview(rows: rows)
            buttons
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .onAppear { loadExisting() }
    }

    @ViewBuilder private var fields: some View {
        switch kind {
        case .replace:
            TextField("Find", text: $find)
            TextField("Replace with", text: $replacement)
        case .add:
            TextField("Text", text: $added)
            Picker("Where", selection: $before) {
                Text("After Name").tag(false)
                Text("Before Name").tag(true)
            }
            .pickerStyle(.segmented)
        case .number:
            TextField("Name", text: $baseName, prompt: Text("Lisbon"))
            Stepper("Start at \(start)", value: $start, in: 0...99_999)
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel", action: { close() })
                .keyboardShortcut(.cancelAction)
            Button("Rename", action: { apply() })
                .keyboardShortcut(.defaultAction)
                .disabled(changes == 0)
        }
    }

    private func loadExisting() {
        existing = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    private func apply() {
        model.applyBatchRename(rows, in: dir)
        close()
    }

    private func close() { model.showBatchRename = false }
}

private struct BatchPreview: View {
    let rows: [Rename.BatchRow]

    var body: some View {
        List(rows.indices, id: \.self) { (i: Int) in
            line(rows[i])
        }
        .listStyle(.bordered)
    }

    private func line(_ row: Rename.BatchRow) -> some View {
        HStack {
            Text(row.from).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityLabel("becomes")
            Text(row.to).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            if let error = row.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .foregroundStyle(row.error == nil ? Color.primary : Color.red)
    }
}
