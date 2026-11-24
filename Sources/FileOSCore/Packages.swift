import Foundation

/// F14.3 package managers. FileOS only lists: remove and clean commands are text for the clipboard.
public enum Tool: String, CaseIterable, Sendable, Codable {
    case homebrew, npm, pip, pipx, cargo, gem, go

    public var name: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .npm: return "npm"
        case .pip: return "pip"
        case .pipx: return "pipx"
        case .cargo: return "Cargo"
        case .gem: return "RubyGems"
        case .go: return "Go"
        }
    }

    /// The read-only listing command; `home` locates tools installed per user.
    func listCommand(home: URL) -> (exe: String, args: [String]) {
        switch self {
        case .homebrew: return (Self.first(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) ?? "brew", ["info", "--json=v2", "--installed"])
        // shortcut: npm is a `#!/usr/bin/env node` script, so it fails when node isn't on the app's PATH; pass PATH when CommandRunner takes an environment.
        case .npm: return ("npm", ["ls", "-g", "--depth=0", "--json"])
        case .pip: return ("pip3", ["list", "--format=json"])
        case .pipx: return (Self.first([home.path + "/.local/bin/pipx"]) ?? "pipx", ["list", "--short"])
        case .cargo: return (Self.first([home.path + "/.cargo/bin/cargo"]) ?? "cargo", ["install", "--list"])
        case .gem: return ("gem", ["list", "--local"])
        case .go: return (Self.first(["/usr/local/go/bin/go", "/opt/homebrew/bin/go"]) ?? "go", ["version", "-m", home.path + "/go/bin"])
        }
    }

    /// pip: the packages nothing else needs, to tell "You installed" from "Came with".
    func extraCommand() -> (exe: String, args: [String])? {
        self == .pip ? ("pip3", ["list", "--not-required", "--format=json"]) : nil
    }

    public static func removeCommand(_ tool: Tool, name: String, isApp: Bool = false) -> String? {
        switch tool {
        case .homebrew: return isApp ? "brew uninstall --cask \(name)" : "brew uninstall \(name)"
        case .npm: return "npm uninstall -g \(name)"
        case .pip: return "pip3 uninstall \(name)"
        case .pipx: return "pipx uninstall \(name)"
        case .cargo: return "cargo uninstall \(name)"
        case .gem: return "gem uninstall \(name)"
        case .go: return nil // binaries in ~/go/bin are removed by hand
        }
    }

    public var cleanCommand: String? {
        switch self {
        case .homebrew: return "brew cleanup"
        case .npm: return "npm cache clean --force"
        case .pip: return "pip3 cache purge"
        case .gem: return "gem cleanup"
        case .go: return "go clean -cache"
        case .pipx, .cargo: return nil
        }
    }

    public func cacheDir(home: URL) -> URL? {
        switch self {
        case .homebrew: return home.appendingPathComponent("Library/Caches/Homebrew")
        case .npm: return home.appendingPathComponent(".npm/_cacache")
        case .pip: return home.appendingPathComponent("Library/Caches/pip")
        case .go: return home.appendingPathComponent("Library/Caches/go-build")
        case .pipx, .cargo, .gem: return nil
        }
    }

    /// Where the tool puts a package's command, for "last run".
    func binary(_ name: String, home: URL) -> [String] {
        switch self {
        case .homebrew: return ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        case .cargo: return [home.path + "/.cargo/bin/\(name)"]
        case .go: return [home.path + "/go/bin/\(name)"]
        case .pipx: return [home.path + "/.local/bin/\(name)"]
        case .npm, .pip, .gem: return []
        }
    }

    private static func first(_ paths: [String]) -> String? { paths.first { FileManager.default.isExecutableFile(atPath: $0) } }

    public func parse(_ output: String, extra: String?) -> [Package] {
        let out: [Package]
        switch self {
        case .homebrew: out = Self.parseBrew(output)
        case .npm:
            let deps = (Self.json(output) as? [String: Any])?["dependencies"] as? [String: Any] ?? [:]
            out = deps.map { (name, info) in
                let bundled = ["npm", "corepack"].contains(name)
                return Package(tool: self, name: name, version: (info as? [String: Any])?["version"] as? String ?? "",
                               source: bundled ? "Came with Node" : "You installed")
            }
        case .pip:
            let top = Set(Self.pipNames(extra ?? "").map(\.name))
            out = Self.pipNames(output).map {
                Package(tool: self, name: $0.name, version: $0.version,
                        source: extra == nil || top.contains($0.name) ? "You installed" : "Came with another package")
            }
        case .pipx:
            out = Self.words(output).map { Package(tool: self, name: $0[0], version: $0.count > 1 ? $0[1] : "", source: "You installed") }
        case .cargo:
            // "ripgrep v14.1.0:" then indented binary names.
            out = output.split(separator: "\n").filter { !$0.hasPrefix(" ") && $0.hasSuffix(":") }.compactMap {
                let parts = $0.dropLast().split(separator: " ")
                guard let name = parts.first else { return nil }
                let version = parts.count > 1 ? String(parts[1].drop { $0 == "v" }) : ""
                return Package(tool: self, name: String(name), version: version, source: "You installed")
            }
        case .gem:
            // "rake (13.0.6, 12.3.3)" or "bigdecimal (default: 3.1.1)".
            out = output.split(separator: "\n").compactMap {
                guard let open = $0.firstIndex(of: "(") else { return nil }
                let name = $0[..<open].trimmingCharacters(in: .whitespaces)
                let inside = $0[$0.index(after: open)...].prefix { $0 != ")" }
                let first = inside.split(separator: ",").first.map(String.init) ?? ""
                let isDefault = first.hasPrefix("default: ")
                let version = isDefault ? String(first.dropFirst("default: ".count)) : first
                return name.isEmpty ? nil : Package(tool: self, name: name, version: version,
                                                    source: isDefault ? "Came with Ruby" : "You installed")
            }
        case .go:
            // `go version -m dir`: "<path>: go1.x" then "\tmod\t<module>\t<version>".
            var list: [Package] = []
            for line in output.split(separator: "\n") {
                if !line.hasPrefix("\t"), let colon = line.range(of: ": go") {
                    let name = (String(line[..<colon.lowerBound]) as NSString).lastPathComponent
                    list.append(Package(tool: self, name: name, version: "", source: "You installed"))
                } else if line.hasPrefix("\tmod\t"), !list.isEmpty {
                    let cols = line.split(separator: "\t")
                    if cols.count >= 3 { list[list.count - 1].version = String(cols[2]) }
                }
            }
            out = list
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func json(_ s: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(s.utf8)) }

    private static func words(_ s: String) -> [[String]] {
        s.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }.filter { !$0.isEmpty }
    }

    private static func pipNames(_ s: String) -> [(name: String, version: String)] {
        ((json(s) as? [[String: Any]]) ?? []).compactMap {
            guard let name = $0["name"] as? String else { return nil }
            return (name, $0["version"] as? String ?? "")
        }
    }

    private struct BrewInfo: Decodable {
        struct Formula: Decodable {
            struct Installed: Decodable { let version: String; let installed_on_request: Bool? }
            let name: String
            let installed: [Installed]
            let dependencies: [String]?
        }
        struct Cask: Decodable { let token: String; let installed: String? }
        let formulae: [Formula]?
        let casks: [Cask]?
    }

    private static func parseBrew(_ s: String) -> [Package] {
        guard let info = try? JSONDecoder().decode(BrewInfo.self, from: Data(s.utf8)) else { return [] }
        let formulae = info.formulae ?? []
        let onRequest = Set(formulae.filter { $0.installed.contains { $0.installed_on_request == true } }.map(\.name))
        var out: [Package] = formulae.map { f in
            var p = Package(tool: .homebrew, name: f.name, version: f.installed.last?.version ?? "", source: "You installed")
            if !onRequest.contains(f.name) {
                // Prefer a parent the user asked for; no parent at all means it was left behind.
                let parents = formulae.filter { $0.dependencies?.contains(f.name) == true }.map(\.name)
                let parent = parents.first { onRequest.contains($0) } ?? parents.first
                p.source = "Came with \(parent ?? "another package")"
                p.leftBehind = parent == nil
            }
            return p
        }
        out += (info.casks ?? []).map { Package(tool: .homebrew, name: $0.token, version: $0.installed ?? "", source: "You installed", isApp: true) }
        return out
    }
}

