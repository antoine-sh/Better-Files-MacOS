import SwiftUI
import AppKit
import AVKit
import Quartz
import FileOSCore

/// Space (F6.1): floats over the window, above ⌘K, so a hit can be peeked without closing the palette.
struct PeekOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let url = model.peek.current {
            ZStack {
                Color.black.opacity(0.35)
                    .onTapGesture { model.peek.close() }
                    .accessibilityHidden(true)
                PeekPanel(peek: model.peek, url: url)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(radius: 16)
                    .padding(40)
            }
            .onAppear { model.installPaneKeyMonitor() } // ← → Return Space Esc
        }
    }
}

private struct PeekPanel: View {
    let peek: PeekModel
    let url: URL

    var body: some View {
        VStack(spacing: 0) {
            PeekHeader(peek: peek, url: url)
            Divider()
            HStack(spacing: 0) {
                PeekBody(content: peek.content, url: url)
                    .id(url) // a fresh preview or player per item
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if peek.showInfo {
                    Divider()
                    InfoDrawer(rows: InfoDrawer.rows(url: url, info: peek.info)).frame(width: 240)
                }
            }
        }
    }
}

// shortcut: no "Add to Workspace" button until workspaces exist (Task 9)
private struct PeekHeader: View {
    let peek: PeekModel
    let url: URL
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            IconButton(symbol: "chevron.left", label: "Previous", help: "Previous (←)", disabled: peek.index == 0,
                       action: { model.peekStep(-1) })
            IconButton(symbol: "chevron.right", label: "Next", help: "Next (→)", disabled: peek.index >= peek.urls.count - 1,
                       action: { model.peekStep(1) })
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                if peek.urls.count > 1 { Text(peek.position).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            buttons
        }
        .padding(10)
    }

    @ViewBuilder private var buttons: some View {
        Button("Open", action: { model.peekOpen() }).help("Open (Return)")
        OpenWithMenu(url: url)
        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
        IconButton(symbol: "folder", label: "Show in Finder", help: "Show in Finder", disabled: false,
                   action: { model.showInFinder([url]) })
        IconButton(symbol: peek.showInfo ? "info.circle.fill" : "info.circle", label: "Info", help: "Info",
                   disabled: false, action: { peek.toggleInfo() })
        IconButton(symbol: "xmark", label: "Close", help: "Close (Space or Esc)", disabled: false,
                   action: { peek.close() })
    }
}

private struct OpenWithMenu: View {
    let url: URL

    var body: some View {
        Menu("Open With") {
            ForEach(NSWorkspace.shared.urlsForApplications(toOpen: url), id: \.self) { (app: URL) in
                Button(FileManager.default.displayName(atPath: app.path), action: { open(with: app) })
            }
        }
        .fixedSize()
    }

    private func open(with app: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(),
                                completionHandler: nil)
    }
}

private struct PeekBody: View {
    let content: PeekContent
    let url: URL

    var body: some View {
        switch content {
        case .loading:
            ProgressView()
        case .quickLook:
            QuickLookPreview(url: url)
        case .media:
            PlayerView(url: url)
        case .text(let text):
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case let .zip(entries, encrypted):
            ZipListing(url: url, entries: entries, encrypted: encrypted)
        case let .folder(items, bytes):
            Summary(url: url, text: "\(AppModel.items(items)), \(formatBytes(bytes))")
        case .notice(let text):
            Summary(url: url, text: text)
        }
    }
}

private struct Summary: View {
    let url: URL
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            FileIcon(url: url, side: 96)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

/// F5.14: what is inside, and Unpack (password zips go to Archive Utility).
private struct ZipListing: View {
    let url: URL
    let entries: [String]
    let encrypted: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(AppModel.items(entries.count)).foregroundStyle(.secondary)
                Spacer()
                if encrypted {
                    Button("Open in Archive Utility", action: { model.openInArchiveUtility(url) })
                } else {
                    Button("Unpack", action: { unpack() })
                }
            }
            .padding(10)
            List(entries.indices, id: \.self) { (i: Int) in
                Text(entries[i]).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func unpack() {
        Task { await model.unpack(url) }
    }
}

/// F6.2.
struct InfoDrawer: View {
    let rows: [(label: String, value: String)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows.indices, id: \.self) { (i: Int) in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rows[i].label).font(.caption).foregroundStyle(.secondary)
                        Text(rows[i].value).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    // shortcut: no camera, colour profile, PDF, video or app details, "Where from" or tags yet (F6.2)
    static func rows(url: URL, info: FileInfoSummary?) -> [(label: String, value: String)] {
        guard let info else { return [] }
        var out: [(label: String, value: String)] = []
        out.append(("Kind", info.items != nil ? "Folder" : kindDescription(url.lastPathComponent)))
        out.append(("Size", formatBytes(info.size)))
        if let items = info.items { out.append(("Contains", AppModel.items(items))) }
        if let px = info.pixelSize { out.append(("Dimensions", "\(px.width) × \(px.height)")) }
        if let words = info.words { out.append(("Words", "\(words)")) }
        if let lines = info.lines { out.append(("Lines", "\(lines)")) }
        if let entries = info.zipEntries { out.append(("Contains", AppModel.items(entries.count))) }
        if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            out.append(("Modified", date.formatted(date: .abbreviated, time: .shortened)))
        }
        return out
    }
}

/// PDFs, images, Office/iWork: Quick Look's own view.
private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView(frame: .zero)
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {}

    // Not close(): a closed view aborts when torn down outside a window close; dropping the item frees the preview.
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.previewItem = nil }
}

/// Audio and video play as soon as they show.
private struct PlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        let player = AVPlayer(url: url)
        view.player = player
        player.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause() }
}
