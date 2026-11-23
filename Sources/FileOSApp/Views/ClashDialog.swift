import SwiftUI
import FileOSCore

/// F5.4: "“Brand-Guide.pdf” is already in “Documents”" — Keep Both, Replace (old one to the Trash,
/// undoable), Skip, Stop. Esc means Stop, so the transfer waiting on the answer never hangs.
struct ClashDialog: View {
    let prompt: ClashPrompt
    @Environment(AppModel.self) private var model
    @State private var applyToAll = false

    static func title(_ clash: Clash) -> String {
        "“\(clash.name)” is already in “\(clash.destination.lastPathComponent)”"
    }

    /// The remaining items plus this one.
    static func allText(_ clash: Clash) -> String { "Do the same for all \(clash.remaining + 1) items…" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Self.title(prompt.clash)).font(.headline)
            if prompt.clash.remaining > 0 {
                Toggle(Self.allText(prompt.clash), isOn: $applyToAll)
            }
            HStack {
                Button("Stop", action: { answer(.stop) })
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip", action: { answer(.skip) })
                Button("Replace", action: { answer(.replace) })
                Button("Keep Both", action: { answer(.keepBoth) })
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }

    private func answer(_ choice: ClashChoice) { model.answerClash(choice, all: applyToAll) }
}
