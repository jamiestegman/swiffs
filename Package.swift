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
        .library(name: "SwiffsHighlight", targets: ["SwiffsHighlight"]),
        .library(name: "SwiffsEditor", targets: ["SwiffsEditor"]),
        .library(name: "SwiffsUI", targets: ["SwiffsUI"]),
    ],
    targets: [
        // Pure Swift diff model, patch parsing and diff algorithms. Foundation
        // only, no UI dependencies (the equivalent of libghostty's core).
        .target(name: "SwiffsCore"),
        // Vendored Oniguruma, the regex engine used by TextMate grammars.
        .target(
            name: "COniguruma",
            exclude: [
                "COPYING",
                "README.md",
                "src/unicode_fold_data.c",
                "src/unicode_property_data.c",
                "src/unicode_property_data_posix.c",
                "src/unicode_wb_data.c",
                "src/unicode_egcb_data.c",
            ],
            cSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("include"),
            ]
        ),
        // TextMate grammar tokenizer (vscode-textmate port) and the Shiki
        // highlighting layer, with bundled grammars and themes.
        .target(
            name: "SwiffsHighlight",
            dependencies: ["COniguruma", "SwiffsCore"],
            resources: [
                .copy("Resources/Languages"),
                .copy("Resources/Themes"),
            ]
        ),
        // Editor model: piece table, text document, edit history, selections
        // and commands. No UI dependencies.
        .target(
            name: "SwiffsEditor",
            dependencies: ["SwiffsCore", "SwiffsHighlight"]
        ),
        // AppKit views: FileDiffView, FileView, CodeView and SwiftUI wrappers.
        .target(
            name: "SwiffsUI",
            dependencies: ["SwiffsCore", "SwiffsHighlight", "SwiffsEditor"]
        ),
        // Development tool: renders views offscreen to PNG for visual checks.
        .executableTarget(
            name: "swiffs-snapshot",
            dependencies: ["SwiffsCore", "SwiffsHighlight", "SwiffsEditor", "SwiffsUI"]
        ),
        // Demo app: `swift run SwiffsDemo`.
        .executableTarget(
            name: "SwiffsDemo",
            dependencies: ["SwiffsCore", "SwiffsHighlight", "SwiffsEditor", "SwiffsUI"],
            path: "Examples/SwiffsDemo",
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "SwiffsHighlightTests", dependencies: ["SwiffsHighlight"], exclude: ["Fixtures"]),
        .testTarget(name: "SwiffsCoreTests", dependencies: ["SwiffsCore"], exclude: ["Fixtures"]),
        .testTarget(name: "SwiffsEditorTests", dependencies: ["SwiffsEditor"], exclude: ["Fixtures"]),
    ]
)
