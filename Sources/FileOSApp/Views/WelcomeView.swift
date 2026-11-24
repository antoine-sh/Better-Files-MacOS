import SwiftUI
import FileOSCore

/// F1.5 (no license step): Get Started, the tour, "Move and Reopen" outside /Applications, Full Disk Access,
/// Make FileOS yours, Start using FileOS.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    let steps: [WelcomeStep]
    @State private var index = 0

    init(steps: [WelcomeStep] = WelcomeStep.steps(offerMove: WelcomeStep.offersMove(bundlePath: Bundle.main.bundlePath))) {
        self.steps = steps
    }

    var body: some View {
        content
            .padding(32)
            .frame(width: 540, height: 460)
    }

    @ViewBuilder private var content: some View {
        switch steps[min(index, steps.count - 1)] {
        case .demo: DemoStep(next: { next() })
        case .tour: TourStep(next: { next() })
        case .moveToApplications: MoveStep(next: { next() })
        case .fullDiskAccess: DiskAccessStep(next: { next() })
        case .makeYours: MakeYoursStep()
        }
    }

    private func next() {
        if index + 1 < steps.count { index += 1 }
    }
}

private struct StepHeader: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 54)).foregroundStyle(.tint).accessibilityHidden(true)
            Text(title).font(.title).bold()
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Turn into FileOS" changes the plain folder into FileOS's, then "Get Started".
private struct DemoStep: View {
    let next: @MainActor () -> Void
    @State private var turned = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            if turned {
                StepHeader(symbol: "folder.fill", title: "Welcome to FileOS",
                           text: "A faster way to find, move and tidy your files.")
                Button("Get Started", action: { next() }).keyboardShortcut(.defaultAction).controlSize(.large)
            } else {
                StepHeader(symbol: "folder", title: "Your files, as they are now", text: "See them the FileOS way.")
                Button("Turn into FileOS", action: { withAnimation { turned = true } })
                    .keyboardShortcut(.defaultAction).controlSize(.large)
            }
            Spacer()
        }
    }
}

private struct TourStep: View {
    let next: @MainActor () -> Void
    @State private var page = 0
    private static let pages: [(symbol: String, title: String, text: String)] = [
        ("magnifyingglass", "Find anything with ⌘K", "Search files, folders, workspaces and bookmarks from one box."),
        ("rectangle.split.2x1", "Two panes, one window", "⌘D opens a second pane. F5 copies and F6 moves to it."),
        ("tray.and.arrow.down", "The Drop Shelf", "Press ⌥Space, or start dragging a file, to drop it into a pinned folder."),
    ]

    var body: some View {
        let item = Self.pages[page]
        VStack(spacing: 20) {
            Spacer()
            StepHeader(symbol: item.symbol, title: item.title, text: item.text)
            Text("\(page + 1) of \(Self.pages.count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Skip", action: { next() })
                Spacer()
                Button("Continue", action: { advance() }).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func advance() {
        if page + 1 < Self.pages.count { page += 1 } else { next() }
    }
}

/// Offered only: nothing moves unless "Move and Reopen" is clicked.
private struct MoveStep: View {
    let next: @MainActor () -> Void
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            StepHeader(symbol: "arrow.down.app", title: "Move FileOS to Applications?",
                       text: "FileOS is running from “\(Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent)”. It works best from the Applications folder.")
            if let error { Text(error).foregroundStyle(.red) }
            Spacer()
            HStack {
                Button("Not now", action: { next() })
                Spacer()
                Button("Move and Reopen", action: { error = model.moveToApplicationsAndReopen() }).keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct DiskAccessStep: View {
    let next: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            StepHeader(symbol: "lock.open", title: "Full Disk Access",
                       text: "Lets FileOS show sizes and search in folders macOS protects. You can turn it on later in System Settings > Privacy & Security.")
            Spacer()
            HStack {
                Button("Not now", action: { next() })
                Spacer()
                Button("Open System Settings", action: {
                    AppModel.openPrivacySettings("Privacy_AllFiles")
                    next()
                })
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Accent colour, view, sounds, menu bar icon, open at login.
private struct MakeYoursStep: View {
    @Environment(AppModel.self) private var model
    @State private var view: ViewMode = .list

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 12) {
            Text("Make FileOS yours").font(.title).bold()
            Form {
                AccentPicker()
                Picker("View", selection: $view) {
                    Text("List").tag(ViewMode.list)
                    Text("Icons").tag(ViewMode.icons)
                    Text("Columns").tag(ViewMode.columns)
                }
                .pickerStyle(.segmented)
                SoundToggle()
                Toggle("Menu bar icon", isOn: $model.settings.menuBar)
                LoginToggle()
            }
            .formStyle(.grouped)
            Button("Start using FileOS", action: { model.finishWelcome() })
                .keyboardShortcut(.defaultAction).controlSize(.large)
        }
        .onAppear { view = model.pane.view }
        .onChange(of: view) { if view != model.pane.view { model.setView(view) } }
    }
}

/// F1.10: after an update, and from Settings > About.
struct WhatsNewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What's New in FileOS \(Release.version)").font(.title2).bold()
            ForEach(Release.notes, id: \.self) { (note: String) in
                Label(note, systemImage: "sparkle")
            }
            HStack {
                Spacer()
                Button("Continue", action: { model.closeWhatsNew() }).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

/// The welcome and What's New sheets on the main window.
struct WelcomeDialogs: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.showWelcome) {
                WelcomeView().environment(model).interactiveDismissDisabled()
            }
            .sheet(isPresented: $model.showWhatsNew, onDismiss: { model.closeWhatsNew() }) {
                WhatsNewView().environment(model)
            }
    }
}

/// The window-wide effects of settings: accent tint, the welcome / What's New sheets, and saving the panes (F1.7).
struct SettingsEffects: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .modifier(WelcomeDialogs(model: model))
            .onChange(of: model.sessionSignature) { model.saveSession() }
            .tint(model.settings.accentColor)
    }
}
