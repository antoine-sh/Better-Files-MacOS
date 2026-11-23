import Foundation

public enum LinkType: String, Codable, CaseIterable, Sendable { case article, video, image, file }

public struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var url: String
    public var title: String
    public var site: String
    public var icon: String?
    public var image: String?
    public var type: LinkType
    public var tags: [String]
    public var favourite: Bool
    public var collections: [UUID]
    public var added: Date

    public init(id: UUID = UUID(), url: String, title: String, site: String, icon: String? = nil, image: String? = nil,
                type: LinkType, tags: [String] = [], favourite: Bool = false, collections: [UUID] = [], added: Date = Date()) {
        self.id = id; self.url = url; self.title = title; self.site = site; self.icon = icon; self.image = image
        self.type = type; self.tags = tags; self.favourite = favourite; self.collections = collections; self.added = added
    }
}

/// A named group of links (F12.2). Not called `Collection`, which would shadow Swift's protocol for every importer.
public struct BookmarkCollection: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var icon: String

    public init(id: UUID = UUID(), name: String, icon: String) { self.id = id; self.name = name; self.icon = icon }
}

public struct BookmarkState: Codable, Equatable, Sendable {
    public var bookmarks: [Bookmark]
    public var collections: [BookmarkCollection]

    public init(bookmarks: [Bookmark] = [], collections: [BookmarkCollection] = []) {
        self.bookmarks = bookmarks; self.collections = collections
    }
}

/// F12.3 filters; `.unsorted` is the sidebar's "Unsorted" (in no collection).
public enum BookmarkFilter: String, CaseIterable, Sendable {
    case all = "All", articles = "Articles", videos = "Videos", images = "Images", files = "Files"
    case favourites = "Favourites", unsorted = "Unsorted"

    func matches(_ b: Bookmark) -> Bool {
        switch self {
        case .all: return true
        case .articles: return b.type == .article
        case .videos: return b.type == .video
        case .images: return b.type == .image
        case .files: return b.type == .file
        case .favourites: return b.favourite
        case .unsorted: return b.collections.isEmpty
        }
    }
}

public enum BookmarkSort: String, CaseIterable, Sendable { case newest = "Newest", oldest = "Oldest", name = "Name", site = "Site" }