public struct Package: Sendable, Hashable, Identifiable {
    public let tool: Tool
    public let name: String
    public var version: String
    /// "You installed" or "Came with X".
    public var source: String
    public var isApp = false
    /// Came with something that is no longer installed.
    public var leftBehind = false
    public var lastRun: Date?

    public var id: String { "\(tool.rawValue):\(name)" }
    public var youInstalled: Bool { source == "You installed" }
    public var removeCommand: String? { Tool.removeCommand(tool, name: name, isApp: isApp) }
}

public struct ToolPackages: Sendable, Identifiable {
    public let tool: Tool
    public let packages: [Package]
    public let cacheBytes: Int64
    public var id: Tool { tool }
}

public enum Packages {
    /// Runs each tool's listing in parallel; tools that aren't installed (or fail) are left out.
    public static func list(runner: CommandRunner, home: URL) async -> [ToolPackages] {
        await withTaskGroup(of: ToolPackages?.self) { group in
            for tool in Tool.allCases {
                group.addTask { await load(tool, runner: runner, home: home) }
            }
            var all: [ToolPackages] = []
            for await t in group { if let t { all.append(t) } }
            return all.sorted { Tool.allCases.firstIndex(of: $0.tool)! < Tool.allCases.firstIndex(of: $1.tool)! }
        }
    }

