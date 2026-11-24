import XCTest
@testable import FileOSCore

final class SystemInfoTests: XCTestCase {
    let runner = ScriptedRunner { exe, _ in
        switch (exe as NSString).lastPathComponent {
        case "pmset": return (0, "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=123)\t15%; discharging; 1:02 remaining present: true\n")
        case "sw_vers": return (0, "ProductName:\t\tmacOS\nProductVersion:\t\t15.1\nBuildVersion:\t\t24B83\n")
        case "fdesetup": return (0, "FileVault is Off.\n")
        case "csrutil": return (0, "System Integrity Protection status: enabled.\n")
        case "spctl": return (0, "assessments enabled\n")
        default: throw CommandError.notFound(exe)
        }
    }

    func testHideNamesRemovesUserAndHost() async {
        let user = NSUserName(), host = SystemInfo.hostName()
        let shown = SystemInfo.asText(await SystemInfo.collect(runner: runner, home: makeTempDir(), hideNames: false, macName: "Ada's MacBook"))
        XCTAssertTrue(shown.contains(user))
        XCTAssertTrue(shown.contains("Ada's MacBook"))
        let hidden = SystemInfo.asText(await SystemInfo.collect(runner: runner, home: makeTempDir(), hideNames: true, macName: "Ada's MacBook"))
        XCTAssertFalse(hidden.contains(user), hidden)
        XCTAssertFalse(hidden.contains(host), hidden)
        XCTAssertFalse(hidden.contains("Ada"), hidden)
        XCTAssertTrue(hidden.contains("you@this-mac"))
    }

    func testScrubAndParsers() {
        let g = [InfoGroup(title: "T", rows: [InfoRow(label: "Path", value: "/Users/ada/x on ada-mbp", status: .ok)])]
        XCTAssertEqual(SystemInfo.scrub(g, user: "ada", host: "ada-mbp", mac: nil)[0].rows[0].value, "/Users/you/x on this-mac")
        let words = [InfoGroup(title: "Memory", rows: [InfoRow(label: "Installed", value: "Memory by mem, MEM-2 and mem.")])]
        XCTAssertEqual(SystemInfo.scrub(words, user: "mem", host: "", mac: nil)[0].rows[0].value, "Memory by you, you-2 and you.")
        XCTAssertEqual(SystemInfo.parseBattery("-InternalBattery-0 (id=1)\t87%; charging; 0:40 remaining")?.value, "87%, charging")
        XCTAssertEqual(SystemInfo.parseBattery("-InternalBattery-0 (id=1)\t8%; discharging;")?.status, .bad)
        XCTAssertNil(SystemInfo.parseBattery("Now drawing from 'AC Power'\n"))
        XCTAssertEqual(SystemInfo.duration(3 * 86_400 + 4 * 3600 + 60), "3 days, 4 hours")
        XCTAssertEqual(SystemInfo.duration(125 * 60), "2 hours, 5 minutes")
        XCTAssertEqual(SystemInfo.duration(30), "less than a minute")
    }

    func testAsTextAndNoSerial() async {
        let groups = await SystemInfo.collect(runner: runner, home: makeTempDir(), hideNames: false, displays: ["Built-in, 3024 × 1964"])
        let text = SystemInfo.asText(groups)
        XCTAssertTrue(text.hasPrefix("About This Mac\n"))
        XCTAssertTrue(text.contains("Memory"))
        XCTAssertTrue(text.contains("Built-in, 3024 × 1964"))
        XCTAssertFalse(text.lowercased().contains("serial"))
        #if os(macOS)
        XCTAssertTrue(text.contains("macOS 15.1 (24B83)"))
        XCTAssertEqual(groups.first { $0.title == "Security" }?.rows.first { $0.label == "FileVault" }?.status, .warn)
        XCTAssertEqual(groups.first { $0.title == "Battery" }?.rows.first?.status, .warn)
        #endif
    }
}
