import SwiftUI
import AppKit
import FileOSCore

/// F4.1–F4.3: clickable crumbs; ⌘L / ⇧⌘G turns them into a field with Tab completion; missing-folder errors.
struct PathBarView: View {
    let pane: PaneModel
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var suggestions: [String] = []
    @State private var choice = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.editingPath { editor } else { crumbs }
            if let missing = model.pathError { errorLine(missing) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onChange(of: model.editingPath) { _, editing in
            if editing { text = model.displayPath(pane.url); suggestions = []; choice = 0 }
        }
    }

    private var crumbURLs: [URL] {
        var urls: [URL] = []
        var url = pane.url
        while true {
            urls.insert(url, at: 0)
            if url.path == "/" { break }
            url = url.deletingLastPathComponent()
        }
        return urls
    }

    private var crumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(crumbURLs.enumerated()), id: \.offset) { index, url in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    Button(model.displayName(url)) { model.open(url) }
                        .buttonStyle(.plain)
                        .fontWeight(url == pane.url ? .semibold : .regular)
                        .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.editingPath = true }
        .accessibilityAction(named: "Type a Path") { model.editingPath = true }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 2) {
            PathField(text: $text, onKey: handle)
                .frame(height: 22)
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, s in
                        Text(s)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == choice ? Color.accentColor.opacity(0.25) : .clear)
                    }
                }
                .font(.callout)
            }
        }
    }

    private func errorLine(_ missing: (name: String, parent: URL, suggestion: String?)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
            Text(PathBar.missingMessage(name: missing.name, parent: missing.parent))
            if let suggestion = missing.suggestion {
                Button("Did you mean \(suggestion)?") { model.go(suggestion) }.buttonStyle(.link)
            }
            Button("Create This Folder") { model.createMissingFolder() }
            Spacer()
            Button { model.pathError = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .font(.callout)
    }

    private func handle(_ key: PathField.Key) -> Bool {
        switch key {
        case .tab:
            let found = PathBar.complete(text, cwd: pane.url, home: model.home)
            if found.count == 1 {
                text = found[0] + "/"
                suggestions = []
            } else if !found.isEmpty {
                if suggestions == found {
                    text = found[choice] + "/" // second Tab takes the highlighted one
                    suggestions = []
                } else {
                    suggestions = found
                    choice = 0
                    let common = Self.commonPrefix(found)
                    if common.count > text.count { text = common }
                }
            }
            return true
        case .up, .down:
            guard !suggestions.isEmpty else { return false }
            choice = (choice + (key == .up ? -1 : 1) + suggestions.count) % suggestions.count
            text = suggestions[choice]
            return true
        case .escape:
            model.editingPath = false
            return true
        case .enter:
            if model.go(text) { model.editingPath = false }
            return true
        }
    }

    static func commonPrefix(_ strings: [String]) -> String {
        guard var prefix = strings.first else { return "" }
        for s in strings.dropFirst() {
            while !s.lowercased().hasPrefix(prefix.lowercased()) { prefix.removeLast() }
        }
        return prefix
    }
}

/// An NSTextField so Tab, arrows, Return and Esc reach us before the field editor uses them.
struct PathField: NSViewRepresentable {
    enum Key { case tab, up, down, escape, enter }
    @Binding var text: String
    var onKey: @MainActor (Key) -> Bool

    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PathField
        init(_ parent: PathField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)): return parent.onKey(.tab)
            case #selector(NSResponder.moveUp(_:)): return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onKey(.down)
            case #selector(NSResponder.cancelOperation(_:)): return parent.onKey(.escape)
            case #selector(NSResponder.insertNewline(_:)): return parent.onKey(.enter)
            default: return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field(string: text)
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.placeholderString = "Type a path, or a command like “code .”"
        field.setAccessibilityLabel("Path")
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }
}
