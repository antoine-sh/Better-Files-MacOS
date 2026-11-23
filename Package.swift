// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [.library(name: "FileOSCore", targets: ["FileOSCore"])]
var targets: [Target] = [
    .target(name: "FileOSCore"),
    .testTarget(name: "FileOSCoreTests", dependencies: ["FileOSCore"]),
]

#if os(macOS)
products.append(.executable(name: "FileOSApp", targets: ["FileOSApp"]))
targets.append(.executableTarget(name: "FileOSApp", dependencies: ["FileOSCore"]))
#endif

let package = Package(
    name: "FileOS",
    platforms: [.macOS(.v15)],
    products: products,
    targets: targets
)
