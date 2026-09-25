import Foundation
import SwiffsCore
import Testing
@testable import SwiffsHighlight

/// Concurrent and pooled highlighting must produce exactly what one serial
/// highlighter does.
struct ConcurrencyInvarianceTests {
    /// A diff with well over `concurrentSideLineThreshold` lines per side,
    /// built from the stress samples.
    static func largeDiff() throws -> FileDiffMetadata {
        let old = RenderStressParityTests.fixture.fileCases
            .filter { $0.file.lang != "ansi" }
            .map(\.file.contents)
            .joined(separator: "\n")
        var lines = old.components(separatedBy: "\n")
        for index in stride(from: 3, to: lines.count, by: 11) {
            lines[index] = lines[index].uppercased()
        }
        return try parseDiffFromFile(
            oldFile: FileContents(name: "big.ts", contents: old),
            newFile: FileContents(name: "big.ts", contents: lines.joined(separator: "\n"))
        )
    }

    @Test func concurrentSidesMatchSerial() throws {
        let diff = try Self.largeDiff()
        #expect(min(diff.deletionLines.count, diff.additionLines.count) >= DiffsHighlighter.concurrentSideLineThreshold)
        for theme in [ThemeSelection.pair(DiffsConstants.defaultThemes), .single("github-dark")] {
            let options = RenderDiffOptions(theme: theme)
            let serial = try DiffsHighlighter().renderDiff(diff, options: options)
            let concurrent = DiffsHighlighter()
            concurrent.sideHighlighter = DiffsHighlighter()
            let result = try concurrent.renderDiff(diff, options: options)
            #expect(result.deletionLines == serial.deletionLines)
            #expect(result.additionLines == serial.additionLines)
        }
    }

    @Test func workerPoolMatchesSerial() async throws {
        let diff = try Self.largeDiff()
        let options = RenderDiffOptions()
        let serial = try DiffsHighlighter().renderDiff(diff, options: options)
        let pool = HighlightWorkerPool(workerCount: 2, cacheCapacity: 4)
        // Several requests at once, so workers run in parallel.
        let results = try await withThrowingTaskGroup(of: ThemedDiffResult.self) { group in
            for _ in 0 ..< 3 {
                group.addTask { try await pool.highlightDiff(diff, options: options) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        for result in results {
            #expect(result.deletionLines == serial.deletionLines)
            #expect(result.additionLines == serial.additionLines)
        }
    }
}
