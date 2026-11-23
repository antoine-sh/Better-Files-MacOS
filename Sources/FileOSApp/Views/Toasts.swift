import SwiftUI

/// Bottom-of-window toasts; undoable ones carry an Undo button.
struct ToastsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.toasts) { (toast: Toast) in
                ToastRow(toast: toast)
            }
        }
        .padding(.bottom, 36)
        .animation(.default, value: model.toasts)
    }
}

private struct ToastRow: View {
    let toast: Toast
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text)
            undoButton
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4)
        .transition(.opacity)
    }

    @ViewBuilder private var undoButton: some View {
        if toast.undoable { Button("Undo", action: undo) }
    }

    private func dismiss() { model.dismiss(toast) }

    private func undo() {
        model.dismiss(toast)
        model.performUndo()
    }
}
