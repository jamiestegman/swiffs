import Foundation
import SwiffsCore
import Testing
@testable import SwiffsHighlight

/// Rough throughput check; run with `SWIFFS_BENCH=1 swift test -c release`.
struct PerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFFS_BENCH"] != nil))
    func highlightLargeTypeScriptFile() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/highlight.json")
        let cases = try JSONDecoder().decode([HighlightParityTests.Case].self, from: Data(contentsOf: url))
        let source = cases.filter { $0.lang == "typescript" }.map(\.code).joined(separator: "\n")
        let code = Array(repeating: source, count: 3).joined(separator: "\n")
        let lineCount = code.split(separator: "\n", omittingEmptySubsequences: false).count
        let highlighter = DiffsHighlighter()
        let file = FileContents(name: "big.ts", contents: code)
        // Warm up grammar compilation.
        _ = try highlighter.renderFile(FileContents(name: "a.ts", contents: "const a = 1"), options: RenderFileOptions())
        let start = Date()
        let result = try highlighter.renderFile(file, options: RenderFileOptions())
        let elapsed = Date().timeIntervalSince(start)
        print("BENCH highlighted \(lineCount) lines (\(result.lines.count)) with 2 themes in \(Int(elapsed * 1000))ms")
    }
}
