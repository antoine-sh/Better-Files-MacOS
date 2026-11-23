import Foundation

/// Watches one folder's own entries (not subfolders) with a kqueue vnode source.
/// Not actor-isolated: it is owned and driven by a main-actor PaneModel; events hop to the main actor.
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private(set) var url: URL?

    func watch(_ url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        if url == self.url, source != nil { return }
        stop()
        self.url = url
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return } // unreadable or missing: the pane shows why; nothing to watch
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib], queue: .global(qos: .utility))
        src.setEventHandler { Task { @MainActor in onChange() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
        url = nil
    }

    deinit { source?.cancel() }
}
