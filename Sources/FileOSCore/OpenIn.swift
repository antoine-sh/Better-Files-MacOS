import Foundation

public struct ExternalApp: Sendable, Identifiable {
    public enum Kind: Sendable { case terminal, editor }
    public let id: String
    public let name: String
    public let kind: Kind
    public let bundleName: String

    public init(id: String, name: String, kind: Kind, bundleName: String) {
        self.id = id; self.name = name; self.kind = kind; self.bundleName = bundleName
    }
}

public enum OpenIn {
    public static let apps: [ExternalApp] = ([
        ("terminal", "Terminal", .terminal, "Terminal"),
        ("iterm", "iTerm", .terminal, "iTerm"),
        ("warp", "Warp", .terminal, "Warp"),
        ("ghostty", "Ghostty", .terminal, "Ghostty"),
        ("vscode", "VS Code", .editor, "Visual Studio Code"),
        ("vscode-insiders", "VS Code Insiders", .editor, "Visual Studio Code - Insiders"),
        ("cursor", "Cursor", .editor, "Cursor"),
        ("windsurf", "Windsurf", .editor, "Windsurf"),
        ("zed", "Zed", .editor, "Zed"),
        ("xcode", "Xcode", .editor, "Xcode"),
        ("sublime", "Sublime Text", .editor, "Sublime Text"),
        ("nova", "Nova", .editor, "Nova"),
        ("bbedit", "BBEdit", .editor, "BBEdit"),
        ("idea", "IntelliJ IDEA", .editor, "IntelliJ IDEA"),
        ("pycharm", "PyCharm", .editor, "PyCharm"),
        ("webstorm", "WebStorm", .editor, "WebStorm"),
        ("goland", "GoLand", .editor, "GoLand"),
        ("clion", "CLion", .editor, "CLion"),
        ("rider", "Rider", .editor, "Rider"),
        ("phpstorm", "PhpStorm", .editor, "PhpStorm"),
        ("rubymine", "RubyMine", .editor, "RubyMine"),
        ("androidstudio", "Android Studio", .editor, "Android Studio"),
        ("cmux", "cmux", .terminal, "cmux"),
    ] as [(String, String, ExternalApp.Kind, String)]).map { ExternalApp(id: $0.0, name: $0.1, kind: $0.2, bundleName: $0.3) }

    /// Terminal: the first selected folder, else cwd. Editor: the first selected item, else cwd.
    public static func target(kind: ExternalApp.Kind, selection: [URL], cwd: URL) -> URL {
        switch kind {
        case .editor: return selection.first ?? cwd
        case .terminal:
            return selection.first { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0.path, isDirectory: &d) && d.boolValue } ?? cwd
        }
    }
}
