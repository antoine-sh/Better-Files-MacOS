import XCTest
@testable import FileOSCore

final class BookmarksTests: XCTestCase {
    private func url(_ s: String) -> URL { Bookmarks.normalize(s)! }

    func testNormalize() {
        XCTAssertEqual(Bookmarks.normalize("  example.com/a ")?.absoluteString, "https://example.com/a")
        XCTAssertEqual(Bookmarks.normalize("HTTPS://Example.COM")?.absoluteString, "https://example.com/")
        XCTAssertEqual(Bookmarks.normalize("http://a.io/x?y=1")?.absoluteString, "http://a.io/x?y=1")
        XCTAssertNil(Bookmarks.normalize("file:///etc/passwd"))
        XCTAssertNil(Bookmarks.normalize("javascript:alert(1)"))
        XCTAssertNil(Bookmarks.normalize("hello world"))
        XCTAssertNil(Bookmarks.normalize(""))
    }

    func testAddTwiceIsAlready() {
        let (s1, b1, already1) = Bookmarks.add(BookmarkState(), url: url("https://www.example.com/post"), collection: nil)
        XCTAssertFalse(already1)
        XCTAssertEqual(s1.bookmarks.count, 1)
        XCTAssertEqual(b1.site, "example.com")
        XCTAssertEqual(b1.title, "example.com")
        XCTAssertEqual(b1.type, .article)
        let (s2, b2, already2) = Bookmarks.add(s1, url: url("www.example.com/post"), collection: nil)
        XCTAssertTrue(already2)
        XCTAssertEqual(b2.id, b1.id)
        XCTAssertEqual(s2.bookmarks.count, 1)
    }

    func testAddIntoCollection() {
        let (s0, c) = Bookmarks.createCollection(BookmarkState(), name: "Design", icon: "paintbrush")
        let (s1, b, _) = Bookmarks.add(s0, url: url("https://a.com"), collection: c.id)
        XCTAssertEqual(b.collections, [c.id])
        XCTAssertEqual(s1.collections.map(\.name), ["Design"])
    }

    func testParseTags() {
        XCTAssertEqual(Bookmarks.parseTags("design, #swift"), ["design", "swift"])
        XCTAssertEqual(Bookmarks.parseTags("#a #b, a,, "), ["a", "b"])
        XCTAssertEqual(Bookmarks.parseTags(""), [])
    }

    func testLinkType() {
        XCTAssertEqual(Bookmarks.linkType(url("https://youtu.be/x")), .video)
        XCTAssertEqual(Bookmarks.linkType(url("https://www.youtube.com/watch?v=1")), .video)
        XCTAssertEqual(Bookmarks.linkType(url("https://vimeo.com/1")), .video)
        XCTAssertEqual(Bookmarks.linkType(url("https://a.com/clip.MP4")), .video)
        XCTAssertEqual(Bookmarks.linkType(url("https://a.com/p.png")), .image)
        XCTAssertEqual(Bookmarks.linkType(url("https://a.com/doc.pdf")), .file)
        XCTAssertEqual(Bookmarks.linkType(url("https://a.com/app.dmg")), .file)
        XCTAssertEqual(Bookmarks.linkType(url("https://a.com/post")), .article)
    }

    func testExtractMetaReadsOgTagsAndResolvesRelative() {
        let html = """
        <html><head><title>Fallback</title>
        <meta property="og:title" content="Big &amp; Bold">
        <meta content="/img/cover.jpg" property="og:image" />
        <link rel="shortcut icon" href="/icon.png">
        </head></html>
        """
        let meta = Bookmarks.extractMeta(html: html, base: url("https://site.com/posts/1"))
        XCTAssertEqual(meta.title, "Big & Bold")
        XCTAssertEqual(meta.image, "https://site.com/img/cover.jpg")
        XCTAssertEqual(meta.icon, "https://site.com/icon.png")
    }

    func testExtractMetaFallsBackToTitleAndRejectsOtherSchemes() {
        let html = "<TITLE>\n Plain  page </TITLE><link rel='icon' href='data:image/png;base64,AAAA'><meta property='og:image' content='file:///x.png'>"
        let meta = Bookmarks.extractMeta(html: html, base: url("https://site.com/"))
        XCTAssertEqual(meta.title, "Plain page")
        XCTAssertNil(meta.icon)
        XCTAssertNil(meta.image)
    }

    func testExtractMetaDropsImagesAndIconsOnPrivateHosts() {
        let html = "<meta property='og:image' content='http://169.254.169.254/latest/meta-data'><link rel='icon' href='http://localhost:8080/x.png'>"
        let meta = Bookmarks.extractMeta(html: html, base: url("https://site.com/"))
        XCTAssertNil(meta.image)
        XCTAssertNil(meta.icon)
        let local = Bookmarks.extractMeta(html: "<link rel='icon' href='/i.png'>", base: url("http://192.168.1.1/"))
        XCTAssertNil(local.icon) // relative to a private base is private too
    }

