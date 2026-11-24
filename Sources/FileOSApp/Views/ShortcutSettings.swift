import SwiftUI
import AppKit
import FileOSCore

/// Records the next key press for one shortcut row: Esc keeps the old shortcut, ⌫ removes it (F17.5).
@MainActor @Observable
final class KeyRecorder {
    static let shared = KeyRecorder()
    private(set) var target: String?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var done: (@MainActor (KeyCombo) -> Void)?

    func start(_ id: String, done: @escaping @MainActor (KeyCombo) -> Void) {
        stop()
        target = id
        self.done = done
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] (event: NSEvent) -> NSEvent? in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        target = nil
        done = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard target != nil else { return false }
        let mods: NSEvent.ModifierFlags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods.isEmpty && event.keyCode == 53 { // kVK_Escape: keep
            stop()
            return true
        }
        var combo: KeyCombo = .none
        if !(mods.isEmpty && event.keyCode == 51) { // kVK_Delete alone removes
            // A bare key would take that key from typing; only F-keys may stand alone.
            guard let pressed = Self.combo(event), pressed.canBeGlobal || pressed.isFunctionKey else {
                NSSound.beep()
                return true
            }
            combo = pressed
        }
        let finish: (@MainActor (KeyCombo) -> Void)? = done
        stop()
        finish?(combo)
        return true
    }

    static func combo(_ event: NSEvent) -> KeyCombo? {
        let flags: NSEvent.ModifierFlags = event.modifierFlags
        var key: String? = HotKey.key(forCode: event.keyCode)
        if key == nil, let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 { key = chars }
        guard var name = key else { return nil }
        var shift: Bool = flags.contains(.shift)
        if name == "=" && shift { // ⌘+ is typed as ⇧⌘= on most layouts
            name = "+"
            shift = false
        }
        return KeyCombo(key: name, command: flags.contains(.command), shift: shift,
                        option: flags.contains(.option), control: flags.contains(.control))
    }
}

extension KeyCombo {
    var isFunctionKey: Bool { key.count > 1 && key.hasPrefix("f") && Int(key.dropFirst()) != nil }
    var settingsLabel: String { isNone ? "None" : description }
}

/// One shortcut: click and press new keys, Reset; a clash asks "Keep It There" / "Use It Here". Fixed ones are disabled.
struct ShortcutRow: View {
    let id: String
    let title: String
    @Environment(AppModel.self) private var model
    @State private var pending: KeyCombo = .none
    @State private var other = ""
    @State private var showConflict = false
    @State private var error: String?

    private var fixed: Bool { Shortcuts.fixed.contains(id) }
    private var recording: Bool { KeyRecorder.shared.target == id }
    private var current: KeyCombo { model.shortcuts[id] ?? .none }
    private var original: KeyCombo { Shortcuts.defaults[id] ?? .none }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title) { buttons }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .alert("\(pending.settingsLabel) is used by “\(Shortcuts.title(other))”", isPresented: $showConflict) {
            Button("Keep It There", role: .cancel, action: {})
            Button("Use It Here", action: { error = model.useShortcutHere(id, pending, from: other) })
        }
    }

    private var buttons: some View {
        HStack {
            Button(action: { toggleRecording() }) {
                Text(recording ? "Press keys…" : current.settingsLabel).frame(minWidth: 90)
            }
            .disabled(fixed)
            .accessibilityLabel("\(title) shortcut: \(current.settingsLabel)")
            Button("Reset", action: { apply(original) }).disabled(fixed || current == original)
        }
    }

    private func toggleRecording() {
        if recording {
            KeyRecorder.shared.stop()
            return
        }
        error = nil
        KeyRecorder.shared.start(id, done: { (combo: KeyCombo) in apply(combo) })
    }

    private func apply(_ combo: KeyCombo) {
        if let taken = Shortcuts.conflict(in: model.shortcuts, action: id, combo: combo) {
            pending = combo
            other = taken
            showConflict = true
        } else {
            error = model.setShortcut(id, combo)
        }
    }
}

struct ShortcutsSection: View {
    @Environment(AppModel.self) private var model
    @State private var restoreError: String?
    /// The Drop Shelf's shortcut is under Drop Shelf.
    private static let ids: [String] = Shortcuts.defaults.keys
        .filter { (k: String) -> Bool in k != "dropShelf" }
        .sorted { (a: String, b: String) -> Bool in Shortcuts.title(a) < Shortcuts.title(b) }
    private static let titles: [String] = ids.map { (k: String) -> String in Shortcuts.title(k) }

    var body: some View {
        SettingsSection(title: "Shortcuts", rows: Self.titles + ["Restore Defaults"]) {
            Text("Click a shortcut and press new keys. Esc keeps it, ⌫ removes it.").font(.caption).foregroundStyle(.secondary)
            ForEach(Self.ids, id: \.self) { (id: String) in
                SettingsRow(title: Shortcuts.title(id)) { ShortcutRow(id: id, title: Shortcuts.title(id)) }
            }
            SettingsRow(title: "Restore Defaults") {
                Button("Restore Defaults", action: { restoreError = model.restoreDefaultShortcuts() })
                if let restoreError { Text(restoreError).font(.caption).foregroundStyle(.red) }
            }
        }
        .onDisappear { KeyRecorder.shared.stop() }
    }
}
