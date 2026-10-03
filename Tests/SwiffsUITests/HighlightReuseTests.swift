import AppKit
import Testing
import SwiffsCore
import SwiffsHighlight
@testable import SwiffsUI

@MainActor
struct HighlightReuseTests {
    static func keyedDiff(_ key: String, lines: Int = 40) throws -> FileDiffMetadata {
        let old = (1...lines).map { "let value\($0) = compute(\($0)) // line \($0)\n" }.joined()
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

    @Test func filesNearTheViewportHighlightBeforeTheyMount() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let code = CodeView<Void>(options: CodeViewOptions())
        code.frame = window.contentView!.bounds
        window.contentView?.addSubview(code)
        let run = UUID().uuidString
        let diffs = try (0..<30).map { try Self.keyedDiff("prefetch-\(run)-\($0)", lines: 10) }
        code.setItems(diffs.enumerated().map { .diff(id: "\($0.offset)", $0.element) })
        window.contentView?.layoutSubtreeIfNeeded()

        let mounted = Set(code.renderedItemIDs)
        let next = try #require((0..<30).first { !mounted.contains("\($0)") })
        let options = DiffsDiffOptions().renderDiffOptions
        let deadline = Date().addingTimeInterval(10)
        while HighlightWorkerPool.shared.cachedDiffResult(diffs[next], options: options) == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(HighlightWorkerPool.shared.cachedDiffResult(diffs[next], options: options) != nil, "the next file is highlighted before it mounts")
        #expect(!code.renderedItemIDs.contains("\(next)"))
        #expect(HighlightWorkerPool.shared.cachedDiffResult(diffs[29], options: options) == nil, "files far from the viewport are left alone")
    }
}
