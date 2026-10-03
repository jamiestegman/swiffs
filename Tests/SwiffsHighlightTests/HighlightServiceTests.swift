import Foundation
import SwiffsCore
import Testing
@testable import SwiffsHighlight

struct HighlightServiceTests {
    private let options = RenderDiffOptions(theme: .pair(DiffsConstants.defaultThemes))

    @Test func concurrentRequestsForOneKeyedDiffShareOneComputation() async throws {
        let service = HighlightService(workerCount: 2)
        var diff = try ConcurrencyInvarianceTests.largeDiff()
        diff.cacheKey = "single-flight"
        async let first = service.highlight(diff, options: options)
        async let second = service.highlight(diff, options: options)
        let (a, b) = try await (first, second)
        #expect(a.additionLines == b.additionLines && a.deletionLines == b.deletionLines)
        #expect(service.cachedResult(for: diff, options: options)?.additionLines == a.additionLines)
    }

    @Test func keyedRequestsRunOnce() async throws {
        let service = HighlightService(workerCount: 2)
        var diff = try ConcurrencyInvarianceTests.largeDiff()
        diff.cacheKey = "once"
        service.prefetch(diff, options: options)
        service.prefetch(diff, options: options)
        #expect(service.pendingCount <= 1)
        _ = try await service.highlight(diff, options: options)
        #expect(service.pendingCount == 0)
    }

    @Test func unkeyedRequestsAreNotCached() async throws {
        let service = HighlightService(workerCount: 1)
        let diff = try ConcurrencyInvarianceTests.largeDiff()
        _ = try await service.highlight(diff, options: options)
        #expect(service.cachedResult(for: diff, options: options) == nil)
    }

    @Test func cancelledUnkeyedRequestsDoNotRun() async throws {
        let service = HighlightService(workerCount: 1)
        let diff = try ConcurrencyInvarianceTests.largeDiff()
        let task = Task { try await service.highlight(diff, options: options) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test @MainActor func smallContentHighlightsImmediately() throws {
        let service = HighlightService(workerCount: 1)
        var file = FileContents(name: "a.swift", contents: "let a = 1")
        file.cacheKey = "small"
        let options = RenderFileOptions()
        let result = try #require(service.immediateResult(for: file, lineCount: 1, options: options, lineLimit: 10))
        #expect(result.lines.count == 1)
        #expect(service.cachedResult(for: file, options: options) != nil)
        #expect(service.immediateResult(for: FileContents(name: "b.swift", contents: "let b = 2"), lineCount: 1, options: options, lineLimit: 0) == nil)
    }

    /// Each visible character's colour, line by line. Whitespace draws
    /// nothing, and a whole-file highlight merges it into the next token.
    private func colours(_ lines: [HighlightedLine]) -> [[String?]] {
        lines.map { line in
            let units = Array(line.text.utf16)
            var colours = [String?](repeating: nil, count: units.count)
            for token in line.tokens {
                for index in token.start ..< min(token.end, colours.count) where units[index] != 0x20 && units[index] != 0x09 {
                    colours[index] = token.styles.first?.color
                }
            }
            return colours
        }
    }

    @Test func streamingAFileMatchesHighlightingItWhole() async throws {
        let contents = "import Foundation\r\n\n/* a comment\nspanning lines */\nlet value = \"text\" // done\r\nfunc f() -> Int { 1 }\n"
        let file = FileContents(name: "a.swift", contents: contents)
        let options = RenderFileOptions()
        let whole = try DiffsHighlighter().renderFile(file, options: options).lines.compactMap { $0 }
        let stream = try HighlightService(workerCount: 1).stream(for: file, options: options)
        var streamed: [HighlightedLine] = []
        var start = contents.startIndex
        while start < contents.endIndex {
            let end = contents.index(start, offsetBy: 5, limitedBy: contents.endIndex) ?? contents.endIndex
            let (first, lines) = try await stream.append(String(contents[start ..< end]))
            streamed.removeSubrange(min(first, streamed.count)...)
            streamed.append(contentsOf: lines)
            start = end
        }
        #expect(streamed.map(\.text) == whole.map(\.text))
        #expect(colours(streamed) == colours(whole))
    }
}
