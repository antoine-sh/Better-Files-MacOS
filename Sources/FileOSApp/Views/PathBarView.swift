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
            bar
            errorArea
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onChange(of: model.editingPath, initial: true) { (_: Bool, editing: Bool) in
            if editing { beginEditing() }
        }
    }

    @ViewBuilder private var bar: some View {
        if model.editingPath { editor } else { crumbs }
    }

    @ViewBuilder private var errorArea: some View {
        if let missing = model.pathError {
            PathErrorLine(name: missing.name, parent: missing.parent, suggestion: missing.suggestion)
        }
    }

    private func beginEditing() {
        text = model.displayPath(pane.url)
        suggestions = []
        choice = 0
    }

    private func startEditing() { model.editingPath = true }

    private var crumbURLs: [URL] {
        var urls: [URL] = []
        var url: URL = pane.url
        while true {
            urls.insert(url, at: 0)
            if url.path == "/" { break }
            url = FileOps.canonical(url.deletingLastPathComponent())
        }
        return urls
    }

    private var crumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            crumbRow
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: startEditing)
        .accessibilityAction(named: Text("Type a Path"), startEditing)
    }

    private var crumbRow: some View {
        let urls: [URL] = crumbURLs
        return HStack(spacing: 2) {
            ForEach(urls, id: \.self) { (url: URL) in
                Crumb(title: model.displayName(url), isFirst: url == urls.first, isCurrent: url == pane.url) {
                    model.open(url)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 2) {
            PathField(text: $text, onKey: handle)
                .frame(height: 22)
            SuggestionList(suggestions: suggestions, choice: choice)
        }
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

private struct Crumb: View {
    let title: String
    let isFirst: Bool
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if !isFirst {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Button(title, action: action)
                .buttonStyle(.plain)
                .fontWeight(weight)
                .padding(.horizontal, 4)
        }
    }

    private var weight: Font.Weight { isCurrent ? .semibold : .regular }
}

private struct SuggestionList: View {
    let suggestions: [String]
    let choice: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions.indices, id: \.self) { (index: Int) in
                SuggestionRow(text: suggestions[index], highlighted: index == choice)
            }
        }
        .font(.callout)
    }
}

private struct SuggestionRow: View {
    let text: String
    let highlighted: Bool

    var body: some View {
        Text(text)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
    }

    private var background: Color { highlighted ? Color.accentColor.opacity(0.25) : Color.clear }
}

/// F4.3: "There's no folder called “…” in …" with "Did you mean ~/…?" and "Create This Folder".
private struct PathErrorLine: View {
    let name: String
    let parent: URL
    let suggestion: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(PathBar.missingMessage(name: name, parent: parent))
            suggestionButton
            Button("Create This Folder", action: create)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .font(.callout)
    }

    @ViewBuilder private var suggestionButton: some View {
        if let suggestion {
            Button(Self.didYouMean(suggestion), action: goToSuggestion).buttonStyle(.link)
        }
    }

    static func didYouMean(_ suggestion: String) -> String { "Did you mean \(suggestion)?" }

    private func goToSuggestion() {
        if let suggestion, model.go(suggestion) { model.editingPath = false }
    }

    private func create() { model.createMissingFolder() }
    private func dismiss() { model.pathError = nil }
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
