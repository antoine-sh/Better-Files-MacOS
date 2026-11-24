import AppKit
import FileOSCore

/// F17.4: the folder-open sound. Off by default, and silent while the Mac's "Play user interface sound
/// effects" is off.
@MainActor
enum Sounds {
    static func name(_ sound: AppSettings.Sound) -> String? {
        switch sound {
        case .off: return nil
        case .soft: return "Pop"
        case .click: return "Tink"
        case .wood: return "Bottle"
        case .mac: return "Purr"
        }
    }

    /// The system's setting; read where System Settings writes it (absent means on).
    static var systemAllowsUISounds: Bool {
        let value = CFPreferencesCopyAppValue("com.apple.sound.uiaudio.enabled" as CFString, "com.apple.systemsound" as CFString)
        return (value as? NSNumber)?.boolValue ?? true
    }

    static func play(_ sound: AppSettings.Sound) {
        guard !AppMain.isSelfTest, systemAllowsUISounds, let name = name(sound), let s = NSSound(named: NSSound.Name(name)) else { return }
        s.volume = sound == .soft ? 0.35 : 0.6
        s.stop() // a fast second folder restarts it
        s.play()
    }
}
