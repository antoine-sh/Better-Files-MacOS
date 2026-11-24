import SwiftUI
import AppKit
import FileOSCore

extension AppModel {
    var hideNames: Bool { store.get("about.hideNames", default: false) }

    func setHideNames(_ hide: Bool) { store.set("about.hideNames", hide) }

    /// F14.5: read when the page shows (and every minute while it does).
    func aboutThisMac(hideNames: Bool) async -> [InfoGroup] {
        let displays: [String] = NSScreen.screens.map { (s: NSScreen) -> String in
            let size: CGSize = s.frame.size
            let scale: CGFloat = s.backingScaleFactor
            return "\(s.localizedName), \(Int(size.width * scale)) × \(Int(size.height * scale))"
        }
        let runner: any CommandRunner = self.runner
        let home: URL = self.home
        let name: String = macName
        return await SystemInfo.collect(runner: runner, home: home, hideNames: hideNames, macName: name, displays: displays)
    }

    func copyAboutText(_ groups: [InfoGroup]) {
        Pasteboard.write(SystemInfo.asText(groups))
        toast("Copied About This Mac", undoable: false)
    }
}

struct AboutMacView: View {
    @Environment(AppModel.self) private var model
    @State private var groups: [InfoGroup] = []
    @State private var hide: Bool

    /// Starts with the saved choice, so names never flash up before Hide Names applies.
    init(hideNames: Bool) { _hide = State(initialValue: hideNames) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if groups.isEmpty { Text("Looking…").foregroundStyle(.secondary) }
                ForEach(groups) { (g: InfoGroup) in InfoGroupView(group: g) }
            }
            .padding(20)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("About This Mac")
        .toolbar { toolbar }
        .onChange(of: hide) { model.setHideNames(hide) }
        .task(id: hide) { await keepReading() }
    }

    /// Only while visible: the task ends when the page goes away.
    private func keepReading() async {
        while !Task.isCancelled {
            groups = await model.aboutThisMac(hideNames: hide)
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle("Hide Names", isOn: $hide)
            Button("Copy as Text", action: { model.copyAboutText(groups) })
                .disabled(groups.isEmpty)
        }
    }
}

private struct InfoGroupView: View {
    let group: InfoGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.title).font(.headline)
            ForEach(group.rows) { (row: InfoRow) in InfoRowView(row: row) }
        }
    }
}

private struct InfoRowView: View {
    let row: InfoRow

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(row.label).foregroundStyle(.secondary).frame(width: 200, alignment: .leading)
            Text(row.value).textSelection(.enabled)
            if row.status != .ok {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(row.status == .bad ? Color.red : Color.orange)
                    .accessibilityLabel(row.status == .bad ? "Problem" : "Warning")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
