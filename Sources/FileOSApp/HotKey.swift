import Carbon
import FileOSCore

/// The Drop Shelf's global shortcut (F15.1), through Carbon's RegisterEventHotKey: it works while another app
/// is frontmost and needs no Accessibility permission. One instance, one hotkey.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) { self.action = action }

    /// Replaces any earlier registration. False when the system refused it (taken, or a key it can't use);
    /// the earlier shortcut is gone either way, as the user asked for the new one.
    func register(_ combo: KeyCombo) -> Bool {
        unregister()
        guard combo.canBeGlobal, let code = Self.keyCode(combo.key) else { return false }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let me: UnsafeMutableRawPointer = Unmanaged.passUnretained(self).toOpaque()
            guard InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &spec, me, &handler) == noErr else { return false }
        }
        let id = EventHotKeyID(signature: 0x4653_4F53, id: 1) // "FSOS"
        var newRef: EventHotKeyRef?
        let status: OSStatus = RegisterEventHotKey(code, Self.modifiers(combo), id, GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else { return false }
        ref = newRef
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    /// Quit: the hotkey and its handler go away.
    func stop() {
        unregister()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    fileprivate func fire() { action() }

    static func modifiers(_ combo: KeyCombo) -> UInt32 {
        var m = 0
        if combo.command { m |= cmdKey }
        if combo.option { m |= optionKey }
        if combo.control { m |= controlKey }
        if combo.shift { m |= shiftKey }
        return UInt32(m)
    }

    /// ANSI virtual key codes (kVK_*) for `KeyCombo.key`.
    static func keyCode(_ key: String) -> UInt32? { codes[key] }

    private static let codes: [String: UInt32] = {
        var map: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, "`": 50, "space": 49, "return": 36, "tab": 48, "delete": 51, "escape": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let fKeys: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in fKeys.enumerated() { map["f\(i + 1)"] = code }
        return map
    }()
}

/// Carbon calls this on the main thread for the application event target.
private func hotKeyPressed(_ call: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    let bits = Int(bitPattern: data)
    MainActor.assumeIsolated {
        guard let pointer = UnsafeRawPointer(bitPattern: bits) else { return }
        Unmanaged<HotKey>.fromOpaque(pointer).takeUnretainedValue().fire()
    }
    return noErr
}
