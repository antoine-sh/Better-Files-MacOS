import SwiftUI
import AppKit
import ServiceManagement
import FileOSCore

// MARK: - Model (F17, F1.7): settings changes, shortcuts, the last session, folder access.

extension AppSettings.Appearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "As the Mac"
        }
    }
}

extension AppSettings {
    /// nil: the Mac's accent colour.
    var accentColor: Color? { Self.color(accent: accent) }

    static func color(accent: String) -> Color? {
        switch accent {
        case "mac": return nil
        case "purple": return .purple
        case "blue": return .blue
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "graphite": return .gray
        default: return rgb(hex: accent).map { (c: (r: Double, g: Double, b: Double)) -> Color in Color(red: c.r, green: c.g, blue: c.b) }
        }
    }

    var sidebarRowSize: SidebarRowSize {
        switch sidebarSize {
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        }
    }
}

/// The panes as they were, for F1.7.
struct SavedSession: Codable {
    var layout: PaneLayout
    var folders: [String]
    var active: Int
}

extension AppModel {
    static func downloadsFolder(home: URL, path: String) -> URL {
        FileOps.canonical(path.isEmpty ? home.appendingPathComponent("Downloads") : URL(fileURLWithPath: path))
    }

    var downloadsURL: URL { Self.downloadsFolder(home: home, path: settings.downloadsPath) }

    /// Default folder colour for folders without their own (F17.3).
    var defaultFolderColor: Color {
        settings.folderColor == "accent" ? (settings.accentColor ?? Color.accentColor) : Self.color(settings.folderColor)
    }

    func settingsChanged(from old: AppSettings) {
        store.set("settings", settings)
        if settings.appearance != old.appearance { applyAppearance() }
        if settings.downloadsPath != old.downloadsPath {
            for p in panes { p.downloads = downloadsURL; p.reload() }
        }
        settingsApplied?(settings)
    }

    func applyAppearance() {
        NSApp?.appearance = settings.appearance.nsAppearance
    }

    // MARK: Restore state (F1.7)

    var sessionSignature: String {
        "\(layout.rawValue)|\(activePane)|" + panes.map { (p: PaneModel) -> String in p.url.path }.joined(separator: "|")
    }

    func saveSession() {
        store.set("session", SavedSession(layout: layout, folders: panes.map { (p: PaneModel) -> String in p.url.path },
                                          active: activePane))
    }

    /// Folders that are gone since are left at the start folder.
    func restoreSession() {
        let saved: SavedSession? = store.get("session", default: nil)
        guard let saved else { return }
        setLayout(saved.layout)
        for (p, path) in zip(panes, saved.folders) {
            let url = URL(fileURLWithPath: path)
            if Self.isBrowsableFolder(url) { p.navigate(to: url) }
        }
        activePane = min(max(saved.active, 0), panes.count - 1)
    }

    // MARK: Shortcuts (F17.5); overrides stay under "shortcuts", the Drop Shelf's via `setDropShelfShortcut`.

    /// nil when set; otherwise why not. `KeyCombo.none` removes the shortcut.
    @discardableResult
    func setShortcut(_ id: String, _ combo: KeyCombo) -> String? {
        if id == "dropShelf" { return setDropShelfShortcut(combo) }
        guard let original = Shortcuts.defaults[id], !Shortcuts.fixed.contains(id) else { return nil }
        var user: [String: KeyCombo] = store.get("shortcuts", default: [String: KeyCombo]())
        user[id] = combo == original ? nil : combo
        store.set("shortcuts", user)
        shortcuts = Shortcuts.merged(user)
        return nil
    }

    /// "Use It Here": `other` loses `combo`, `id` gets it.
    func useShortcutHere(_ id: String, _ combo: KeyCombo, from other: String) -> String? {
        if other == "dropShelf" { return "The Drop Shelf needs a shortcut: give it another one first" }
        let previous: KeyCombo = shortcuts[other] ?? .none
        setShortcut(other, .none)
        if let error = setShortcut(id, combo) {
            setShortcut(other, previous)
            return error
        }
        return nil
    }

