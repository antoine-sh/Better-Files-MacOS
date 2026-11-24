import SwiftUI
import AppKit
import FileOSCore

// MARK: - Model (F15.1–F15.3, F16.1, F5.15): the only writers of the shelf, holding, quick access, Home and
// quick-action state, and of their store keys.

extension AppModel {
    private func savePaths(_ key: String, _ urls: [URL]) {
        store.set(key, urls.map { (u: URL) -> String in u.path })
    }

    /// Folders among `urls` (the open folder when empty), canonical, minus those already in `list`.
    private func newFolders(_ urls: [URL], notIn list: [URL]) -> [URL] {
        let folders: [URL] = urls.isEmpty ? [pane.url] : urls.filter { (u: URL) -> Bool in Self.isBrowsableFolder(u) }
        var out: [URL] = []
        for url in folders.map({ (u: URL) -> URL in FileOps.canonical(u) }) where !list.contains(url) && !out.contains(url) {
            out.append(url)
        }
        return out
    }

    // MARK: Drop Shelf pins

    /// File > Pin to Drop Shelf, the item menu, quick actions and "Pin a folder".
    func pinToShelf(_ urls: [URL]) {
        let added: [URL] = newFolders(urls, notIn: shelfPinned)
        guard !added.isEmpty else { return }
        shelfPinned += added
        savePaths("dropShelf.pinned", shelfPinned)
        undo.push("Pin to Drop Shelf") {
            await self.unpinFromShelf(added)
            return RestoreResult(restored: added)
        }
        toast("Pinned \(Self.items(added.count)) to the Drop Shelf", undoable: true)
    }

    /// Only forgets the pin; the folder stays where it is.
    func unpinFromShelf(_ urls: [URL]) {
        shelfPinned.removeAll { (u: URL) -> Bool in urls.contains(u) }
        savePaths("dropShelf.pinned", shelfPinned)
    }

    /// A drop on a pinned folder: "Move here" (⌥ copies). Goes through the transfer queue, so clashes ask
    /// the same question as anywhere else, and the move is undoable from the shelf's result line.
    func dropShelfMove(_ urls: [URL], to folder: URL, copy: Bool) async {
        let sources: [URL] = urls.filter { (u: URL) -> Bool in u.isFileURL }
        guard !sources.isEmpty else { return }
        let mode: TransferMode = copy ? .copy : .move
        // Held files that move leave Holding (their paths are gone); undo puts them back in it.
        let held: [URL] = sources.map { (u: URL) -> URL in Self.heldURL(u) }.filter { (u: URL) -> Bool in holding.contains(u) }
        guard let outcome = await transfers.run(sources, to: folder, mode: mode) else { return }
        reloadAll()
        pruneHolding() // held files that just moved are no longer where holding points
        switch outcome {
        case .failure(let error):
            shelfResult = Toast(text: error.localizedDescription, undoable: false)
        case .success(let result):
            let names: [String] = result.results.map { (r: (from: URL, to: URL, action: TransferResult.Action)) -> String in
                r.from.lastPathComponent
            }
            if !names.isEmpty {
                let restore: @Sendable () async -> RestoreResult = result.undo
                undo.push(copy ? "Copy" : "Move") {
                    let restored: RestoreResult = await restore()
                    await self.addToHolding(held)
                    return restored
                }
                shelfResult = Toast(text: DropShelfText.result(names: names, folder: folder.lastPathComponent, copied: copy),
                                    undoable: true)
            }
            if let failure = result.failure { toast(failure.localizedDescription, undoable: false) }
            if names.isEmpty, let failure = result.failure {
                shelfResult = Toast(text: failure.localizedDescription, undoable: false)
            }
        }
    }

    /// The result line's Undo.
    func undoShelfResult() {
        shelfResult = nil
        performUndo()
    }

    /// "Open in FileOS" (shelf, menu bar): shows a window (opening one if every window was closed, F1.6).
    func openInFileOS(_ url: URL) {
        showMainWindow()
        openItem(url)
    }

    /// Brings a FileOS window forward, or opens one when none is left (the app keeps running, F1.6).
    func showMainWindow() {
        let windows: [NSWindow] = NSApp.windows.filter { (w: NSWindow) -> Bool in
            (w.isVisible || w.isMiniaturized) && !(w is NSPanel) && w.canBecomeMain
        }
        if let window = windows.first {
            NSApp.activate()
            if window.isMiniaturized { window.deminiaturize(nil) }
            if NSApp.mainWindow == nil { window.makeKeyAndOrderFront(nil) }
        } else if let openMainWindow {
            NSApp.activate()
            openMainWindow()
        }
    }

