// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DozzleDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DozzleDesk", targets: ["DozzleDesk"]),
    ],
    targets: [
        // Platform-neutral logic: SSE parsing, Dozzle models, state reducer, connection policy.
        .target(name: "DozzleCore"),
        // AppKit/SwiftUI desktop panel + menu bar item.
        .executableTarget(name: "DozzleDesk", dependencies: ["DozzleCore"]),
        .testTarget(name: "DozzleCoreTests", dependencies: ["DozzleCore"]),
    ],
    swiftLanguageModes: [.v5]
)
