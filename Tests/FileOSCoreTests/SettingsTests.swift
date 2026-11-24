import XCTest
@testable import FileOSCore

final class SettingsTests: XCTestCase {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    func testEmptyJSONIsAllDefaults() throws {
        let s = try decode("{}")
        XCTAssertEqual(s, AppSettings())
        XCTAssertEqual(s.appearance, .system)
        XCTAssertEqual(s.accent, "mac")
        XCTAssertEqual(s.folderStyle, .glass)
        XCTAssertEqual(s.sidebarSize, .medium)
        XCTAssertEqual(s.motion, .quiet)
        XCTAssertEqual(s.sound, .off) // off by default (F17.4)
        XCTAssertFalse(s.backspaceTrashes)
        XCTAssertTrue(s.startInLastFolder)
        XCTAssertEqual(s.downloadsPath, "")
        XCTAssertTrue(s.dropShelfOnDrag)
        XCTAssertTrue(s.menuBar)
        XCTAssertFalse(s.welcomed)
    }

    func testPartialJSONKeepsOtherDefaults() throws {
        let s = try decode(#"{"motion":"zoom"}"#)
        var expected = AppSettings()
        expected.motion = .zoom
        XCTAssertEqual(s, expected)
    }

    func testUnknownOrDamagedValuesFallBackPerField() throws {
        let s = try decode(#"{"motion":"warp","appearance":42,"welcomed":true,"future":"x"}"#)
        XCTAssertEqual(s.motion, .quiet)
        XCTAssertEqual(s.appearance, .system)
        XCTAssertTrue(s.welcomed)
    }

    func testRoundTrip() throws {
        var s = AppSettings()
        s.appearance = .dark
        s.accent = "#FF8800"
        s.folderStyle = .finder
        s.folderColor = "teal"
        s.sidebarSize = .large
        s.motion = .glide
        s.sound = .wood
        s.backspaceTrashes = true
        s.startInLastFolder = false
        s.downloadsPath = "/tmp/dl"
        s.dropShelfOnDrag = false
        s.menuBar = false
        s.toolbarNewFolder = true
        s.toolbarTrash = true
        s.welcomed = true
        s.whatsNewSeen = "1.0"
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testReduceMotionTurnsMovementIntoAFade() {
        XCTAssertEqual(AppSettings.Motion.none.transition(reduceMotion: false), .none)
        XCTAssertEqual(AppSettings.Motion.quiet.transition(reduceMotion: false), .fade)
        XCTAssertEqual(AppSettings.Motion.glide.transition(reduceMotion: false), .slide)
        XCTAssertEqual(AppSettings.Motion.zoom.transition(reduceMotion: false), .zoom)
        XCTAssertEqual(AppSettings.Motion.glide.transition(reduceMotion: true), .fade)
        XCTAssertEqual(AppSettings.Motion.zoom.transition(reduceMotion: true), .fade)
        XCTAssertEqual(AppSettings.Motion.none.transition(reduceMotion: true), .none)
    }

    func testHexColours() {
        XCTAssertEqual(AppSettings.rgb(hex: "#FF8000")?.r, 1)
        XCTAssertEqual(AppSettings.rgb(hex: "#ff8000")?.b, 0)
        XCTAssertNil(AppSettings.rgb(hex: "purple"))
        XCTAssertNil(AppSettings.rgb(hex: "#GG0000"))
        XCTAssertEqual(AppSettings.accents.count, 9) // the Mac's + 8
    }

    func testSettingsSearch() {
        XCTAssertTrue(SettingsSearch.matches("", section: "General", row: "Open at login"))
        XCTAssertTrue(SettingsSearch.matches("login", section: "General", row: "Open at login"))
        XCTAssertTrue(SettingsSearch.matches("GENERAL", section: "General", row: "Open at login"))
        XCTAssertTrue(SettingsSearch.matches("general login", section: "General", row: "Open at login"))
        XCTAssertFalse(SettingsSearch.matches("dark", section: "General", row: "Open at login"))
        XCTAssertTrue(SettingsSearch.visible("dark", section: "Appearance", rows: ["Light / Dark", "Accent"]))
        XCTAssertFalse(SettingsSearch.visible("zzz", section: "Appearance", rows: ["Light / Dark", "Accent"]))
    }

    func testWelcomeSteps() {
        XCTAssertEqual(WelcomeStep.steps(offerMove: true),
                       [.demo, .tour, .moveToApplications, .fullDiskAccess, .makeYours])
        XCTAssertFalse(WelcomeStep.steps(offerMove: false).contains(.moveToApplications))
        XCTAssertTrue(WelcomeStep.offersMove(bundlePath: "/Users/me/Downloads/FileOS.app"))
        XCTAssertFalse(WelcomeStep.offersMove(bundlePath: "/Applications/FileOS.app"))
        XCTAssertFalse(WelcomeStep.offersMove(bundlePath: "/Users/me/src/.build/debug")) // not an app bundle
    }

    func testWhatsNew() {
        var s = AppSettings()
        XCTAssertFalse(Release.showsWhatsNew(s)) // a new user gets the welcome instead
        s.welcomed = true
        XCTAssertTrue(Release.showsWhatsNew(s))
        s.whatsNewSeen = Release.version
        XCTAssertFalse(Release.showsWhatsNew(s))
        XCTAssertFalse(Release.notes.isEmpty)
    }

    func testRemovedShortcutNeverConflicts() {
        var map = Shortcuts.defaults
        map["viewList"] = KeyCombo.none
        map["viewIcons"] = KeyCombo.none
        XCTAssertNil(Shortcuts.conflict(in: map, action: "viewList", combo: .none))
        XCTAssertEqual(Shortcuts.merged(["viewList": .none])["viewList"], KeyCombo.none)
        XCTAssertTrue(KeyCombo.none.isNone)
        XCTAssertEqual(Shortcuts.title("goDocuments"), "Go Documents")
        XCTAssertEqual(Shortcuts.title("pinnedWorkspace3"), "Pinned Workspace 3")
        XCTAssertEqual(Shortcuts.title("trashF8"), "Trash F8")
    }
}
