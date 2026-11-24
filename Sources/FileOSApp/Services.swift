import AppKit
import FileOSCore

/// F12.1 Services > "Save Link to FileOS" (declared under NSServices in scripts/bundle.sh).
@MainActor
final class ServiceProvider: NSObject {
    let model: AppModel
    init(model: AppModel) { self.model = model }

    @objc func saveLink(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text: String? = (pboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.absoluteString
            ?? pboard.string(forType: .string)
        guard let text, model.saveLink(text) else {
            error.pointee = "That isn't a link"
            return
        }
    }
}
