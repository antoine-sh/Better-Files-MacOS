import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FileOSCore

/// F16.1 Home (⇧⌘H): greeting, one search field that opens ⌘K, widgets, Recent Files; Customize shows or hides parts.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var customizing = false
    @State private var recents: [URL] = []
    @State private var inbox: (count: Int, latest: [URL]) = (0, [])

    private func shown(_ part: HomePart) -> Bool { part.isShown(in: model.homeParts) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TimelineView(.everyMinute) { (context: TimelineViewDefaultContext) in
                    Text(Greeting.text(hour: Calendar.current.component(.hour, from: context.date)))
                        .font(.largeTitle.weight(.semibold))
                }
                TextField("Search everything", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .frame(maxWidth: 520)
                    .onChange(of: query) { openSearch() }
                    .onSubmit { openSearch() }
                widgets
                if shown(.recentFiles) { RecentFiles(urls: recents) }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Home")
        .toolbar { customizeButton }
        .task { await load() }
    }

    private var customizeButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Customize", action: { customizing = true })
                .popover(isPresented: $customizing) { CustomizeHome().environment(model) }
        }
    }

    private var widgets: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], alignment: .leading, spacing: 14) {
            if shown(.worldClock) { WorldClockWidget() }
            if shown(.today) { TodayWidget() }
            if shown(.diskSpace) { DiskSpaceWidget() }
            if shown(.downloadsInbox) { DownloadsWidget(count: inbox.count, latest: inbox.latest) }
            if shown(.photoFrame) { PhotoFrameWidget(photo: recents.first { (u: URL) -> Bool in Self.isImage(u) }) }
            if shown(.pinnedFolder) { PinnedFolderWidget() }
        }
    }

    /// Typing hands the text to ⌘K, which shows the results and keeps the typing going.
    private func openSearch() {
        guard !query.isEmpty else { return }
        model.search.query = query
        query = ""
        model.openSearch()
    }

    private func load() async {
        let home: URL = model.home
        let downloads: URL = model.downloadsURL
        let places: [URL] = ["Desktop", "Documents", "Pictures"].map { (n: String) -> URL in home.appendingPathComponent(n) } + [downloads]
        let found: (recents: [URL], count: Int, latest: [URL]) = await Task.detached { () -> (recents: [URL], count: Int, latest: [URL]) in
            let recents: [URL] = Recents.latest(in: places, limit: 40, includeFolders: false)
            let count: Int = AppModel.itemCount(downloads) ?? 0
            return (recents, count, Recents.latest(in: [downloads], limit: 3, includeFolders: true))
        }.value
        recents = found.recents
        inbox = (found.count, found.latest)
    }

    nonisolated static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
}

private struct CustomizeHome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Show on Home").font(.headline)
            ForEach(HomePart.allCases, id: \.self) { (part: HomePart) in PartToggle(part: part) }
        }
        .padding(16)
        .frame(width: 220)
    }
}

/// @State + onChange rather than Binding(get:set:) (see SidebarView).
private struct PartToggle: View {
    let part: HomePart
    @Environment(AppModel.self) private var model
    @State private var on = true

    var body: some View {
        Toggle(part.title, isOn: $on)
            .onAppear { on = part.isShown(in: model.homeParts) }
            .onChange(of: on) { model.setHomePart(part, shown: on) }
    }
}

private struct Widget<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }
}

private struct WorldClockWidget: View {
    private static let places: [(String, String)] = [("London", "Europe/London"), ("New York", "America/New_York"),
                                                      ("Tokyo", "Asia/Tokyo")]

    var body: some View {
        Widget(title: "World Clock", symbol: "globe") {
            TimelineView(.everyMinute) { (context: TimelineViewDefaultContext) in
                VStack(alignment: .leading, spacing: 4) {
                    row("Here", TimeZone.current, context.date)
                    ForEach(Self.places.indices, id: \.self) { (i: Int) in
                        row(Self.places[i].0, TimeZone(identifier: Self.places[i].1) ?? .current, context.date)
                    }
                }
            }
        }
    }

    private func row(_ name: String, _ zone: TimeZone, _ date: Date) -> some View {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = zone
        return HStack {
            Text(name)
            Spacer()
            Text(date.formatted(style)).monospacedDigit()
        }
    }
}

