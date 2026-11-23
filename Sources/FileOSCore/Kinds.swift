import Foundation

public enum FileKind: String, CaseIterable, Sendable {
    case pdfs = "PDFs", images = "Images", screenshots = "Screenshots", videos = "Videos"
    case installers = "Installers", archives = "Archives", audio = "Audio", documents = "Documents", other = "Other"

    private static let byExt: [String: FileKind] = {
        let table: [FileKind: [String]] = [
            .pdfs: ["pdf"],
            .images: ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg"],
            .videos: ["mp4", "mov", "mkv", "avi", "webm", "m4v"],
            .installers: ["dmg", "pkg", "exe", "msi", "deb", "appimage"],
            .archives: ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz"],
            .audio: ["mp3", "wav", "flac", "aac", "m4a", "ogg", "aiff"],
            .documents: ["doc", "docx", "txt", "md", "rtf", "pages", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "csv", "odt"],
        ]
        return Dictionary(uniqueKeysWithValues: table.flatMap { kind, exts in exts.map { ($0, kind) } })
    }()

    public static func of(_ name: String) -> FileKind {
        let lower = name.lowercased()
        let (_, ext) = splitExtension(lower)
        if (ext == ".png" || ext == ".jpg" || ext == ".jpeg"),
           lower.hasPrefix("screenshot ") || lower.hasPrefix("screen shot ") { return .screenshots }
        guard let last = ext.split(separator: ".").last else { return .other }
        return byExt[String(last)] ?? .other
    }
}

private let compoundExtensions = [".tar.gz", ".tar.bz2", ".tar.xz"]

/// `ext` includes the leading dot ("" when none). A leading-dot name has no extension.
public func splitExtension(_ name: String) -> (base: String, ext: String) {
    let lower = name.lowercased()
    for c in compoundExtensions where lower.hasSuffix(c) && name.count > c.count {
        return (String(name.dropLast(c.count)), String(name.suffix(c.count)))
    }
    guard let i = name.lastIndex(of: "."), i != name.startIndex, name.index(after: i) != name.endIndex else { return (name, "") }
    return (String(name[..<i]), String(name[i...]))
}

public func isDownloading(_ name: String) -> Bool {
    let lower = name.lowercased()
    return [".crdownload", ".download", ".part", ".opdownload"].contains { lower.hasSuffix($0) }
}

public func formatBytes(_ n: Int64) -> String {
    if n < 1000 { return "\(n) bytes" }
    var v = Double(n)
    var i = -1
    let units = ["KB", "MB", "GB", "TB"]
    repeat { v /= 1000; i += 1 } while v >= 1000 && i < units.count - 1
    return String(format: "%.1f %@", v, units[i])
}