    /// Restore Defaults: every override goes; the Drop Shelf's shortcut is registered again.
    func restoreDefaultShortcuts() -> String? {
        let old: KeyCombo = dropShelfShortcut
        store.set("shortcuts", [String: KeyCombo]())
        shortcuts = Shortcuts.defaults
        let fresh: KeyCombo = dropShelfShortcut
        guard old != fresh, let register = dropShelfShortcutChanged, !register(fresh) else { return nil }
        _ = register(old) // keep the one that worked
        setShortcut("dropShelf", old)
        return "Couldn't use \(fresh) for the Drop Shelf: another app may be using it"
    }

    // MARK: Folder Access (F17.6)

    /// Whether FileOS may list ~/`name` (macOS asks the first time).
    func folderOpens(_ name: String) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(name).path)) != nil
    }

    static func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Welcome (F1.5)

    /// "Move and Reopen": only after the user clicked it, never over an existing copy.
    func moveToApplicationsAndReopen() -> String? {
        let source: URL = Bundle.main.bundleURL
        let target = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            return "There's already a “\(target.lastPathComponent)” in Applications"
        }
        do {
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            return "Couldn't move FileOS: \(error.localizedDescription)"
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: target, configuration: config) { (_: NSRunningApplication?, error: Error?) in
            let failed: Bool = error != nil
            Task { @MainActor in
                // Quit only once the moved copy is running; otherwise keep this one open.
                if failed { self.toast("FileOS moved to Applications. Reopen it from there.", undoable: false) } else { NSApp.terminate(nil) }
            }
        }
        return nil
    }

    func finishWelcome() {
        settings.welcomed = true
        settings.whatsNewSeen = Release.version
        showWelcome = false
    }

    func closeWhatsNew() {
        settings.whatsNewSeen = Release.version
        showWhatsNew = false
    }
}

/// Open at login (F17.2): the system keeps this, not our settings.
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// nil when done; otherwise why not.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "Couldn't change Open at Login: \(error.localizedDescription)"
        }
    }
}

// MARK: - Views

extension EnvironmentValues {
    @Entry var settingsQuery: String = ""
    @Entry var settingsSection: String = ""
}

/// ⌘, (F17.1): a search box over every row; changes apply at once.
struct SettingsView: View {
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search Settings", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 8)
            Form {
                AboutSection()
                GeneralSection()
                AppearanceSection()
                WindowSection()
                MotionSection()
                QuickActionsSection()
                ShortcutsSection()
                FolderAccessSection()
                OpenInSection()
                DropShelfSection()
                MenuBarSection()
            }
            .formStyle(.grouped)
            .environment(\.settingsQuery, query)
        }
        .frame(width: 560, height: 640)
    }
}

/// A section shown while any of its rows matches the search.
struct SettingsSection<Content: View>: View {
    let title: String
    let rows: [String]
    @ViewBuilder let content: () -> Content
    @Environment(\.settingsQuery) private var query

    var body: some View {
        if SettingsSearch.visible(query, section: title, rows: rows) {
            Section(title) { content() }.environment(\.settingsSection, title)
        }
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.settingsQuery) private var query
    @Environment(\.settingsSection) private var section

    var body: some View {
        if SettingsSearch.matches(query, section: section, row: title) { content() }
    }
}

private struct AboutSection: View {
    @Environment(AppModel.self) private var model
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? Release.version
    }

    var body: some View {
        SettingsSection(title: "About", rows: ["Version", "What's New", "Guide"]) {
            SettingsRow(title: "Version") { LabeledContent("Version", value: version) }
            SettingsRow(title: "What's New") { Button("What's New", action: { model.showWhatsNew = true }) }
            SettingsRow(title: "Guide") {
                Link("Guide", destination: URL(string: "https://github.com/antoine-sh/better-files-macos#readme")!)
            }
        }
    }
}

