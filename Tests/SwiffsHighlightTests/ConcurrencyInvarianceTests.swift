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

    /// Independent highlighters share compiled regexes process-wide; heavy
    /// parallel use must still match serial output line for line.
    @Test func parallelHighlightersSharingRegexesMatchSerial() throws {
        let files = RenderStressParityTests.fixture.fileCases.map(\.file)
        let options = RenderFileOptions()
        // Embedded languages highlight only when loaded, so every highlighter
        // starts with the same languages.
        let langs = Array(Set(files.compactMap { $0.lang ?? getFiletypeFromFileName($0.name) }))
        func makeHighlighter() -> DiffsHighlighter {
            let highlighter = DiffsHighlighter()
            try? highlighter.prepare(langs: langs, themes: [DiffsConstants.defaultThemes.dark, DiffsConstants.defaultThemes.light])
            return highlighter
        }
        let serial = try files.map { try makeHighlighter().renderFile($0, options: options).lines }
        final class Results: @unchecked Sendable {
            var lines: [[[HighlightedLine?]]] = Array(repeating: [], count: 8)
            var errors: [[String]] = Array(repeating: [], count: 8)
        }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            let highlighter = makeHighlighter()
            // Each worker walks every file, starting at a different one.
            var output = [[HighlightedLine?]](repeating: [], count: files.count)
            for step in 0 ..< files.count {
                let index = (step + worker * 5) % files.count
                do {
                    output[index] = try highlighter.renderFile(files[index], options: options).lines
                } catch {
                    results.errors[worker].append("\(files[index].name): \(error)")
                }
            }
            results.lines[worker] = output
        }
        var mismatches = results.errors.flatMap { $0 }
        for worker in 0 ..< 8 {
            for index in files.indices where results.lines[worker][index] != serial[index] {
                mismatches.append("worker \(worker) differs on \(files[index].name)")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches: \(mismatches.prefix(8))")
    }

    /// Lazily embedded languages (Markdown fences) highlight only when the
    /// language is attached. Upstream has one shared highlighter; every
    /// highlighter here, including the concurrent diff side, must see the
    /// same languages.
    @Test func embeddedLanguagesMatchAcrossHighlighters() throws {
        let body = (0 ..< 250).map { "Line \($0) of prose.\n" }.joined()
        let fence = "```ts\nconst value: number = 42;\n```\n"
        let diff = try parseDiffFromFile(
            oldFile: FileContents(name: "a.md", contents: fence + body),
            newFile: FileContents(name: "a.md", contents: fence + body.replacingOccurrences(of: "Line 5 ", with: "Line five "))
        )
        let main = DiffsHighlighter()
        try main.prepare(langs: ["typescript"], themes: [])
        main.sideHighlighter = DiffsHighlighter()
        let concurrent = try main.renderDiff(diff, options: RenderDiffOptions())
        main.sideHighlighter = nil
        let serial = try main.renderDiff(diff, options: RenderDiffOptions())
        let other = try DiffsHighlighter().renderDiff(diff, options: RenderDiffOptions())
        #expect(concurrent.deletionLines == serial.deletionLines)
        #expect(concurrent.additionLines == serial.additionLines)
        #expect(other.deletionLines == serial.deletionLines)
        // The fence is highlighted as TypeScript on both sides.
        let fenceLine = try #require(concurrent.deletionLines[1])
        #expect(Set(fenceLine.tokens.map { $0.styles.first?.color }).count > 1)
        #expect(concurrent.deletionLines[1] == concurrent.additionLines[1])
    }
}
