// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swiffs",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SwiffsCore", targets: ["SwiffsCore"]),
    ],
    targets: [
        // Pure Swift diff model, patch parsing and diff algorithms. Foundation
        // only, no UI dependencies (the equivalent of libghostty's core).
        .target(name: "SwiffsCore"),
        .testTarget(name: "SwiffsCoreTests", dependencies: ["SwiffsCore"], exclude: ["Fixtures"]),
    ]
)
