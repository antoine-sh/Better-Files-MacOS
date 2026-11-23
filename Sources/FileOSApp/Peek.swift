import AppKit
import Quartz

/// Space: a Quick Look panel over the given files.
// shortcut: macOS Quick Look until Task 7's Peek window replaces it
@MainActor
enum Peek {
    private static var source: PeekSource?

    static func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        let src = PeekSource(urls: urls)
        source = src
        panel.dataSource = src
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
}

final class PeekSource: NSObject, QLPreviewPanelDataSource {
    let urls: [URL]
    init(urls: [URL]) { self.urls = urls }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}
