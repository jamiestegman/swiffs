import AppKit
import Testing
import SwiffsCore
import SwiffsHighlight
@testable import SwiffsUI

@MainActor
struct HighlightReuseTests {
    static func keyedDiff(_ key: String) throws -> FileDiffMetadata {
        let old = (1...40).map { "let value\($0) = compute(\($0)) // line \($0)\n" }.joined()
        var diff = try parseDiffFromFile(oldFile: FileContents(name: "a.swift", contents: old), newFile: FileContents(name: "a.swift", contents: old.replacingOccurrences(of: "line 5\n", with: "line five\n")))
        diff.cacheKey = key
        return diff
    }

    @Test func aFileViewShowsAResultTheWorkersAlreadyHave() async throws {
        let diff = try Self.keyedDiff("reuse-\(UUID())")
        _ = try await HighlightWorkerPool.shared.highlightDiff(diff, options: DiffsDiffOptions().renderDiffOptions)
        let view = FileDiffView<Void>()
        view.synchronousHighlightLineLimit = 0
        view.render(fileDiff: diff)
        #expect(view.line(side: .additions, lineIndex: 0).tokens.count > 1, "highlighted at once, with no main-thread highlighting and no plain first frame")
    }

    @Test func aResultHighlightedOnTheMainThreadIsKeptForTheNextMount() throws {
        let diff = try Self.keyedDiff("main-\(UUID())")
        let first = FileDiffView<Void>()
        first.render(fileDiff: diff)
        #expect(HighlightWorkerPool.shared.cachedDiffResult(diff, options: DiffsDiffOptions().renderDiffOptions) != nil, "so remounting the file costs nothing")
    }
}
