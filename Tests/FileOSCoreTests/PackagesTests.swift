import XCTest
@testable import FileOSCore

final class PackagesTests: XCTestCase {
    static let brewJSON = """
    {"formulae":[
      {"name":"node","installed":[{"version":"24.1.0","installed_on_request":true}],"dependencies":["icu4c","openssl@3"]},
      {"name":"node@24","installed":[{"version":"24.0.0","installed_on_request":true}],"dependencies":[]},
      {"name":"icu4c","installed":[{"version":"76.1","installed_on_request":false}],"dependencies":[]},
      {"name":"openssl@3","installed":[{"version":"3.4.0","installed_on_request":false}],"dependencies":[]},
      {"name":"oldlib","installed":[{"version":"1.0","installed_on_request":false}],"dependencies":[]}
    ],"casks":[{"token":"firefox","installed":"133.0"}]}
    """

    func testBrewParse() {
        let pkgs = Tool.homebrew.parse(Self.brewJSON, extra: nil)
        XCTAssertEqual(pkgs.map(\.name), ["firefox", "icu4c", "node", "node@24", "oldlib", "openssl@3"])
        let node = pkgs.first { $0.name == "node" }!
        XCTAssertEqual(node.version, "24.1.0")
        XCTAssertEqual(node.source, "You installed")
        XCTAssertFalse(node.isApp)
        XCTAssertEqual(pkgs.first { $0.name == "icu4c" }?.source, "Came with node")
        XCTAssertTrue(pkgs.first { $0.name == "oldlib" }!.leftBehind)
        XCTAssertFalse(pkgs.first { $0.name == "icu4c" }!.leftBehind)
        let ff = pkgs.first { $0.name == "firefox" }!
        XCTAssertTrue(ff.isApp)
        XCTAssertEqual(ff.removeCommand, "brew uninstall --cask firefox")
        XCTAssertEqual(node.removeCommand, "brew uninstall node")
        XCTAssertTrue(Tool.homebrew.parse("not json", extra: nil).isEmpty)
    }

    func testBrewfile() {
        let pkgs = Tool.homebrew.parse(Self.brewJSON, extra: nil)
        XCTAssertEqual(Packages.brewfile(pkgs), "brew \"node\"\nbrew \"node@24\"\ncask \"firefox\"\n")
    }

    func testTwoOfTheSame() {
        let pkgs = Tool.homebrew.parse(Self.brewJSON, extra: nil)
        XCTAssertEqual(Packages.twoOfTheSame(pkgs).map { $0.map(\.name) }, [["node", "node@24"]])
        let npm = Tool.npm.parse(#"{"dependencies":{"@types/node":{"version":"1"},"node":{"version":"2"}}}"#, extra: nil)
        XCTAssertTrue(Packages.twoOfTheSame(npm).isEmpty, "a scope is not a version")
    }

    func testOtherParsers() {
        let npm = Tool.npm.parse(#"{"dependencies":{"typescript":{"version":"5.4.5"},"npm":{"version":"10.0.0"}}}"#, extra: nil)
        XCTAssertEqual(npm.map(\.name), ["npm", "typescript"])
        XCTAssertEqual(npm[0].source, "Came with Node")
        XCTAssertEqual(npm[1].removeCommand, "npm uninstall -g typescript")

        let pip = Tool.pip.parse(#"[{"name":"requests","version":"2.32"},{"name":"idna","version":"3.7"}]"#,
                                 extra: #"[{"name":"requests","version":"2.32"}]"#)
        XCTAssertEqual(pip.map { "\($0.name) \($0.source)" }, ["idna Came with another package", "requests You installed"])

        XCTAssertEqual(Tool.pipx.parse("black 24.1.0\nruff 0.4.1\n", extra: nil).map(\.version), ["24.1.0", "0.4.1"])

        let cargo = Tool.cargo.parse("ripgrep v14.1.0:\n    rg\nbat v0.24.0:\n    bat\n", extra: nil)
        XCTAssertEqual(cargo.map { "\($0.name) \($0.version)" }, ["bat 0.24.0", "ripgrep 14.1.0"])
        XCTAssertEqual(cargo[1].removeCommand, "cargo uninstall ripgrep")

        let gems = Tool.gem.parse("rake (13.0.6, 12.3.3)\nbigdecimal (default: 3.1.1)\n", extra: nil)
        XCTAssertEqual(gems.map { "\($0.name) \($0.version) \($0.source)" },
                       ["bigdecimal 3.1.1 Came with Ruby", "rake 13.0.6 You installed"])

        let go = Tool.go.parse("/Users/x/go/bin/gopls: go1.22.0\n\tpath\tgolang.org/x/tools/gopls\n\tmod\tgolang.org/x/tools/gopls\tv0.15.0\th1:abc\n", extra: nil)
        XCTAssertEqual(go.map { "\($0.name) \($0.version)" }, ["gopls v0.15.0"])
        XCTAssertNil(go[0].removeCommand)
    }

    #if os(macOS)
    func testPipAndGemNeedTheDeveloperTools() async {
        let runner = ScriptedRunner { exe, _ in
            if exe == "xcode-select" { return (2, "") }
            XCTAssertFalse(exe == "pip3" || exe == "gem", "ran the \(exe) stub")
            throw CommandError.notFound(exe)
        }
        _ = await Packages.list(runner: runner, home: makeTempDir())
    }
    #endif

    func testListSkipsMissingToolsAndRunsOnlyListCommands() async {
        let home = makeTempDir()
        let runner = ScriptedRunner { exe, args in
            XCTAssertFalse(args.contains("uninstall") || args.contains("cleanup") || args.contains("install") && exe != "cargo",
                           "\(exe) \(args)")
            if exe.hasSuffix("brew") { return (0, Self.brewJSON) }
            throw CommandError.notFound(exe)
        }
        let tools = await Packages.list(runner: runner, home: home)
        XCTAssertEqual(tools.map(\.tool), [.homebrew])
        XCTAssertEqual(tools.first?.packages.count, 6)
        XCTAssertEqual(Tool.homebrew.cleanCommand, "brew cleanup")
    }
}