private struct GeneralSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsSection(title: "General", rows: ["Open at login", "Sound effects", "Downloads folder", "⌫ alone moves to Trash",
                                                 "Show hidden files"]) {
            SettingsRow(title: "Open at login") { LoginToggle() }
            SettingsRow(title: "Sound effects") { SoundToggle() }
            SettingsRow(title: "Downloads folder") { DownloadsChooser() }
            SettingsRow(title: "⌫ alone moves to Trash") {
                Toggle("⌫ alone moves to Trash", isOn: $model.settings.backspaceTrashes)
            }
            SettingsRow(title: "Show hidden files") { HiddenFilesToggle() }
        }
    }
}

struct LoginToggle: View {
    @State private var on = LoginItem.isOn
    @State private var error: String?

    var body: some View {
        Toggle("Open at login", isOn: $on)
            .onChange(of: on) { (_: Bool, now: Bool) in
                guard now != LoginItem.isOn else { return }
                error = LoginItem.set(now)
                if error != nil { on = LoginItem.isOn }
            }
        if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
}

/// Sound effects on (Soft) or off; the sound itself is chosen in Motion and Sound.
struct SoundToggle: View {
    @Environment(AppModel.self) private var model
    @State private var on = false

    var body: some View {
        Toggle("Sound effects", isOn: $on)
            .onAppear { on = model.settings.sound != .off }
            .onChange(of: model.settings.sound) { on = model.settings.sound != .off }
            .onChange(of: on) { (_: Bool, now: Bool) in
                if now != (model.settings.sound != .off) { model.settings.sound = now ? .soft : .off }
            }
    }
}

private struct HiddenFilesToggle: View {
    @Environment(AppModel.self) private var model
    @State private var on = false

