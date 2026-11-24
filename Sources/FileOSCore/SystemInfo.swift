import Foundation
#if canImport(Glibc)
import Glibc
#endif

public enum InfoStatus: String, Sendable { case ok, warn, bad }

public struct InfoRow: Sendable, Equatable, Identifiable {
    public let label: String
    public var value: String
    public let status: InfoStatus
    public init(label: String, value: String, status: InfoStatus = .ok) {
        self.label = label; self.value = value; self.status = status
    }
    public var id: String { label }
}

public struct InfoGroup: Sendable, Equatable, Identifiable {
    public let title: String
    public var rows: [InfoRow]
    public init(title: String, rows: [InfoRow]) { self.title = title; self.rows = rows }
    public var id: String { title }
}

/// F14.5 About This Mac. Reads nothing sensitive: no serial number, hardware UUID or network addresses.
public enum SystemInfo {
    public static func collect(runner: CommandRunner, home: URL, hideNames: Bool, macName: String? = nil,
                               displays: [String] = [], now: Date = Date()) async -> [InfoGroup] {
        let info = ProcessInfo.processInfo
        let user = NSUserName(), host = hostName()
        var mac = [InfoRow(label: "Name", value: macName ?? host),
                   InfoRow(label: "Signed in as", value: "\(user)@\(host)"),
                   InfoRow(label: "Uptime", value: duration(info.systemUptime))]
        #if os(macOS)
        if let setup = (try? FileManager.default.attributesOfItem(atPath: "/var/db/.AppleSetupDone"))?[.creationDate] as? Date {
            mac.append(InfoRow(label: "In use since", value: setup.formatted(date: .long, time: .omitted)))
        }
        #endif
        var groups = [InfoGroup(title: "This Mac", rows: mac)]
        #if os(macOS)
        if let row = parseBattery(await output(runner, "/usr/bin/pmset", ["-g", "batt"])) {
            groups.append(InfoGroup(title: "Battery", rows: [row]))
        }
        #endif
        groups.append(InfoGroup(title: "Memory", rows: [InfoRow(label: "Installed", value: "\(info.physicalMemory / 1_073_741_824) GB")]))
        groups.append(InfoGroup(title: "Chip", rows: [InfoRow(label: "Name", value: chipName()),
                                                      InfoRow(label: "Cores", value: "\(info.processorCount)")]))
        let disk = FileOps.diskInfo(for: home)
        let used = disk.total > 0 ? Double(disk.total - disk.free) / Double(disk.total) : 0
        groups.append(InfoGroup(title: "Disk", rows: [InfoRow(label: "Available", value: "\(formatBytes(disk.free)) of \(formatBytes(disk.total))",
                                                              status: used >= 0.95 ? .bad : used >= 0.9 ? .warn : .ok)]))
        if !displays.isEmpty {
            groups.append(InfoGroup(title: "Displays", rows: displays.enumerated().map { InfoRow(label: "Display \($0.offset + 1)", value: $0.element) }))
        }
        #if os(macOS)
        groups.append(InfoGroup(title: "Security", rows: await security(runner)))
        let sw = await output(runner, "/usr/bin/sw_vers", [])
        let os = ["ProductName", "ProductVersion"].compactMap { field(sw, $0) }.joined(separator: " ")
        let build = field(sw, "BuildVersion").map { " (\($0))" } ?? ""
        groups.append(InfoGroup(title: "Software", rows: [InfoRow(label: "System", value: os.isEmpty ? info.operatingSystemVersionString : os + build)]))
        #else
        groups.append(InfoGroup(title: "Software", rows: [InfoRow(label: "System", value: info.operatingSystemVersionString)]))
        #endif
        return hideNames ? scrub(groups, user: user, host: host, mac: macName) : groups
    }