    /// The pinned folder's item count, or nil when it can't be read (moved, deleted, no access).
    nonisolated static func itemCount(_ folder: URL) -> Int? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return names.filter { (n: String) -> Bool in !n.hasPrefix(".") }.count
    }

    // MARK: Holding (F15.2): paths only, nothing is copied or moved.

    /// One spelling per held item; unlike `FileOps.canonical`, a file keeps a file URL (no trailing slash) for drags.
    nonisolated static func heldURL(_ url: URL) -> URL { URL(fileURLWithPath: url.standardizedFileURL.path) }

    func addToHolding(_ urls: [URL]) {
        var added: [URL] = []
        for url in urls where url.isFileURL && FileManager.default.fileExists(atPath: url.path) {
            let u: URL = Self.heldURL(url)
            if !holding.contains(u) && !added.contains(u) { added.append(u) }
        }
        guard !added.isEmpty else { return }
        holding += added
        savePaths("holding", holding)
    }

    func removeFromHolding(_ urls: [URL]) {
        holding.removeAll { (u: URL) -> Bool in urls.contains(u) }
        savePaths("holding", holding)
    }

    func clearHolding() {
        holding = []
        savePaths("holding", holding)
    }

    func pruneHolding() {
        let kept: [URL] = holding.filter { (u: URL) -> Bool in FileManager.default.fileExists(atPath: u.path) }
        if kept.count != holding.count { removeFromHolding(holding.filter { (u: URL) -> Bool in !kept.contains(u) }) }
    }

    // MARK: Quick access (F15.3 menu bar, F3.10 "Add to Quick Access")

    func addToQuickAccess(_ urls: [URL]) {
        let added: [URL] = newFolders(urls, notIn: quickAccess)
        guard !added.isEmpty else { return }
        quickAccess += added
        savePaths("quickAccess", quickAccess)
        undo.push("Add to Quick Access") {
            await self.removeFromQuickAccess(added)
            return RestoreResult(restored: added)
        }
        toast("Added \(Self.items(added.count)) to Quick Access", undoable: true)
    }

    func removeFromQuickAccess(_ urls: [URL]) {
        quickAccess.removeAll { (u: URL) -> Bool in urls.contains(u) }
        savePaths("quickAccess", quickAccess)
    }

    // MARK: Home and quick actions settings

    func setHomePart(_ part: HomePart, shown: Bool) {
        homeParts[part.rawValue] = shown
        store.set("home.widgets", homeParts)
    }

    /// F16.1: a new sticker lands in a free-ish spot under the greeting; Undo takes it off.
    func addSticker(_ emoji: String) {
        let sticker = Sticker(emoji: emoji, x: Double(420 + 50 * (stickers.count % 8)), y: 40)
        stickers.append(sticker)
        store.setArray("home.stickers", stickers)
        undo.push("Add Sticker") {
            await self.takeOffSticker(sticker.id)
            return RestoreResult()
        }
        toast("Added a sticker", undoable: true)
    }

    func removeSticker(_ id: UUID) {
        guard let index = stickers.firstIndex(where: { (s: Sticker) -> Bool in s.id == id }) else { return }
        let sticker: Sticker = stickers[index]
        takeOffSticker(id)
        undo.push("Remove Sticker") {
            await self.putBackSticker(sticker, at: index)
            return RestoreResult()
        }
        toast("Removed a sticker", undoable: true)
    }

    func moveSticker(_ id: UUID, x: Double, y: Double) {
        guard let index = stickers.firstIndex(where: { (s: Sticker) -> Bool in s.id == id }) else { return }
        stickers[index].x = max(0, x)
        stickers[index].y = max(0, y)
        store.setArray("home.stickers", stickers)
    }

    private func takeOffSticker(_ id: UUID) {
        stickers.removeAll { (s: Sticker) -> Bool in s.id == id }
        store.setArray("home.stickers", stickers)
    }

    private func putBackSticker(_ sticker: Sticker, at index: Int) {
        guard !stickers.contains(where: { (s: Sticker) -> Bool in s.id == sticker.id }) else { return }
        stickers.insert(sticker, at: min(index, stickers.count))
        store.setArray("home.stickers", stickers)
    }

    /// Settings > Quick Actions: the chosen order; only the first six show.
    func setQuickActions(_ list: [QuickAction]) {
        store.set("quickActions", list.map { (a: QuickAction) -> String in a.rawValue })
        quickActions = QuickAction.ordered(list.map { (a: QuickAction) -> String in a.rawValue })
    }

    // MARK: The global shortcut

    var dropShelfShortcut: KeyCombo { shortcuts["dropShelf"] ?? KeyCombo(key: "space", option: true) }

    /// nil when the new shortcut was registered and saved; otherwise why not (the old one stays in use).
    @discardableResult
    func setDropShelfShortcut(_ combo: KeyCombo) -> String? {
        guard combo.canBeGlobal else { return "The Drop Shelf shortcut must include ⌘, ⌥ or ⌃" }
        if Shortcuts.conflict(in: shortcuts, action: "dropShelf", combo: combo) != nil {
            return "\(combo) is already used by another command"
        }
        if let register = dropShelfShortcutChanged, !register(combo) {
            _ = register(dropShelfShortcut) // keep the shortcut that worked
            return "Couldn't use \(combo): another app may be using it"
        }
        var user: [String: KeyCombo] = store.get("shortcuts", default: [String: KeyCombo]())
        user["dropShelf"] = combo
        store.set("shortcuts", user)
        shortcuts["dropShelf"] = combo
        return nil
    }
}

