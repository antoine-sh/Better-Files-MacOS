import SwiftUI
import AppKit
import QuickLookThumbnailing
import FileOSCore

enum Thumbnails {
    @MainActor static func icon(_ url: URL) -> NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    /// A real preview (first page, photo, video frame) from Quick Look, or nil when it has none.
    /// Not main-actor: Quick Look calls back on its own queue.
    static func preview(_ url: URL, side: CGFloat, scale: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale,
                                                   representationTypes: .thumbnail)
        return await withCheckedContinuation { (c: CheckedContinuation<CGImage?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { @Sendable (rep: QLThumbnailRepresentation?, _: Error?) in
                c.resume(returning: rep?.cgImage)
            }
        }
    }
}

/// An icon-view picture: Quick Look preview at Medium/Large, else the system icon; folders are glass
/// tiles with their item count (F3.3).
struct ThumbnailView: View {
    let entry: Entry
    let side: CGFloat
    let preview: Bool
    @State private var image: NSImage?

    var body: some View {
        picture
            .frame(width: side, height: side)
            .overlay(alignment: .bottomTrailing) { badge }
            .task(id: taskKey) { await load() }
    }

    private var taskKey: String { "\(entry.id)|\(side)|\(preview)|\(entry.modified.timeIntervalSince1970)" }

    @ViewBuilder private var picture: some View {
        if entry.isDirectory {
            GlassFolder(entry: entry, side: side)
        } else {
            Image(nsImage: image ?? Thumbnails.icon(entry.url))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var badge: some View {
        let ext: String = splitExtension(entry.name).ext
        if preview, !entry.isDirectory, !ext.isEmpty {
            Text(ext.dropFirst().uppercased())
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.thinMaterial, in: Capsule())
        }
    }

    private func load() async {
        guard preview, !entry.isDirectory else {
            image = nil
            return
        }
        let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
        guard let cg = await Thumbnails.preview(entry.url, side: side, scale: scale) else { return }
        image = NSImage(cgImage: cg, size: .zero)
    }
}

private struct GlassFolder: View {
    let entry: Entry
    let side: CGFloat
    @Environment(AppModel.self) private var model
    @State private var count: Int?
    private var url: URL { entry.url }

    var body: some View {
        ZStack {
            tile
            VStack(spacing: 2) {
                FolderGlyph(entry: entry, size: side * 0.42)
                countText
            }
        }
        .task(id: url) { loadCount() }
        .accessibilityHidden(true)
    }

    /// Settings > Appearance > Folder style: glass, flat (a tint of the folder colour), plain and Finder (none).
    @ViewBuilder private var tile: some View {
        switch model.settings.folderStyle {
        case .glass:
            RoundedRectangle(cornerRadius: side * 0.18).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: side * 0.18).strokeBorder(.white.opacity(0.25))
        case .flat:
            RoundedRectangle(cornerRadius: side * 0.18).fill((model.folderColor(url) ?? model.defaultFolderColor).opacity(0.2))
        case .plain, .finder:
            EmptyView()
        }
    }

    @ViewBuilder private var countText: some View {
        if side >= 56, let count {
            Text(AppModel.items(count)).font(.system(size: max(9, side * 0.1))).foregroundStyle(.secondary)
        }
    }

    private func loadCount() {
        // shortcut: counts on the main actor; move off-main if network volumes make it slow
        count = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.filter { (n: String) -> Bool in !n.hasPrefix(".") }.count
    }
}