    /// Hide Names: the user becomes "you" and the Mac "this-mac", wherever they appear.
    public static func scrub(_ groups: [InfoGroup], user: String, host: String, mac: String?) -> [InfoGroup] {
        var names: [(String, String)] = []
        for h in [host, (host as NSString).deletingPathExtension, mac ?? ""] where !h.isEmpty { names.append((h, "this-mac")) }
        names.append((NSFullUserName(), "you"))
        names.append((user, "you"))
        // Longest first, so "ada-mbp" goes before "ada"; very short names would mangle other words.
        let sorted = names.filter { $0.0.count >= 2 }.sorted { $0.0.count > $1.0.count }
        return groups.map { g in
            var g = g
            for i in g.rows.indices {
                if g.rows[i].label == "Signed in as" { g.rows[i].value = "you@this-mac"; continue }
                if g.title == "This Mac" && g.rows[i].label == "Name" { g.rows[i].value = "this-mac"; continue }
                for (name, replacement) in sorted {
                    g.rows[i].value = replaceWord(name, with: replacement, in: g.rows[i].value)
                }
            }
            return g
        }
    }

    /// Hide Names with this Mac's own names, for groups already on screen.
    public static func scrub(_ groups: [InfoGroup], macName: String?) -> [InfoGroup] {
        scrub(groups, user: NSUserName(), host: hostName(), mac: macName)
    }

    /// Whole words only, ignoring case: "mem" goes, "Memory" stays.
    static func replaceWord(_ word: String, with replacement: String, in text: String) -> String {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                           withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    public static func asText(_ groups: [InfoGroup]) -> String {
        var lines = ["About This Mac"]
        for g in groups {
            lines.append("")
            lines.append(g.title)
            lines += g.rows.map { "  \($0.label): \($0.value)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func hostName() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return "" }
        return text(buf)
    }

    private static func text(_ buf: [CChar]) -> String {
        String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// "-InternalBattery-0 (id=…)\t87%; charging; …"; nil on a Mac without a battery.
    static func parseBattery(_ pmset: String) -> InfoRow? {
        guard let line = pmset.split(separator: "\n").first(where: { $0.contains("InternalBattery") }),
              let tab = line.firstIndex(of: "\t") else { return nil }
        let parts = line[line.index(after: tab)...].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let pct = parts.first, let n = Int(pct.dropLast()) else { return nil }
        let state = parts.count > 1 ? parts[1] : ""
        let charging = state == "charging" || state == "charged" || state == "finishing charge"
        let status: InfoStatus = charging ? .ok : n < 10 ? .bad : n < 20 ? .warn : .ok
        return InfoRow(label: "Charge", value: state.isEmpty ? pct : "\(pct), \(state)", status: status)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        func unit(_ n: Int, _ w: String) -> String { "\(n) \(w)\(n == 1 ? "" : "s")" }
        if d > 0 { return h > 0 ? "\(unit(d, "day")), \(unit(h, "hour"))" : unit(d, "day") }
        if h > 0 { return m > 0 ? "\(unit(h, "hour")), \(unit(m, "minute"))" : unit(h, "hour") }
        return m > 0 ? unit(m, "minute") : "less than a minute"
    }

    private static func output(_ runner: CommandRunner, _ exe: String, _ args: [String]) async -> String {
        (try? await runner.run(exe, args, timeout: 5))?.stdout ?? ""
    }

    private static func field(_ text: String, _ key: String) -> String? {
        text.split(separator: "\n").first { $0.hasPrefix(key + ":") }
            .map { $0.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces) }
    }

    #if os(macOS)
    private static func security(_ runner: CommandRunner) async -> [InfoRow] {
        let fv = await output(runner, "/usr/bin/fdesetup", ["status"])
        let sip = await output(runner, "/usr/bin/csrutil", ["status"])
        let gk = await output(runner, "/usr/sbin/spctl", ["--status"])
        func row(_ label: String, _ text: String, on: String, off: String, offStatus: InfoStatus) -> InfoRow {
            if text.contains(on) { return InfoRow(label: label, value: "On") }
            if text.contains(off) { return InfoRow(label: label, value: "Off", status: offStatus) }
            return InfoRow(label: label, value: "Unknown", status: .warn)
        }
        return [row("FileVault", fv, on: "is On", off: "is Off", offStatus: .warn),
                row("System Integrity Protection", sip, on: "enabled", off: "disabled", offStatus: .bad),
                row("Gatekeeper", gk, on: "assessments enabled", off: "assessments disabled", offStatus: .warn)]
    }
    #endif

    private static func chipName() -> String {
        #if os(macOS)
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "Unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 else { return "Unknown" }
        return text(buf)
        #else
        let cpu = (try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8)) ?? ""
        return field(cpu.replacingOccurrences(of: "\t", with: ""), "model name") ?? "Unknown"
        #endif
    }
}