// MARK: - The shelf

/// F15.1: pinned folders five per row with item counts and keys 1–9, the amber Holding well (F15.2), and the
/// result line with Undo.
struct DropShelfView: View {
    @Environment(AppModel.self) private var model
    /// Asks the panel to fit the content again.
    let resized: @MainActor () -> Void

    private var layoutKey: String {
        "\(model.shelfPinned.count)|\(model.holding.count)|\(model.shelfResult?.id.uuidString ?? "")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            PinnedFolders()
            HoldingWell()
            resultLine
        }
        .padding(14)
        .frame(width: DropShelfController.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onChange(of: layoutKey) { Task { @MainActor in resized() } }
    }

    private var header: some View {
        HStack {
            Text("Drop Shelf").font(.headline)
            Text(model.dropShelfShortcut.description).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(action: { pinAFolder() }) { Label("Pin a folder", systemImage: "pin") }
        }
    }

    @ViewBuilder private var resultLine: some View {
        if let result = model.shelfResult {
            HStack {
                Text(result.text).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
                if result.undoable { Button("Undo", action: { model.undoShelfResult() }) }
            }
        }
    }

    private func pinAFolder() {
        model.shelfModalOpen = true
        defer { model.shelfModalOpen = false }
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Pin"
        if panel.runModal() == .OK { model.pinToShelf(panel.urls) }
    }
}

private struct PinnedFolders: View {
    @Environment(AppModel.self) private var model
    private let columns: [GridItem] = Array(repeating: GridItem(.fixed(96), spacing: 8), count: 5)

    var body: some View {
        if model.shelfPinned.isEmpty {
            Text("Pin folders here, then drop files on them to move them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(Array(model.shelfPinned.enumerated()), id: \.element) { (pair: (offset: Int, element: URL)) in
                    ShelfTile(url: pair.element, number: pair.offset < 9 ? pair.offset + 1 : nil)
                }
            }
        }
    }
}

private struct ShelfTile: View {
    let url: URL
    let number: Int?
    @Environment(AppModel.self) private var model
    @State private var targeted = false
    /// Read off the main actor (a big or slow folder must not stall drag hovering); nil until read.
    @State private var count: Int??

    private var countText: String {
        guard let count else { return "" }
        return count.map { (n: Int) -> String in AppModel.items(n) } ?? "Can't find it"
    }

    /// Read again after each shelf drop.
    private var countKey: String { "\(url.path)|\(model.shelfResult?.id.uuidString ?? "")" }

    private func loadCount() async {
        let folder: URL = url
        count = .some(await Task.detached { () -> Int? in AppModel.itemCount(folder) }.value)
    }

