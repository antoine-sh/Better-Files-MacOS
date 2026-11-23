import SwiftUI

/// Bottom-of-window toasts; undoable ones carry an Undo button (same as ⌘Z).
struct ToastsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.toasts) { toast in
                HStack(spacing: 12) {
                    Text(toast.text)
                    if toast.undoable {
                        Button("Undo") {
                            model.dismiss(toast)
                            model.performUndo()
                        }
                    }
                    Button { model.dismiss(toast) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 36)
        .animation(.default, value: model.toasts)
    }
}