    func testIsFetchable() {
        XCTAssertTrue(Bookmarks.isFetchable(url("https://site.com/a.png")))
        XCTAssertFalse(Bookmarks.isFetchable(url("http://10.0.0.1/a.png")))
        XCTAssertFalse(Bookmarks.isFetchable(URL(string: "file:///etc/passwd")))
        XCTAssertFalse(Bookmarks.isFetchable(nil))
    }

    func testDeletingACollectionRemovesItsLinks() {
        var (s, c) = Bookmarks.createCollection(BookmarkState(), name: "Reading", icon: "book")
        (s, _, _) = Bookmarks.add(s, url: url("https://a.com"), collection: c.id)
        (s, _, _) = Bookmarks.add(s, url: url("https://b.com"), collection: nil)
        let after = Bookmarks.deleteCollection(s, c.id)
        XCTAssertTrue(after.collections.isEmpty)
        XCTAssertEqual(after.bookmarks.map(\.site), ["b.com"])
    }

    func testFilterSortAndSearch() {
        var s = BookmarkState()
        let t0 = Date(timeIntervalSince1970: 1000)
        (s, _, _) = Bookmarks.add(s, url: url("https://zeta.com/a"), collection: nil, now: t0)
        (s, _, _) = Bookmarks.add(s, url: url("https://youtu.be/b"), collection: nil, now: t0.addingTimeInterval(10))
        (s, _, _) = Bookmarks.add(s, url: url("https://alpha.org/c"), collection: nil, now: t0.addingTimeInterval(20))
        s = Bookmarks.update(s, s.bookmarks[0].id) { $0.tags = ["swift"]; $0.favourite = true }
        let all = s.bookmarks
        XCTAssertEqual(Bookmarks.filter(all, sort: .newest).map(\.site), ["alpha.org", "youtu.be", "zeta.com"])
        XCTAssertEqual(Bookmarks.filter(all, sort: .oldest).map(\.site), ["zeta.com", "youtu.be", "alpha.org"])
        XCTAssertEqual(Bookmarks.filter(all, sort: .site).map(\.site), ["alpha.org", "youtu.be", "zeta.com"])
        XCTAssertEqual(Bookmarks.filter(all, filter: .videos, sort: .newest).map(\.site), ["youtu.be"])
        XCTAssertEqual(Bookmarks.filter(all, filter: .favourites, sort: .newest).map(\.site), ["zeta.com"])
        XCTAssertEqual(Bookmarks.filter(all, query: "SWI", sort: .newest).map(\.site), ["zeta.com"])
        XCTAssertEqual(Bookmarks.filter(all, query: "alpha.org/c", sort: .newest).count, 1)
        XCTAssertEqual(Bookmarks.filter(all, tag: "swift", sort: .newest).count, 1)
        XCTAssertEqual(Bookmarks.filter(all, filter: .unsorted, sort: .newest).count, 3)
        XCTAssertEqual(Bookmarks.tags(all), ["swift"])
        XCTAssertEqual(Bookmarks.remove(s, [s.bookmarks[0].id]).bookmarks.count, 2)
    }

    func testCodableKeepsPaletteFields() throws {
        let (s, b, _) = Bookmarks.add(BookmarkState(), url: url("https://a.com/x"), collection: nil)
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s.bookmarks)) as! [[String: Any]]
        XCTAssertEqual(raw[0]["id"] as? String, b.id.uuidString)
        XCTAssertEqual(raw[0]["url"] as? String, "https://a.com/x")
        XCTAssertEqual(raw[0]["title"] as? String, "a.com")
    }

    func testExtractMetaStaysFastOnHostileHTML() {
        let hostile = String(repeating: "<title>", count: 8000) + String(repeating: "<meta content=x ", count: 8000)
            + String(repeating: "<link rel=icon ", count: 8000) + String(repeating: "a", count: 900_000)
        let start = Date()
        let meta = Bookmarks.extractMeta(html: hostile, base: url("https://site.com/"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertNil(meta.icon)
    }

    func testExtractMetaClampsTheTitleAndReadsOnlyTheHead() {
        let long = String(repeating: "word ", count: 200)
        let html = "<head><title>\(long)</title></head><body><meta property=\"og:image\" content=\"/late.png\"></body>"
        let meta = Bookmarks.extractMeta(html: html, base: url("https://site.com/"))
        XCTAssertLessThanOrEqual(meta.title?.count ?? 0, 300)
        XCTAssertNil(meta.image)
    }

    func testPublicHosts() {
        for host in ["example.com", "8.8.8.8", "172.32.0.1", "[2606:4700::1]"] {
            XCTAssertTrue(Bookmarks.isPublicHost(host), host)
        }
        for host in ["localhost", "a.localhost", "printer.local", "127.0.0.1", "10.1.2.3", "172.16.0.9", "192.168.1.1",
                     "169.254.169.254", "0.0.0.0", "100.64.0.1", "[::1]", "::1", "[fe80::1]", "fd00::2", "", "2130706433"] {
            XCTAssertFalse(Bookmarks.isPublicHost(host), host)
        }
    }
}