    private var fill: Color { targeted ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.04) }

    private var label: String {
        let base: String = "\(url.lastPathComponent), \(countText)"
        return number.map { (n: Int) -> String in "\(n), \(base)" } ?? base
    }

    private var tile: some View {
        VStack(spacing: 3) {
            Image(nsImage: Thumbnails.icon(url))
                .resizable()
                .frame(width: 44, height: 44)
                .overlay(alignment: .topLeading) { badge }
                .accessibilityHidden(true)
            Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(targeted ? "Move here" : countText).font(.caption2).foregroundStyle(targeted ? Color.accentColor : Color.secondary)
        }
        .frame(width: 92, height: 88)
        .background(RoundedRectangle(cornerRadius: 10).fill(fill))
    }

    var body: some View {
        tile
        .task(id: countKey) { await loadCount() }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.openInFileOS(url) }
        .dropDestination(for: URL.self, action: { (urls: [URL], _: CGPoint) -> Bool in
            drop(urls)
            return true
        }, isTargeted: { (on: Bool) in targeted = on })
        .contextMenu {
            Button("Open in FileOS", action: { model.openInFileOS(url) })
            Button("Show in Finder", action: { model.showInFinder([url]) })
            Divider()
            Button("Unpin", action: { model.unpinFromShelf([url]) })
        }
        .help("Drop to move here; hold ⌥ to copy")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var badge: some View {
        if let number {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 4)
                .background(.thinMaterial, in: Capsule())
        }
    }

    private func drop(_ urls: [URL]) {
        let copy: Bool = NSEvent.modifierFlags.contains(.option)
        let folder: URL = url
        Task { await model.dropShelfMove(urls, to: folder, copy: copy) }
    }
}

/// F15.2: the amber well. Drops remember paths only; drag one file out, or "Drag All" to move every held file.
struct HoldingWell: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Holding", systemImage: "tray.full").font(.subheadline.weight(.semibold))
                Spacer()
                if !model.holding.isEmpty {
                    DragAllHandle(urls: model.holding)
                        .frame(width: 80, height: 22)
                        .overlay { Text("Drag All").font(.caption).allowsHitTesting(false) }
                        .help("Drag every held file to an app or a folder")
                    Button("Clear", action: { model.clearHolding() })
                }
            }
            content
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(targeted ? 0.35 : 0.16)))
        .dropDestination(for: URL.self, action: { (urls: [URL], _: CGPoint) -> Bool in
            model.addToHolding(urls)
            return true
        }, isTargeted: { (on: Bool) in targeted = on })
    }

    @ViewBuilder private var content: some View {
        if model.holding.isEmpty {
            Text("Drop files here to hold them. Nothing moves until you drag them out.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.holding, id: \.self) { (url: URL) in HeldItem(url: url) }
                }
            }
        }
    }
}

private struct HeldItem: View {
    let url: URL
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            FileIcon(url: url, side: 18)
            Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: 140)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.thinMaterial, in: Capsule())
        .onDrag { NSItemProvider(object: url as NSURL) }
        .contextMenu {
            Button("Show in Finder", action: { model.showInFinder([url]) })
            Button("Remove from Holding", action: { model.removeFromHolding([url]) })
        }
    }
}

/// Starts one AppKit drag carrying every held file (SwiftUI's onDrag carries a single item provider).
private struct DragAllHandle: NSViewRepresentable {
    let urls: [URL]

    func makeNSView(context: Context) -> DragAllView { DragAllView() }

    func updateNSView(_ view: DragAllView, context: Context) { view.urls = urls }
}

final class DragAllView: NSView, NSDraggingSource {
    var urls: [URL] = []

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func mouseDown(with event: NSEvent) {} // keep the press, so mouseDragged comes here

    override func mouseDragged(with event: NSEvent) {
        let items: [NSDraggingItem] = urls.map { (url: URL) -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(bounds, contents: Thumbnails.icon(url))
            return item
        }
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: event, source: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .link, .generic]
    }
}

// MARK: - The panel

