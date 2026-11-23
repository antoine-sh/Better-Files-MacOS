import SwiftUI
import Observation
import FileOSCore

/// F5.5: copies and moves run one at a time. The running job shows "Copying “X”" with
/// "1.2 GB of 3.4 GB · 12 of 40 items" and Cancel; later ones wait as "Waiting: …". Name clashes
/// ask through `clashPrompt` (F5.4), and a pending question is always answered, never dropped.
@MainActor @Observable
final class TransferQueue {
    struct Job: Identifiable {
        let id = UUID()
        let sources: [URL]
        let dest: URL
        let mode: TransferMode
        var progress: TransferProgress?
    }

    private(set) var running: Job?
    private(set) var waiting: [Job] = []
    private(set) var clashPrompt: ClashPrompt?
    /// Drives the clash sheet. SwiftUI may set it false (a dismissal); `clashSheetDismissed` then answers Stop.
    var showClash = false
    /// Called just before a clash question shows, so other modal UI (⌘K) can step aside.
    @ObservationIgnored var willAsk: (@MainActor () -> Void)?
    let trashDir: URL?
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var tasks: [UUID: Task<Result<TransferResult, Error>?, Never>] = [:]

    init(trashDir: URL?) { self.trashDir = trashDir }

    /// Runs after every earlier job. nil when the job was cancelled before it started.
    func run(_ sources: [URL], to dest: URL, mode: TransferMode) async -> Result<TransferResult, Error>? {
        let job = Job(sources: sources, dest: dest, mode: mode)
        waiting.append(job)
        let previous: Task<Void, Never>? = tail
        let task = Task { () async -> Result<TransferResult, Error>? in
            await previous?.value
            return await self.start(job)
        }
        tasks[job.id] = task
        tail = Task { _ = await task.value }
        let result = await task.value
        tasks[job.id] = nil
        return result
    }

    private func start(_ job: Job) async -> Result<TransferResult, Error>? {
        guard let index = waiting.firstIndex(where: { (j: Job) -> Bool in j.id == job.id }) else { return nil }
        waiting.remove(at: index)
        running = job
        defer { running = nil }
        let id: UUID = job.id
        do {
            // `transfer` runs off the main actor inside this task, so Task.isCancelled sees Cancel.
            let result: TransferResult = try await transfer(
                job.sources, to: job.dest, mode: job.mode, trashDir: trashDir,
                resolve: { (clash: Clash) async -> (ClashChoice, applyToAll: Bool) in await self.askClash(clash) },
                progress: { (p: TransferProgress) in Task { @MainActor in self.update(id, p) } },
                isCancelled: { Task.isCancelled })
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    private func update(_ id: UUID, _ progress: TransferProgress) {
        if running?.id == id { running?.progress = progress }
    }

    /// Cancel: a waiting job never starts; the running one stops after the current item (and its
    /// open clash question is answered Stop). What was already done stays done and undoable.
    func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { (j: Job) -> Bool in j.id == id }) {
            waiting.remove(at: index)
            return
        }
        guard running?.id == id else { return }
        tasks[id]?.cancel()
        answerClash(.stop, all: false)
    }

    func askClash(_ clash: Clash) async -> (ClashChoice, applyToAll: Bool) {
        let answer: (ClashChoice, Bool) = await withCheckedContinuation { (c: CheckedContinuation<(ClashChoice, Bool), Never>) in
            // Only one job runs, but never strand an earlier question's transfer: stop it.
            if let earlier = clashPrompt { earlier.continuation.resume(returning: (.stop, false)) }
            if Task.isCancelled {
                clashPrompt = nil
                showClash = false
                c.resume(returning: (.stop, false))
            } else {
                willAsk?()
                clashPrompt = ClashPrompt(clash: clash, continuation: c)
                showClash = true
            }
        }
        return (answer.0, applyToAll: answer.1)
    }

    func answerClash(_ choice: ClashChoice, all: Bool) {
        guard let prompt = clashPrompt else { return }
        clashPrompt = nil
        showClash = false
        prompt.continuation.resume(returning: (choice, all))
    }

    /// The sheet went away without an answer (not replaced by a new question): Stop, never strand the transfer.
    func clashSheetDismissed() {
        if !showClash { answerClash(.stop, all: false) }
    }

    // MARK: Copy

    static func verb(_ mode: TransferMode) -> String { mode == .copy ? "Copying" : "Moving" }

    /// "Copying “Team-Photos.zip”".
    static func title(_ job: Job) -> String {
        let name: String = job.progress?.currentName ?? job.sources.first?.lastPathComponent ?? ""
        return "\(verb(job.mode)) “\(name)”"
    }

    /// "1.2 GB of 3.4 GB · 12 of 40 items".
    static func detail(bytesDone: Int64, bytesTotal: Int64, itemsDone: Int, itemsTotal: Int) -> String {
        "\(formatBytes(bytesDone)) of \(formatBytes(bytesTotal)) · \(itemsDone) of \(itemsTotal) items"
    }

    static func detail(_ job: Job) -> String {
        guard let p = job.progress else { return detail(bytesDone: 0, bytesTotal: 0, itemsDone: 0, itemsTotal: job.sources.count) }
        return detail(bytesDone: p.bytesDone, bytesTotal: p.bytesTotal, itemsDone: p.itemsDone, itemsTotal: p.itemsTotal)
    }

    /// "Waiting: Copying “a.txt” to “Documents”" / "Waiting: Moving 3 items to “Documents”".
    static func waitingText(_ job: Job) -> String {
        let what: String = job.sources.count == 1 ? "“\(job.sources[0].lastPathComponent)”" : AppModel.items(job.sources.count)
        return "Waiting: \(verb(job.mode)) \(what) to “\(job.dest.lastPathComponent)”"
    }
}

/// The progress card for the running transfer and the "Waiting: …" list (F5.5).
struct TransferQueueView: View {
    let queue: TransferQueue

    var body: some View {
        if let job = queue.running {
            VStack(alignment: .leading, spacing: 6) {
                RunningTransfer(job: job, queue: queue)
                ForEach(queue.waiting) { (waiting: TransferQueue.Job) in
                    WaitingTransfer(job: waiting, queue: queue)
                }
            }
            .padding(12)
            .frame(width: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 4)
            .padding(16)
        }
    }
}

private struct RunningTransfer: View {
    let job: TransferQueue.Job
    let queue: TransferQueue

    private var fraction: Double {
        guard let p = job.progress else { return 0 }
        if p.bytesTotal > 0 { return Double(p.bytesDone) / Double(p.bytesTotal) }
        return p.itemsTotal > 0 ? Double(p.itemsDone) / Double(p.itemsTotal) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(TransferQueue.title(job)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Cancel", action: { cancel() })
            }
            ProgressView(value: min(max(fraction, 0), 1))
            Text(TransferQueue.detail(job)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func cancel() { queue.cancel(job.id) }
}

private struct WaitingTransfer: View {
    let job: TransferQueue.Job
    let queue: TransferQueue

    var body: some View {
        HStack {
            Text(TransferQueue.waitingText(job)).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(action: { cancel() }) { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain)
                .help("Cancel")
                .accessibilityLabel("Cancel")
        }
    }

    private func cancel() { queue.cancel(job.id) }
}
