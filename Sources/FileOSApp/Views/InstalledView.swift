import SwiftUI
import AppKit
import FileOSCore

enum InstalledFilter: String, CaseIterable, Hashable {
    case all = "All", apps = "Apps", mine = "You installed", others = "Came with others", leftBehind = "Left behind"
    /// Set by the Tidy-up chips.
    case twoOfTheSame = "Two of the same", notRunLately = "Not run lately"

    static let picker: [InstalledFilter] = [.all, .apps, .mine, .others, .leftBehind]
}

/// F14.3 Installed: read-only lists from each package manager. Removing is a copied command.
@MainActor @Observable
final class InstalledModel {
    private(set) var tools: [ToolPackages] = []
    private(set) var loading = false
    private(set) var loaded = false
    var filter: InstalledFilter = .all
    @ObservationIgnored private var task: Task<[ToolPackages], Never>?

    func load(runner: any CommandRunner, home: URL) async {
        task?.cancel()
        loading = true
        let t = Task.detached(priority: .utility) { () -> [ToolPackages] in await Packages.list(runner: runner, home: home) }
        task = t
        let result: [ToolPackages] = await t.value
        guard task == t else { return } // a newer Refresh owns the list
        tools = result
        loading = false
        loaded = true
    }

    var all: [Package] { tools.flatMap { (t: ToolPackages) -> [Package] in t.packages } }

    var twins: [[Package]] { Packages.twoOfTheSame(all) }

    func stale(now: Date) -> [Package] { all.filter { (p: Package) -> Bool in Packages.notRunLately(p, now: now) } }

    func shown(now: Date) -> [Package] {
        switch filter {
        case .all: return all
        case .apps: return all.filter { (p: Package) -> Bool in p.isApp }
        case .mine: return all.filter { (p: Package) -> Bool in p.youInstalled }
        case .others: return all.filter { (p: Package) -> Bool in !p.youInstalled }
        case .leftBehind: return all.filter { (p: Package) -> Bool in p.leftBehind }
        case .twoOfTheSame: return twins.flatMap { (g: [Package]) -> [Package] in g }
        case .notRunLately: return stale(now: now)
        }
    }

    var summary: String {
        let n: Int = all.count
        let t: Int = tools.count
        return "\(n) \(n == 1 ? "package" : "packages") from \(t) \(t == 1 ? "tool" : "tools")"
    }
}

extension AppModel {
    func copyRemoveCommand(_ p: Package) {
        guard let command = p.removeCommand else {
            toast("Remove “\(p.name)” from ~/go/bin by hand", undoable: false)
            return
        }
        Pasteboard.write(command)
        toast("Copied “\(command)”", undoable: false)
    }

    func copyCleanCommand(_ tool: Tool) {
        guard let command = tool.cleanCommand else { return }
        Pasteboard.write(command)
        toast("Copied “\(command)”", undoable: false)
    }

    /// Save List…: a Brewfile; undo puts back what was there (or trashes the new file).
    func saveBrewfile(to url: URL) {
        let text: String = Packages.brewfile(installed.all)
        do {
            let write: SetupWrite = try Agents.write(Data(text.utf8), to: url)
            let trashDir: URL? = self.trashDir
            undo.push("Save List") { Agents.undo([write], trashDir: trashDir) }
            toast("Saved “\(url.lastPathComponent)”", undoable: true)
        } catch {
            toast("Couldn't save “\(url.lastPathComponent)”: \(error.localizedDescription)", undoable: false)
        }
    }

    func askSaveBrewfile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Brewfile"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveBrewfile(to: url)
    }
}

struct InstalledView: View {
    let installed: InstalledModel
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InstalledHeader(installed: installed)
            TidyChips(installed: installed)
            FilterPicker(installed: installed)
            PackageList(installed: installed)
        }
        .padding(16)
        .navigationTitle("Installed")
        .toolbar { toolbar }
        .task { if !installed.loaded { await refresh() } }
    }

    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Save List…", action: { model.askSaveBrewfile() })
                .disabled(!installed.tools.contains { (t: ToolPackages) -> Bool in t.tool == .homebrew })
            IconButton(symbol: "arrow.clockwise", label: "Refresh", help: "Refresh", disabled: installed.loading,
                       action: { Task { await refresh() } })
        }
    }

    private func refresh() async { await installed.load(runner: model.runner, home: model.home) }
}