    static func load(_ tool: Tool, runner: CommandRunner, home: URL) async -> ToolPackages? {
        let cmd = tool.listCommand(home: home)
        guard let out = try? await runner.run(cmd.exe, cmd.args, timeout: 60), out.status == 0 else { return nil }
        var extra: String?
        if let e = tool.extraCommand(), let r = try? await runner.run(e.exe, e.args, timeout: 60), r.status == 0 { extra = r.stdout }
        let packages = tool.parse(out.stdout, extra: extra).map { p -> Package in
            var p = p
            p.lastRun = lastRun(tool.binary(p.name, home: home))
            return p
        }
        let cache = tool.cacheDir(home: home).map { FileOps.directorySize($0, maxEntries: 50_000).bytes } ?? 0
        return ToolPackages(tool: tool, packages: packages, cacheBytes: cache)
    }

    // shortcut: last access time of the command file; volumes mounted noatime report the install time.
    static func lastRun(_ paths: [String]) -> Date? {
        for path in paths {
            if let d = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate { return d }
        }
        return nil
    }

    /// Not run for 90 days.
    public static func notRunLately(_ p: Package, now: Date) -> Bool {
        guard let last = p.lastRun else { return false }
        return now.timeIntervalSince(last) > 90 * 86_400
    }

    /// `node` and `node@24`: same name before "@" (a leading "@scope/" isn't a version).
    public static func twoOfTheSame(_ packages: [Package]) -> [[Package]] {
        func base(_ name: String) -> String {
            let start = name.hasPrefix("@") ? name.index(after: name.startIndex) : name.startIndex
            guard let at = name[start...].firstIndex(of: "@") else { return name }
            return String(name[..<at])
        }
        let groups = Dictionary(grouping: packages) { "\($0.tool.rawValue):\(base($0.name))" }
        return groups.values.filter { $0.count > 1 }.map { $0.sorted { $0.name < $1.name } }.sorted { $0[0].name < $1[0].name }
    }

    /// "Save List…": a Brewfile of what the user installed with Homebrew.
    public static func brewfile(_ packages: [Package]) -> String {
        let brew = packages.filter { $0.tool == .homebrew && $0.youInstalled }
        let lines = brew.filter { !$0.isApp }.map { "brew \"\($0.name)\"" } + brew.filter(\.isApp).map { "cask \"\($0.name)\"" }
        return lines.map { $0 + "\n" }.joined()
    }
}
