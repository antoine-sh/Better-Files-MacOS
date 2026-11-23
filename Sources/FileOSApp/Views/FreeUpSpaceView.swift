import SwiftUI
import AppKit
import FileOSCore

/// Free Up Space (F10) state: the nine cards, read off the main actor; read-only until "Move N to Trash".
@MainActor @Observable
final class CleanModel {
    private(set) var cards: [CleanCard] = CleanModel.emptyCards
    private(set) var looking = false
    /// True until a scan finishes, and again after one is cancelled, so the page looks again when it reappears.
    private(set) var needsScan = true
    /// Scans started, for the self-test.
    private(set) var scansStarted = 0
    private(set) var summary: (free: Int64, total: Int64, used: Int64, trash: Int64)?
    var openCard: CardID?
    @ObservationIgnored private var scanTask: Task<(summary: (free: Int64, total: Int64, used: Int64, trash: Int64), cards: [CleanCard]), Never>?

    static var emptyCards: [CleanCard] { CardID.allCases.map { (id: CardID) -> CleanCard in CleanCard(id: id, items: []) } }

    /// "Look Again": the cards go grey with "Looking…" and fill when the scan ends; an older scan is cancelled.
    func scan(home: URL, applications: [URL]? = nil) async {
        scanTask?.cancel()
        scansStarted += 1
        looking = true
        cards = Self.emptyCards
        let running: Set<String> = Set(NSWorkspace.shared.runningApplications.compactMap { (a: NSRunningApplication) -> String? in a.localizedName })
        let task = Task.detached(priority: .utility) { () -> (summary: (free: Int64, total: Int64, used: Int64, trash: Int64), cards: [CleanCard]) in
            let summary = SmartClean.diskSummary(home: home)
            let cards: [CleanCard] = SmartClean.scan(home: home, now: Date(), isAppRunning: { (name: String) -> Bool in running.contains(name) },
                                                     applications: applications)
            return (summary, cards)
        }
        scanTask = task
        let result = await task.value
        guard scanTask == task, !task.isCancelled else { return } // a newer scan owns the cards
        summary = result.summary
        cards = result.cards
        looking = false
        needsScan = false
    }

    func cancel() {
        guard let task = scanTask else { return }
        task.cancel()
        scanTask = nil
        if looking {
            looking = false
            needsScan = true
        }
    }

    /// Duplicates' "Tick These Too".
    func tickTheseToo() {
        guard let c = cards.firstIndex(where: { (card: CleanCard) -> Bool in card.id == .duplicates }) else { return }
        cards[c].tickTheseToo()
    }

    func card(_ id: CardID) -> CleanCard? { cards.first { (c: CleanCard) -> Bool in c.id == id } }

    func setTicked(_ id: CardID, item: String?, _ ticked: Bool) {
        guard let c = cards.firstIndex(where: { (card: CleanCard) -> Bool in card.id == id }) else { return }
        for i in cards[c].items.indices where item == nil || cards[c].items[i].id == item {
            cards[c].items[i].ticked = ticked
        }
    }

    /// Each ticked path once, even if it shows in two cards.
    var ticked: [CleanItem] {
        var seen: Set<String> = []
        var out: [CleanItem] = []
        for card in cards {
            for item in card.items where item.ticked && seen.insert(item.id).inserted { out.append(item) }
        }
        return out
    }

    var barText: String {
        let items: [CleanItem] = ticked
        return "\(items.count) ticked · \(formatBytes(items.reduce(0) { (sum: Int64, i: CleanItem) -> Int64 in sum + i.bytes }))"
    }

    /// Drops items that are no longer on disk (after they were moved to the Trash).
    func dropGone() {
        for c in cards.indices {
            cards[c].items.removeAll { (i: CleanItem) -> Bool in (try? FileManager.default.attributesOfItem(atPath: i.url.path)) == nil }
        }
    }
}

extension AppModel {
    /// "Move 4 to Trash": one undo entry and the usual "Moved 4 items to the Trash" toast.
    func moveTickedToTrash() {
        let urls: [URL] = clean.ticked.map { (i: CleanItem) -> URL in i.url }
        trash(urls)
        clean.dropGone()
    }

    static func diskSummaryText(_ s: (free: Int64, total: Int64, used: Int64, trash: Int64), volume: String) -> String {
        "\(formatBytes(s.free)) free of \(formatBytes(s.total)) on \(volume) · \(formatBytes(s.used)) used"
    }
}

