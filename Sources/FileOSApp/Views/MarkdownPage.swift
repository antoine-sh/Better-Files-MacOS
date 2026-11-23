import SwiftUI
import AppKit
import Observation
import FileOSCore

enum MarkdownMode: String, CaseIterable { case preview = "Preview", edit = "Edit", split = "Split" }

/// One open .md file (F6.3): the text being edited and the text last saved.
@MainActor @Observable
final class MarkdownDocument {
    let url: URL
    var text: String
    private(set) var saved: String
    var mode: MarkdownMode = .preview

    init(url: URL, text: String) {
        self.url = url
        self.text = text
        saved = text
    }

    var name: String { url.lastPathComponent }
    var isEdited: Bool { text != saved }

    func revert() { text = saved }
    func markSaved(_ written: String) { saved = written }

    /// Undo of a save: the file holds `previous` again; edits typed since the save are kept.
    func undoSave(to previous: String, from written: String) {
        if text == written { text = previous }
        saved = previous
    }
}

// MARK: - Opening, saving, leaving

extension AppModel {
    /// Folders open in place, Markdown as a page (when it can be one), everything else in its app.
    func openItem(_ url: URL) {
        if Self.isBrowsableFolder(url) { return open(url) }
        if Markdown.isMarkdown(url.lastPathComponent) {
            Task { await openMarkdown(url) }
            return
        }
        _ = NSWorkspace.shared.open(url)
    }

    func openMarkdown(_ url: URL) async {
        if let doc = markdown, doc.isEdited, doc.url != url {
            page = .markdown
            toast("Save or revert “\(doc.name)” first", undoable: false)
            return
        }
        switch await Self.loadMarkdown(url) {
        case .success(let text):
            markdown = MarkdownDocument(url: url, text: text)
            page = .markdown
        case .failure(let error):
            toast("Can't show “\(url.lastPathComponent)” as a page: \(error.localizedDescription)", undoable: false)
            _ = NSWorkspace.shared.open(url)
        }
    }

    /// Off the main actor: the file can be up to 5 MB.
    nonisolated static func loadMarkdown(_ url: URL) async -> Result<String, MarkdownError> { Markdown.load(url) }

    /// Save ⌘S: writes atomically; undo puts the previous text back unless the file changed since.
    @discardableResult
    func saveMarkdown() -> Bool {
        guard let doc = markdown, doc.isEdited else { return true }
        let url: URL = doc.url
        let previous: String = doc.saved
        let written: String = doc.text
        do {
            try written.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            toast("Couldn't save “\(doc.name)”: \(error.localizedDescription)", undoable: false)
            return false
        }
        doc.markSaved(written)
        undo.push("Save") {
            // Never overwrite a change made after the save, in another app for instance.
            guard case .success(let now) = Markdown.load(url), now == written else {
                return RestoreResult(failed: [(url, "it changed after it was saved")])
            }
            do {
                try previous.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return RestoreResult(failed: [(url, error.localizedDescription)])
            }
            await doc.undoSave(to: previous, from: written)
            return RestoreResult(restored: [url])
        }
        toast("Saved “\(doc.name)”", undoable: true)
        return true
    }

    /// Called whenever `page` changes: leaving an edited page goes back to it and asks first.
    func pageChanged(from old: Page, to new: Page) {
        guard old == .markdown, new != .markdown, let doc = markdown else { return }
        guard doc.isEdited else {
            markdown = nil
            return
        }
        leavingTo = new
        page = .markdown
        showLeaveAlert = true
    }

    /// "Save" (stays if saving fails) or "Don't Save".
    func finishLeaving(save: Bool) {
        guard let target = leavingTo else { return }
        leavingTo = nil
        if save, !saveMarkdown() { return }
        markdown = nil
        page = target
    }

    static func leaveTitle(_ name: String) -> String { "Save the changes to “\(name)”?" }
}

// MARK: - Views

/// F6.3: Preview / Edit / Split, "On this page", and the "Edited" bar.
// shortcut: no full screen, cheat sheet or clickable task boxes yet; quitting with edits doesn't ask
struct MarkdownPage: View {
    @Bindable var doc: MarkdownDocument
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if doc.isEdited {
                EditedBar(doc: doc)
                Divider()
            }
            content
        }
        .navigationTitle(doc.name)
        .toolbar { toolbar }
    }

    @ViewBuilder private var content: some View {
        switch doc.mode {
        case .preview: MarkdownPreview(text: doc.text)
        case .edit: editor
        case .split: HSplitView { editor; MarkdownPreview(text: doc.text) }
        }
    }

    private var editor: some View {
        TextEditor(text: $doc.text)
            .font(.system(.body, design: .monospaced))
            .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            IconButton(symbol: "chevron.left", label: "Back", help: "Back to the folder", disabled: false,
                       action: { model.page = .browser })
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("Mode", selection: $doc.mode) {
                ForEach(MarkdownMode.allCases, id: \.self) { (m: MarkdownMode) in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)
        }
    }
}

private struct EditedBar: View {
    let doc: MarkdownDocument
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Text("Edited").fontWeight(.semibold)
            Spacer()
            Button("Revert", action: { doc.revert() })
            Button("Save", action: { model.saveMarkdown() }).keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.15))
    }
}

/// Each block rendered on its own; "On this page" scrolls to a heading.
// shortcut: re-parsed on every render; cache the blocks when big files feel slow
private struct MarkdownPreview: View {
    let text: String

    var body: some View {
        let blocks: [Markdown.Block] = Markdown.blocks(text)
        ScrollViewReader { (proxy: ScrollViewProxy) in
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(blocks.indices, id: \.self) { (i: Int) in
                            MarkdownBlockView(block: blocks[i]).id(Self.anchor(blocks[i], i))
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                OutlineList(blocks: blocks, proxy: proxy)
            }
        }
    }

    static func anchor(_ block: Markdown.Block, _ index: Int) -> String {
        if case let .heading(_, _, id) = block { return "h-" + id }
        return "b-\(index)"
    }
}

private struct OutlineList: View {
    let blocks: [Markdown.Block]
    let proxy: ScrollViewProxy

    private var headings: [(level: Int, text: String, id: String)] {
        blocks.compactMap { (b: Markdown.Block) -> (level: Int, text: String, id: String)? in
            if case let .heading(level, text, id) = b { return (level, text, id) }
            return nil
        }
    }

    var body: some View {
        let list = headings
        if !list.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("On this page").font(.headline)
                    ForEach(list.indices, id: \.self) { (i: Int) in
                        Button(list[i].text, action: { jump(list[i].id) })
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(.leading, CGFloat(list[i].level - 1) * 10)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 200)
        }
    }

    private func jump(_ id: String) {
        withAnimation { proxy.scrollTo("h-" + id, anchor: .top) }
    }
}

private struct MarkdownBlockView: View {
    let block: Markdown.Block

    var body: some View {
        switch block {
        case let .heading(level, text, _):
            Text(Self.inline(text)).font(Self.font(level)).padding(.top, 6)
        case .paragraph(let text):
            Text(Self.inline(text))
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(Self.inline(text))
            }
        case let .task(done, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: done ? "checkmark.square" : "square")
                    .accessibilityLabel(done ? "Done" : "To do")
                Text(Self.inline(text))
            }
        case .code(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func font(_ level: Int) -> Font {
        let fonts: [Font] = [.largeTitle, .title, .title2, .title3, .headline, .subheadline]
        return fonts[min(max(level, 1), 6) - 1]
    }
}
