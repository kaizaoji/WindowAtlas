// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowAtlas",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "WindowAtlas", resources: [.process("Resources")]),
        .testTarget(name: "WindowAtlasTests", dependencies: ["WindowAtlas"])
    ]
)