/// Pure edits on the saved links: each returns a new state, so undo is putting the previous one back.
public enum Bookmarks {
    /// A typed or pasted address as an http(s) URL; anything else (file:, javascript:, plain words) is nil.
    public static func normalize(_ text: String) -> URL? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        guard var c = URLComponents(string: s.contains("://") ? s : "https://" + s),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host?.lowercased(), host.contains(".") || host == "localhost" else { return nil }
        c.scheme = scheme
        c.host = host
        if c.path.isEmpty { c.path = "/" }
        return c.url
    }

    static func site(_ url: URL) -> String {
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Saves `url` unless it's already saved, in which case the saved one comes back with `already`.
    public static func add(_ state: BookmarkState, url: URL, collection: UUID?, now: Date = Date())
        -> (BookmarkState, Bookmark, already: Bool) {
        let address = (normalize(url.absoluteString) ?? url).absoluteString
        if let saved = state.bookmarks.first(where: { $0.url == address }) { return (state, saved, true) }
        let site = site(url)
        let b = Bookmark(url: address, title: site, site: site, type: linkType(url),
                         collections: collection.map { [$0] } ?? [], added: now)
        var next = state
        next.bookmarks.append(b)
        return (next, b, false)
    }

    private static let videoHosts: Set<String> = ["youtube.com", "m.youtube.com", "youtu.be", "vimeo.com", "player.vimeo.com"]

    public static func linkType(_ url: URL) -> LinkType {
        if videoHosts.contains(site(url).lowercased()) { return .video }
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "webm", "m4v": return .video
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "avif": return .image
        case "pdf", "zip", "dmg": return .file
        default: return .article
        }
    }

    /// "design, #swift" → ["design", "swift"]; commas or # separate, repeats are dropped.
    public static func parseTags(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text.split(whereSeparator: { $0 == "," || $0 == "#" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    public static func tags(_ list: [Bookmark]) -> [String] {
        Array(Set(list.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public static func filter(_ list: [Bookmark], filter: BookmarkFilter = .all, query: String = "", collection: UUID? = nil,
                              tag: String? = nil, sort: BookmarkSort) -> [Bookmark] {
        let q = query.trimmingCharacters(in: .whitespaces)
        func has(_ s: String) -> Bool { s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        let kept = list.filter { b in
            filter.matches(b)
                && (collection.map { b.collections.contains($0) } ?? true)
                && (tag.map { t in b.tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } } ?? true)
                && (q.isEmpty || has(b.title) || has(b.url) || has(b.site) || b.tags.contains(where: has))
        }
        func byName(_ a: Bookmark, _ b: Bookmark) -> Bool { a.title.localizedStandardCompare(b.title) == .orderedAscending }
        switch sort {
        case .newest: return kept.sorted { $0.added > $1.added }
        case .oldest: return kept.sorted { $0.added < $1.added }
        case .name: return kept.sorted(by: byName)
        case .site: return kept.sorted { $0.site == $1.site ? byName($0, $1) : $0.site.localizedStandardCompare($1.site) == .orderedAscending }
        }
    }

    public static func update(_ state: BookmarkState, _ id: UUID, _ edit: (inout Bookmark) -> Void) -> BookmarkState {
        var next = state
        if let i = next.bookmarks.firstIndex(where: { $0.id == id }) { edit(&next.bookmarks[i]) }
        return next
    }

    public static func remove(_ state: BookmarkState, _ ids: Set<UUID>) -> BookmarkState {
        var next = state
        next.bookmarks.removeAll { ids.contains($0.id) }
        return next
    }

    public static func createCollection(_ state: BookmarkState, name: String, icon: String) -> (BookmarkState, BookmarkCollection) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = BookmarkCollection(name: trimmed.isEmpty ? "Untitled Collection" : trimmed, icon: icon.isEmpty ? "folder" : icon)
        var next = state
        next.collections.append(c)
        return (next, c)
    }

    /// Deletes the collection and every link in it, even ones also in other collections.
    public static func deleteCollection(_ state: BookmarkState, _ id: UUID) -> BookmarkState {
        var next = state
        next.collections.removeAll { $0.id == id }
        next.bookmarks.removeAll { $0.collections.contains(id) }
        return next
    }

    // MARK: Page metadata

    /// False for addresses that point into the user's own machine or network (loopback, private, link-local,
    /// CGNAT, multicast, `.local`), and for numeric hosts that aren't a plain dotted quad, so a saved link can
    /// never make the app fetch from them.
    // shortcut: checks the host as written; a public name that resolves to a private address still passes —
    // resolve and check before connecting if links ever fetch more than a page's <head>
    public static func isPublicHost(_ raw: String) -> Bool {
        var host = raw.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"),
              !host.hasSuffix(".internal") else { return false }
        if host.contains(":") { // IPv6 literal
            let blocked = ["fe8", "fe9", "fea", "feb", "fc", "fd", "ff", "::ffff:", "64:ff9b:"]
            return host != "::" && host != "::1" && !blocked.contains { host.hasPrefix($0) }
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard let last = labels.last, last.allSatisfy(\.isNumber) || last.hasPrefix("0x") else { return true }
        // Numeric: only an unambiguous dotted quad (no hex, octal-looking or shortened forms).
        let octets = labels.compactMap { (l: Substring) -> Int? in
            l.count > 1 && l.hasPrefix("0") ? nil : Int(l).flatMap { $0 <= 255 ? $0 : nil }
        }
        guard labels.count == 4, octets.count == 4 else { return false }
        let (a, b) = (octets[0], octets[1])
        switch a {
        case 0, 10, 127: return false
        case 100 where (64...127).contains(b): return false
        case 169 where b == 254: return false
        case 172 where (16...31).contains(b): return false
        case 192 where b == 168: return false
        case 224...255: return false
        default: return true
        }
    }

    /// The part of a page worth reading: up to `</head>`, and never more than 128 KB, so hostile HTML stays cheap.
    static func head(_ html: String) -> String {
        let limited = html.utf8.count > 131_072 ? String(decoding: html.utf8.prefix(131_072), as: UTF8.self) : html
        guard let end = limited.range(of: "</head>", options: .caseInsensitive) else { return limited }
        return String(limited[..<end.lowerBound])
    }

    /// og:title (else `<title>`), og:image and the `rel=icon` link, resolved against `base`; only http(s) results.
    /// Every pattern is linear: tags can't span a `<`, and are at most 2 KB.
    public static func extractMeta(html fullHTML: String, base: URL) -> (title: String?, image: String?, icon: String?) {
        let html = head(fullHTML)
        var ogTitle: String?, image: String?, icon: String?
        for tag in matches(#"<meta\b[^<>]{0,2048}>"#, in: html) {
            let a = attributes(tag)
            guard let content = a["content"] else { continue }
            switch (a["property"] ?? a["name"])?.lowercased() {
            case "og:title": ogTitle = ogTitle ?? content
            case "og:image": image = image ?? content
            default: break
            }
        }
        for tag in matches(#"<link\b[^<>]{0,2048}>"#, in: html) where icon == nil {
            let a = attributes(tag)
            let rel = (a["rel"] ?? "").lowercased().split(separator: " ")
            if rel.contains("icon") || rel.contains("apple-touch-icon") { icon = a["href"] }
        }
        let plainTitle = firstGroup(#"<title[^<>]{0,256}>([^<]*)"#, in: html)
        let title = (ogTitle ?? plainTitle).map { (t: String) -> String in
            String(decode(t).split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(300))
        }
        return (title?.isEmpty == true ? nil : title, resolve(image, base), resolve(icon, base))
    }

    private static func resolve(_ ref: String?, _ base: URL) -> String? {
        guard let ref, let url = URL(string: decode(ref).trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url.absoluteString
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = regex(pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    private static func firstGroup(_ pattern: String, in s: String) -> String? {
        guard let m = regex(pattern)?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func attributes(_ tag: String) -> [String: String] {
        guard let re = regex(#"([a-zA-Z:_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#) else { return [:] }
        var out: [String: String] = [:]
        for m in re.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let k = Range(m.range(at: 1), in: tag) else { continue }
            let value = (2...4).lazy.compactMap { Range(m.range(at: $0), in: tag) }.first.map { String(tag[$0]) } ?? ""
            out[tag[k].lowercased()] = out[tag[k].lowercased()] ?? value
        }
        return out
    }

    private static func decode(_ s: String) -> String {
        var out = s
        for (entity, char) in [("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&lt;", "<"),
                               ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: char, options: .caseInsensitive)
        }
        return out
    }
}