private struct TodayWidget: View {
    var body: some View {
        Widget(title: "Today", symbol: "calendar") {
            TimelineView(.everyMinute) { (context: TimelineViewDefaultContext) in
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.date.formatted(.dateTime.weekday(.wide))).font(.title2.weight(.semibold))
                    Text(context.date.formatted(.dateTime.day().month(.wide).year()))
                }
            }
        }
    }
}

/// Read off the main actor: statfs on a slow or network volume must not stall rendering.
private struct DiskSpaceWidget: View {
    @Environment(AppModel.self) private var model
    @State private var disk: (total: Int64, free: Int64)?

    var body: some View {
        Widget(title: "Disk Space", symbol: "internaldrive") {
            if let disk {
                let used: Double = DiskLine.usedFraction(total: disk.total, free: disk.free)
                Text("\(formatBytes(disk.free)) available").font(.title3.weight(.semibold))
                ProgressView(value: used).tint(used >= 0.9 ? Color.orange : Color.accentColor)
                Text("\(formatBytes(disk.total - disk.free)) used of \(formatBytes(disk.total))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Free Up Space…", action: { model.page = .freeUpSpace })
        }
        .task { await load() }
    }

    private func load() async {
        let home: URL = model.home
        let info: (total: Int64, free: Int64) = await Task.detached { () -> (total: Int64, free: Int64) in
            FileOps.diskInfo(for: home)
        }.value
        disk = info
    }
}

private struct DownloadsWidget: View {
    let count: Int
    let latest: [URL]
    @Environment(AppModel.self) private var model

    var body: some View {
        Widget(title: "Downloads Inbox", symbol: "arrow.down.circle") {
            Text(AppModel.items(count)).font(.title3.weight(.semibold))
            ForEach(latest, id: \.self) { (url: URL) in
                HStack(spacing: 4) {
                    FileIcon(url: url, side: 16)
                    Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                }
            }
            Button("Open Downloads", action: { model.goTo("Downloads") })
        }
    }
}

/// The newest picture in Desktop, Documents, Downloads or Pictures.
private struct PhotoFrameWidget: View {
    let photo: URL?
    @Environment(AppModel.self) private var model
    @State private var image: NSImage?

    var body: some View {
        Widget(title: "Photo Frame", symbol: "photo") {
            if let image, let photo {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture { model.openItem(photo) }
                    .accessibilityLabel(photo.lastPathComponent)
            } else {
                Text("Your newest photo shows here.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: photo) { await load() }
    }

    private func load() async {
        image = nil
        guard let photo else { return }
        let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
        guard let cg = await Thumbnails.preview(photo, side: 240, scale: scale) else { return }
        image = NSImage(cgImage: cg, size: .zero)
    }
}

/// The first Drop Shelf pin, else the first Quick Access folder, else Documents.
private struct PinnedFolderWidget: View {
    @Environment(AppModel.self) private var model
    @State private var count: Int??

    private var folder: URL {
        model.shelfPinned.first ?? model.quickAccess.first ?? model.home.appendingPathComponent("Documents")
    }

    var body: some View {
        let folder: URL = self.folder
        return Widget(title: "Pinned Folder", symbol: "pin") {
            HStack {
                Image(nsImage: Thumbnails.icon(folder)).resizable().frame(width: 40, height: 40).accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(folder.lastPathComponent).font(.title3.weight(.semibold))
                    Text(countText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Open", action: { model.open(folder) })
        }
        .task(id: folder) { await loadCount(folder) }
    }

    private var countText: String {
        guard let count else { return "" }
        return count.map { (n: Int) -> String in AppModel.items(n) } ?? "Can't find it"
    }

    /// Off the main actor, like the shelf's counts.
    private func loadCount(_ folder: URL) async {
        count = .some(await Task.detached { () -> Int? in AppModel.itemCount(folder) }.value)
    }
}

private struct RecentFiles: View {
    let urls: [URL]
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Files").font(.title3.weight(.semibold))
            if urls.isEmpty {
                Text("Files you change in Desktop, Documents, Downloads and Pictures show here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(urls.prefix(10), id: \.self) { (url: URL) in
                Button(action: { model.openItem(url) }) {
                    HStack {
                        FileIcon(url: url, side: 20)
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(model.displayPath(url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onDrag { NSItemProvider(object: url as NSURL) }
                .contextMenu {
                    Button("Show in Finder", action: { model.showInFinder([url]) })
                    Button("Add to Holding", action: { model.addToHolding([url]) })
                }
            }
        }
    }
}