struct FreeUpSpaceView: View {
    let clean: CleanModel
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DiskSummaryHeader(clean: clean)
                    if let id = clean.openCard, let card = clean.card(id) {
                        CardDetail(clean: clean, card: card)
                    } else {
                        CardGrid(clean: clean, group: .safe, title: "Safe to clear")
                        CardGrid(clean: clean, group: .yourCall, title: "Your call")
                    }
                }
                .padding(20)
            }
            TickedBar(clean: clean)
        }
        .navigationTitle("Free Up Space")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Look Again", action: { lookAgain() }).disabled(clean.looking)
            }
        }
        .onAppear { if clean.needsScan && !clean.looking { lookAgain() } }
        .onDisappear { clean.cancel() }
    }

    private func lookAgain() {
        let home: URL = model.home
        let apps: [URL]? = model.cleanApplications
        Task { await clean.scan(home: home, applications: apps) }
    }
}

private struct DiskSummaryHeader: View {
    let clean: CleanModel
    @Environment(AppModel.self) private var model

    private var volume: String {
        (try? model.home.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = clean.summary {
                Text(AppModel.diskSummaryText(s, volume: volume)).font(.title3.weight(.semibold))
                ProgressView(value: Double(s.used), total: Double(max(1, s.total)))
                Text("In the Trash: \(formatBytes(s.trash))").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Looking…").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CardGrid: View {
    let clean: CleanModel
    let group: CleanCard.Group
    let title: String
    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(clean.cards.filter { (c: CleanCard) -> Bool in c.group == group }) { (card: CleanCard) in
                    CardTile(clean: clean, card: card)
                }
            }
        }
    }
}

private struct CardTile: View {
    let clean: CleanModel
    let card: CleanCard

    private var bytes: Int64 { card.items.reduce(0) { (sum: Int64, i: CleanItem) -> Int64 in sum + i.bytes } }

    var body: some View {
        Button(action: { open() }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title).font(.subheadline.weight(.semibold))
                Text(card.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(status).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .padding(10)
            .background(Color.secondary.opacity(clean.looking ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 10))
            .opacity(clean.looking ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(clean.looking || card.items.isEmpty)
    }

    private var status: String {
        if clean.looking { return "Looking…" }
        if card.items.isEmpty { return "Nothing found" }
        return "\(AppModel.items(card.items.count)) · \(formatBytes(bytes))"
    }

    private func open() { clean.openCard = card.id }
}

private struct CardDetail: View {
    let clean: CleanModel
    let card: CleanCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("< All suggestions", action: { back() }).buttonStyle(.link)
            Text(card.title).font(.title2.weight(.semibold))
            Text(card.reason).foregroundStyle(.secondary)
            HStack {
                Button("Tick all", action: { clean.setTicked(card.id, item: nil, true) })
                Button("Untick all", action: { clean.setTicked(card.id, item: nil, false) })
                if card.id == .duplicates, card.items.contains(where: { (i: CleanItem) -> Bool in !i.ticked }) {
                    Button("Tick These Too", action: { clean.tickTheseToo() })
                        .help("Tick the spares left unticked; one copy of each is always kept")
                }
            }
            ForEach(main) { (item: CleanItem) in
                CleanItemRow(clean: clean, card: card.id, item: item)
            }
            if !apart.isEmpty {
                Text("Stale node_modules").font(.headline).padding(.top, 6)
                ForEach(apart) { (item: CleanItem) in
                    CleanItemRow(clean: clean, card: card.id, item: item)
                }
            }
        }
    }

    /// Developer caches list stale node_modules apart (F10.3).
    private var apart: [CleanItem] { card.items.filter { (i: CleanItem) -> Bool in i.note == SmartClean.staleNodeModulesNote } }
    private var main: [CleanItem] { card.items.filter { (i: CleanItem) -> Bool in i.note != SmartClean.staleNodeModulesNote } }

    private func back() { clean.openCard = nil }
}

private struct CleanItemRow: View {
    let clean: CleanModel
    let card: CardID
    let item: CleanItem
    @Environment(AppModel.self) private var model
    @State private var on = false

    var body: some View {
        Toggle(isOn: $on) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(item.note ?? model.displayPath(item.url.deletingLastPathComponent()))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(formatBytes(item.bytes)).foregroundStyle(.secondary)
            }
        }
        .onAppear { on = item.ticked }
        .onChange(of: item.ticked) { on = item.ticked }
        .onChange(of: on) { if on != item.ticked { clean.setTicked(card, item: item.id, on) } }
    }
}

/// "4 ticked · 24.2 GB" and "Move 4 to Trash".
private struct TickedBar: View {
    let clean: CleanModel
    @Environment(AppModel.self) private var model

    var body: some View {
        let count: Int = clean.ticked.count
        HStack {
            Text(clean.barText).foregroundStyle(.secondary)
            Spacer()
            Button("Move \(count) to Trash", action: { model.moveTickedToTrash() })
                .disabled(count == 0 || clean.looking)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