/// Floating and non-activating: showing it never takes focus from the frontmost app. It becomes key only when
/// the user opens it with the shortcut (so 1–9 and Esc reach it) or clicks into it.
final class ShelfPanel: NSPanel {
    var onKey: (@MainActor (NSEvent) -> Bool)?
    var onResignKey: (@MainActor () -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let onKey, onKey(event) { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// Owns the panel and the drag watcher. Created by the app delegate only; the self-test never makes one.
@MainActor
final class DropShelfController {
    static let width: CGFloat = 560
    private let model: AppModel
    private var panel: ShelfPanel?
    private var host: NSHostingView<AnyView>?
    /// Shown because a drag started: it hides again after the drag, and it was never made key.
    private var shownByDrag = false
    private var monitors: [Any] = []
    private let dragBoard = NSPasteboard(name: .drag)
    private var lastDragChange: Int
    private var hideTask: Task<Void, Never>?
    private var hiding = false

    init(model: AppModel) {
        self.model = model
        lastDragChange = dragBoard.changeCount
    }

    var isShown: Bool { panel?.isVisible == true }

    /// The global shortcut.
    func toggle() {
        if isShown && !shownByDrag { hide() } else { show(takeKeys: true) }
    }

    func show(takeKeys: Bool) {
        hideTask?.cancel()
        let panel: ShelfPanel = self.panel ?? makePanel()
        fit(panel)
        if takeKeys {
            panel.makeKeyAndOrderFront(nil) // key without activating FileOS: the other app stays frontmost
        } else {
            panel.orderFrontRegardless()
        }
        shownByDrag = !takeKeys
    }

    func hide() {
        guard !hiding else { return } // ordering out resigns key, which hides again
        hiding = true
        defer { hiding = false }
        hideTask?.cancel()
        panel?.orderOut(nil)
        shownByDrag = false // the result line stays: its Undo is still the latest shelf action
    }

    /// Quit: no more monitors, no panel.
    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        panel?.close()
    }

    private func makePanel() -> ShelfPanel {
        let panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 240),
                               styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        let view = DropShelfView(resized: { [weak self] in self?.refit() }).environment(model)
        let host = NSHostingView(rootView: AnyView(view))
        panel.contentView = host
        panel.onKey = { [weak self] (event: NSEvent) -> Bool in self?.handleKey(event) ?? false }
        panel.onResignKey = { [weak self] in
            // Opened with the shortcut: clicking another app puts it away, as Spotlight does.
            if let self, !self.shownByDrag, self.isShown, !self.modalUp { self.hide() }
        }
        self.panel = panel
        self.host = host
        return panel
    }

    private func refit() {
        if let panel, panel.isVisible { fit(panel) }
    }

    /// Top centre of the screen with the pointer.
    private func fit(_ panel: ShelfPanel) {
        let size: NSSize = host?.fittingSize ?? NSSize(width: Self.width, height: 240)
        let mouse: NSPoint = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { (s: NSScreen) -> Bool in NSMouseInRect(mouse, s.frame, false) })
                ?? NSScreen.main else { return }
        let area: NSRect = screen.visibleFrame
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.maxY - size.height - 6,
                              width: size.width, height: size.height), display: true)
    }

    /// 1–9 open that pinned folder in FileOS; Esc puts the shelf away.
    private func handleKey(_ event: NSEvent) -> Bool {
        let mods: NSEvent.ModifierFlags = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { return false }
        if event.keyCode == 53 { // kVK_Escape
            hide()
            return true
        }
        guard let chars = event.charactersIgnoringModifiers, let n = Int(chars), (1...9).contains(n),
              n <= model.shelfPinned.count else { return false }
        let folder: URL = model.shelfPinned[n - 1]
        hide()
        model.openInFileOS(folder)
        return true
    }

    // MARK: Showing on drag start (F15.1)

    /// Watches drags in every app (global monitor; mouse events need no extra permission) and in FileOS.
    /// Settings > Drop Shelf "Show on drag" turns this on and off.
    func watchDrags(_ on: Bool) {
        guard on else {
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
            monitors = []
            return
        }
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] (event: NSEvent) in
            self?.mouse(event.type)
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] (event: NSEvent) -> NSEvent? in
            self?.mouse(event.type)
            return event
        }) { monitors.append(local) }
    }

    private func mouse(_ type: NSEvent.EventType) {
        if type == .leftMouseDragged {
            let change: Int = dragBoard.changeCount
            guard change != lastDragChange else { return }
            lastDragChange = change // a new drag wrote the drag pasteboard
            guard !isShown, dragBoard.types?.contains(.fileURL) == true else { return }
            show(takeKeys: false)
        } else if type == .leftMouseUp, shownByDrag, isShown {
            hideLater()
        }
    }

    /// After a drag: stay a moment so the result line can be read, and while the pointer is over the shelf.
    private func hideLater() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            repeat {
                try? await Task.sleep(for: .seconds(3))
            } while !Task.isCancelled && (self?.pointerInside == true || self?.modalUp == true)
            guard !Task.isCancelled, let self, self.shownByDrag else { return }
            self.hide()
        }
    }

    private var modalUp: Bool { model.shelfModalOpen || NSApp.modalWindow != nil }

    private var pointerInside: Bool { panel.map { (p: ShelfPanel) -> Bool in p.frame.contains(NSEvent.mouseLocation) } ?? false }
}
