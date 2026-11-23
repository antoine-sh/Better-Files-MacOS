import Foundation

public enum MarkdownError: Error, Equatable, LocalizedError {
    case cannotShow(String)
    public var errorDescription: String? { if case .cannotShow(let reason) = self { return reason } else { return nil } }
}

/// The Markdown page (F6.3): which files open as a page, the "On this page" outline, and the blocks
/// the preview renders one by one.
public enum Markdown {
    public static let maxPageBytes: Int64 = 5_000_000
    private static let extensions: Set<String> = [".md", ".markdown", ".mdown", ".mkd"]

    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String, id: String)
        case paragraph(String)
        case bullet(String)
        case task(done: Bool, text: String)
        case code(String)
    }

    public static func isMarkdown(_ name: String) -> Bool {
        extensions.contains(splitExtension(name).ext.lowercased())
    }

    /// Why the file can't be a page (over 5 MB, or not UTF-8), or nil when it can.
    public static func canShowAsPage(size: Int64, data: Data) -> String? {
        if size > maxPageBytes { return "it's over 5 MB" }
        if String(data: data, encoding: .utf8) == nil { return "it isn't UTF-8 text" }
        return nil
    }

    /// The page's text, read from a regular file only (links, FIFOs and devices are never opened). Call off the main actor.
    public static func load(_ url: URL) -> Result<String, MarkdownError> {
        guard let size = FileInfo.regularFileSize(url) else { return .failure(.cannotShow("it isn't a regular file")) }
        if let reason = canShowAsPage(size: size, data: Data()) { return .failure(.cannotShow(reason)) }
        guard let data = FileInfo.read(url, upTo: Int(maxPageBytes) + 1) else { return .failure(.cannotShow("it can't be read")) }
        if let reason = canShowAsPage(size: Int64(data.count), data: data) { return .failure(.cannotShow(reason)) }
        return .success(String(decoding: data, as: UTF8.self))
    }

    /// ATX headings outside fenced code, with unique slug ids ("hello-world", "hello-world-1").
    public static func outline(_ src: String) -> [(level: Int, text: String, id: String)] {
        blocks(src).compactMap { (block: Block) -> (level: Int, text: String, id: String)? in
            if case let .heading(level, text, id) = block { return (level, text, id) }
            return nil
        }
    }

    public static func blocks(_ src: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var fence: (char: Character, count: Int)?
        var used: [String: Int] = [:]
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        // "\r\n" is a single Character, so split on any newline rather than on "\n".
        for rawLine in src.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let indent = line.prefix { $0 == " " }.count
            let body = indent <= 3 ? String(line.dropFirst(indent)) : nil
            if let open = fence {
                if let body, let f = fenceMarker(body), f.char == open.char, f.count >= open.count,
                   body.drop(while: { $0 == f.char }).allSatisfy(\.isWhitespace) {
                    out.append(.code((code ?? []).joined(separator: "\n")))
                    fence = nil
                    code = nil
                } else {
                    code?.append(line)
                }
                continue
            }
            if let body, let f = fenceMarker(body) {
                flush()
                fence = f
                code = []
                continue
            }
            if line.allSatisfy(\.isWhitespace) { flush(); continue }
            if let body, let (level, text) = heading(body) {
                flush()
                let base = slug(text)
                let n = used[base, default: 0]
                used[base] = n + 1
                out.append(.heading(level: level, text: text, id: n == 0 ? base : "\(base)-\(n)"))
                continue
            }
            if let item = listItem(line) {
                flush()
                out.append(item)
                continue
            }
            paragraph.append(line)
        }
        if fence != nil { out.append(.code((code ?? []).joined(separator: "\n"))) } // unclosed: runs to the end
        flush()
        return out
    }

    private static func fenceMarker(_ s: String) -> (char: Character, count: Int)? {
        guard let c = s.first, c == "`" || c == "~" else { return nil }
        let n = s.prefix { $0 == c }.count
        return n >= 3 ? (c, n) : nil
    }

    private static func heading(_ s: String) -> (Int, String)? {
        let level = s.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = s.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of #s ("## B ##") is not part of the text.
        let closing = text.reversed().prefix { $0 == "#" }.count
        if closing > 0 {
            let kept = text.dropLast(closing)
            if kept.isEmpty || kept.last == " " || kept.last == "\t" { text = kept.trimmingCharacters(in: .whitespaces) }
        }
        return text.isEmpty ? nil : (level, text)
    }

    private static func listItem(_ line: String) -> Block? {
        let s = line.drop { $0 == " " || $0 == "\t" }
        guard let c = s.first, "-*+".contains(c), s.dropFirst().first == " " else { return nil }
        let item = s.dropFirst(2)
        for (mark, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where item.hasPrefix(mark) {
            return .task(done: done, text: String(item.dropFirst(4)))
        }
        return .bullet(String(item))
    }

    /// GitHub-style anchor: lowercase letters, digits, - and _, spaces as -.
    static func slug(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.compactMap { (u: Unicode.Scalar) -> Character? in
            if CharacterSet.alphanumerics.contains(u) || u == "-" || u == "_" { return Character(u) }
            return u == " " ? "-" : nil
        }
        return String(kept)
    }
}
