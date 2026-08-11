// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClaudeDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeDeck", path: "Sources/ClaudeDeck"),
        .testTarget(name: "ClaudeDeckTests", dependencies: ["ClaudeDeck"], path: "Tests/ClaudeDeckTests"),
    ]
)
