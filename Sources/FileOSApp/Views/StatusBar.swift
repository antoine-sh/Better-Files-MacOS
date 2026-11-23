import SwiftUI
import FileOSCore

/// F1.3: "N items, M selected, X available" and the hidden-files state.
struct StatusBar: View {
    let pane: PaneModel
    @Environment(AppModel.self) private var model

    static func text(items: Int, selected: Int, free: Int64) -> String {
        "\(items == 1 ? "1 item" : "\(items) items"), \(selected) selected, \(formatBytes(free)) available"
    }

    var body: some View {
        HStack {
            Spacer()
            Text(Self.text(items: pane.visibleEntries.count, selected: pane.selection.count, free: pane.freeSpace))
            Spacer()
            if model.showHidden {
                Text("Hidden files shown").help("Press ⇧⌘. to hide them")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
    }
}
