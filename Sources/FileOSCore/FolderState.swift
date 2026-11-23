import Foundation

/// What a pane shows for its folder: the contents, the locked-folder screen (F3.13), or a message.
/// Permission errors must land on `.locked` so an unreadable folder is never a blank pane.
public enum FolderState: Equatable, Sendable {
    case contents, locked(folder: String), unavailable(String)

    public init(error: FileOSError?) {
        switch error {
        case nil: self = .contents
        case .accessDenied(let path)?: self = .locked(folder: (path as NSString).lastPathComponent)
        case let other?: self = .unavailable(other.errorDescription ?? "This folder can't be opened")
        }
    }

    public static func lockedTitle(_ folder: String) -> String { "FileOS needs access to “\(folder)”" }
}