private struct InstalledHeader: View {
    let installed: InstalledModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(installed.loading ? "Looking…" : installed.summary).font(.title2.weight(.semibold))
            ShareBar(tools: installed.tools)
        }
    }
}

/// Each tool's share of all packages.
private struct ShareBar: View {
    let tools: [ToolPackages]
    static let colors: [Color] = [.orange, .red, .blue, .teal, .brown, .pink, .cyan]

    private var total: Int { max(1, tools.reduce(0) { (n: Int, t: ToolPackages) -> Int in n + t.packages.count }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { (geo: GeometryProxy) in
                HStack(spacing: 1) {
                    ForEach(Array(tools.enumerated()), id: \.offset) { (pair: (offset: Int, element: ToolPackages)) in
                        Rectangle()
                            .fill(Self.colors[pair.offset % Self.colors.count])
                            .frame(width: geo.size.width * Double(pair.element.packages.count) / Double(total))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            .accessibilityHidden(true)
            legend
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(Array(tools.enumerated()), id: \.offset) { (pair: (offset: Int, element: ToolPackages)) in
                Label("\(pair.element.tool.name) \(pair.element.packages.count)", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(Self.colors[pair.offset % Self.colors.count])
            }
        }
    }
}

/// Caches (with their clean command), Two of the same, Not run lately.
private struct TidyChips: View {
    let installed: InstalledModel
    @Environment(AppModel.self) private var model

    private var caches: [ToolPackages] {
        installed.tools.filter { (t: ToolPackages) -> Bool in t.cacheBytes > 0 && t.tool.cleanCommand != nil }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(caches) { (t: ToolPackages) in
                Button("\(t.tool.name) cache \(formatBytes(t.cacheBytes)) · Copy “\(t.tool.cleanCommand ?? "")”",
                       action: { model.copyCleanCommand(t.tool) })
            }
            if !installed.twins.isEmpty {
                Button("Two of the same: \(installed.twins.count)", action: { installed.filter = .twoOfTheSame })
            }
            let stale: Int = installed.stale(now: Date()).count
            if stale > 0 {
                Button("Not run lately: \(stale)", action: { installed.filter = .notRunLately })
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private struct FilterPicker: View {
    let installed: InstalledModel
    @State private var choice: InstalledFilter = .all

    var body: some View {
        Picker("Show", selection: $choice) {
            ForEach(InstalledFilter.picker, id: \.self) { (f: InstalledFilter) in Text(f.rawValue).tag(f) }
            if !InstalledFilter.picker.contains(installed.filter) {
                Text(installed.filter.rawValue).tag(installed.filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onAppear { choice = installed.filter }
        .onChange(of: installed.filter) { choice = installed.filter }
        .onChange(of: choice) { if choice != installed.filter { installed.filter = choice } }
    }
}

private struct PackageList: View {
    let installed: InstalledModel

    var body: some View {
        let rows: [Package] = installed.shown(now: Date())
        return List(rows) { (p: Package) in PackageRow(package: p) }
            .overlay { empty(rows) }
    }

    @ViewBuilder private func empty(_ rows: [Package]) -> some View {
        if rows.isEmpty && !installed.loading {
            Text(installed.tools.isEmpty ? "No package managers found." : "Nothing here.").foregroundStyle(.secondary)
        }
    }
}

private struct PackageRow: View {
    let package: Package
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: package.isApp ? "app" : "shippingbox").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(package.name).fontWeight(.medium)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy Remove Command", action: { model.copyRemoveCommand(package) })
                .controlSize(.small)
                .disabled(package.removeCommand == nil)
        }
        .contextMenu { Button("Copy Remove Command", action: { model.copyRemoveCommand(package) }) }
    }

    private var details: String {
        var parts: [String] = [package.tool.name]
        if !package.version.isEmpty { parts.append(package.version) }
        parts.append(package.leftBehind ? "Left behind" : package.source)
        if let last = package.lastRun { parts.append("Last run \(last.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }
}