    var body: some View {
        Toggle("Show hidden files", isOn: $on)
            .onAppear { on = model.showHidden }
            .onChange(of: model.showHidden) { on = model.showHidden }
            .onChange(of: on) { if on != model.showHidden { model.toggleHidden() } }
    }
}

private struct DownloadsChooser: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LabeledContent("Downloads folder") {
            HStack {
                Text(model.displayPath(model.downloadsURL)).lineLimit(1).truncationMode(.middle)
                Button("Choose…", action: { choose() })
                if !model.settings.downloadsPath.isEmpty {
                    Button("Use ~/Downloads", action: { model.settings.downloadsPath = "" })
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { model.settings.downloadsPath = FileOps.canonical(url).path }
    }
}

private struct AppearanceSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsSection(title: "Appearance", rows: ["Light / Dark / As the Mac", "Accent colour", "Folder style",
                                                    "Folder colour", "Sidebar size"]) {
            SettingsRow(title: "Light / Dark / As the Mac") {
                Picker("Appearance", selection: $model.settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases, id: \.self) { (a: AppSettings.Appearance) in Text(a.title).tag(a) }
                }
                .pickerStyle(.segmented)
            }
            SettingsRow(title: "Accent colour") { AccentPicker() }
            SettingsRow(title: "Folder style") {
                Picker("Folder style", selection: $model.settings.folderStyle) {
                    ForEach(AppSettings.FolderStyle.allCases, id: \.self) { (s: AppSettings.FolderStyle) in
                        Text(s.rawValue.capitalized).tag(s)
                    }
                }
            }
            SettingsRow(title: "Folder colour") {
                Picker("Folder colour", selection: $model.settings.folderColor) {
                    Text("Accent").tag("accent")
                    ForEach(AppModel.folderColors, id: \.self) { (name: String) in Text(name.capitalized).tag(name) }
                }
            }
            SettingsRow(title: "Sidebar size") {
                Picker("Sidebar size", selection: $model.settings.sidebarSize) {
                    ForEach(AppSettings.SidebarSize.allCases, id: \.self) { (s: AppSettings.SidebarSize) in
                        Text(s.rawValue.capitalized).tag(s)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

/// The Mac's, purple and seven more, or a custom colour.
struct AccentPicker: View {
    @Environment(AppModel.self) private var model
    @State private var custom: Color = .purple

    var body: some View {
        LabeledContent("Accent colour") {
            HStack(spacing: 6) {
                ForEach(AppSettings.accents, id: \.self) { (name: String) in dot(name) }
                ColorPicker("Custom", selection: $custom, supportsOpacity: false).labelsHidden()
            }
        }
        .onChange(of: custom) { (_: Color, c: Color) in
            if let hex = Self.hex(c) { model.settings.accent = hex }
        }
    }

    private func dot(_ name: String) -> some View {
        let chosen: Bool = model.settings.accent == name
        return Button(action: { model.settings.accent = name }) {
            Circle()
                .fill(AppSettings.color(accent: name) ?? Color.accentColor)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(.primary.opacity(chosen ? 0.8 : 0), lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name == "mac" ? "The Mac's accent colour" : name.capitalized)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private static func hex(_ color: Color) -> String? {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let parts: [Int] = [c.redComponent, c.greenComponent, c.blueComponent].map { (v: CGFloat) -> Int in Int((v * 255).rounded()) }
        return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
    }
}

private struct WindowSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsSection(title: "Window", rows: ["Start in the last folder", "Toolbar: New Folder", "Toolbar: Move to Trash"]) {
            SettingsRow(title: "Start in the last folder") {
                Toggle("Start in the last folder", isOn: $model.settings.startInLastFolder)
            }
            SettingsRow(title: "Toolbar: New Folder") {
                Toggle("Toolbar: New Folder button", isOn: $model.settings.toolbarNewFolder)
            }
            SettingsRow(title: "Toolbar: Move to Trash") {
                Toggle("Toolbar: Move to Trash button", isOn: $model.settings.toolbarTrash)
            }
        }
    }
}

private struct MotionSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsSection(title: "Motion and Sound", rows: ["Motion", "Folder-open sound"]) {
            SettingsRow(title: "Motion") {
                Picker("Motion", selection: $model.settings.motion) {
                    ForEach(AppSettings.Motion.allCases, id: \.self) { (m: AppSettings.Motion) in Text(m.rawValue.capitalized).tag(m) }
                }
                .pickerStyle(.segmented)
                Text("With Reduce Motion on, folders fade instead.").font(.caption).foregroundStyle(.secondary)
            }
            SettingsRow(title: "Folder-open sound") {
                Picker("Folder-open sound", selection: $model.settings.sound) {
                    ForEach(AppSettings.Sound.allCases, id: \.self) { (s: AppSettings.Sound) in Text(s.title).tag(s) }
                }
                .onChange(of: model.settings.sound) { Sounds.play(model.settings.sound) }
            }
        }
    }
}

private struct QuickActionsSection: View {
    @Environment(AppModel.self) private var model

    private var order: [QuickAction] {
        model.quickActions + QuickAction.allCases.filter { (a: QuickAction) -> Bool in !model.quickActions.contains(a) }
    }

    var body: some View {
        SettingsSection(title: "Quick Actions", rows: QuickAction.allCases.map { (a: QuickAction) -> String in a.title }) {
            Text("⌘. shows the first six.").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(order.enumerated()), id: \.element) { (pair: (offset: Int, element: QuickAction)) in
                SettingsRow(title: pair.element.title) { row(pair.element, at: pair.offset) }
            }
        }
    }

    private func row(_ action: QuickAction, at index: Int) -> some View {
        HStack {
            Image(systemName: action.symbol).frame(width: 20)
            Text(action.title).foregroundStyle(index < 6 ? Color.primary : Color.secondary)
            Spacer()
            Button(action: { move(index, by: -1) }) { Image(systemName: "chevron.up") }
                .disabled(index == 0).accessibilityLabel("Move \(action.title) up")
            Button(action: { move(index, by: 1) }) { Image(systemName: "chevron.down") }
                .disabled(index == order.count - 1).accessibilityLabel("Move \(action.title) down")
        }
        .buttonStyle(.borderless)
    }

    private func move(_ index: Int, by step: Int) {
        var list: [QuickAction] = order
        list.swapAt(index, index + step)
        model.setQuickActions(list)
    }
}

private struct FolderAccessSection: View {
    @Environment(AppModel.self) private var model
    @State private var opens: [String: Bool] = [:]
    private let folders = ["Desktop", "Documents", "Downloads"]

