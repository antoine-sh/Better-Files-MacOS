import SwiftUI
import AppKit
import FileOSCore

/// F3.13: shown instead of a blank pane when macOS refuses to list a folder.
struct LockedFolderView: View {
    let folder: String
    let pane: PaneModel
    static let fullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(FolderState.lockedTitle(folder)).font(.title2.weight(.semibold))
            Button("Give FileOS Full Access") { _ = NSWorkspace.shared.open(Self.fullDiskAccess) }
                .buttonStyle(.borderedProminent)
            HStack {
                Button("Allow Just This Folder…") { allowJustThisFolder() }
                Button("Try Again") { pane.reload() }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Picking the folder in an open panel is the user intent macOS accepts as access to it.
    private func allowJustThisFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = pane.url
        panel.prompt = "Allow"
        if panel.runModal() == .OK { pane.reload() }
    }
}

/// A folder that can't be shown for another reason (gone, not a folder).
struct FolderErrorView: View {
    let message: String
    let pane: PaneModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message).font(.title3)
            HStack {
                if pane.canGoUp { Button("Enclosing Folder") { pane.up() } }
                Button("Try Again") { pane.reload() }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