    var body: some View {
        SettingsSection(title: "Folder Access", rows: folders + ["Check Again", "Open System Settings"]) {
            ForEach(folders, id: \.self) { (name: String) in
                SettingsRow(title: name) {
                    LabeledContent(name) {
                        Text(opens[name] == true ? "Opens" : "Not allowed")
                            .foregroundStyle(opens[name] == true ? Color.secondary : Color.red)
                    }
                }
            }
            SettingsRow(title: "Check Again") {
                HStack {
                    Button("Check Again", action: { check() })
                    Button("Open System Settings", action: { AppModel.openPrivacySettings("Privacy_FilesAndFolders") })
                }
            }
        }
        .onAppear { check() }
    }

    private func check() {
        var found: [String: Bool] = [:]
        for name in folders { found[name] = model.folderOpens(name) }
        opens = found
    }
}

private struct OpenInSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsSection(title: "Open In", rows: ["Terminal", "Editor"]) {
            SettingsRow(title: "Terminal") { DefaultAppPicker(kind: .terminal, title: "Terminal") }
            SettingsRow(title: "Editor") { DefaultAppPicker(kind: .editor, title: "Editor") }
        }
    }
}

/// Reads and writes the "openIn.terminal" / "openIn.editor" defaults (F14.2).
private struct DefaultAppPicker: View {
    let kind: ExternalApp.Kind
    let title: String
    @Environment(AppModel.self) private var model
    @State private var chosen = ""

    private var apps: [ExternalApp] { model.openInApps.filter { (a: ExternalApp) -> Bool in a.kind == kind } }

    var body: some View {
        if apps.isEmpty {
            LabeledContent(title, value: "None installed")
        } else {
            Picker(title, selection: $chosen) {
                ForEach(apps, id: \.id) { (a: ExternalApp) in Text(a.name).tag(a.id) }
            }
            .onAppear { chosen = model.defaultApp(kind)?.id ?? "" }
            .onChange(of: chosen) { if !chosen.isEmpty { model.setDefaultApp(kind, id: chosen) } }
        }
    }
}

private struct DropShelfSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsSection(title: "Drop Shelf", rows: ["Shortcut", "Show on drag", "Pinned folders", "Holding"]) {
            SettingsRow(title: "Shortcut") { ShortcutRow(id: "dropShelf", title: "Drop Shelf shortcut") }
            SettingsRow(title: "Show on drag") {
                Toggle("Show the Drop Shelf when a file drag starts", isOn: $model.settings.dropShelfOnDrag)
            }
            SettingsRow(title: "Pinned folders") {
                ForEach(model.shelfPinned, id: \.self) { (url: URL) in
                    HStack {
                        Text(model.displayPath(url)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Unpin", action: { model.unpinFromShelf([url]) })
                    }
                }
                if model.shelfPinned.isEmpty { Text("No pinned folders").foregroundStyle(.secondary) }
            }
            SettingsRow(title: "Holding") {
                LabeledContent("Holding: \(AppModel.items(model.holding.count))") {
                    Button("Clear", action: { model.clearHolding() }).disabled(model.holding.isEmpty)
                }
            }
        }
    }
}

private struct MenuBarSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsSection(title: "Menu Bar", rows: ["Menu bar icon"]) {
            SettingsRow(title: "Menu bar icon") { Toggle("Show the menu bar icon", isOn: $model.settings.menuBar) }
        }
    }
}

extension AppSettings.Sound {
    var title: String { self == .off ? "Off" : rawValue == "mac" ? "Mac" : rawValue.capitalized }
}
