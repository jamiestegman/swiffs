import AppKit
import Testing
import SwiffsCore
@testable import SwiffsUI

@MainActor
struct RenderErrorTests {
    private func brokenDiff() throws -> FileDiffMetadata {
        var diff = try parseDiffFromFile(oldFile: FileContents(name: "a.txt", contents: "a\nb\nc\n"), newFile: FileContents(name: "a.txt", contents: "a\nB\nc\n"))
        // Trailing context must pair up across sides.
        diff.additionLines.append("extra\n")
        return diff
    }

    @Test func showsRenderErrorsUnlessDisabled() throws {
        let view = FileDiffView<Void>()
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        var reported: [String] = []
        view.onRenderError = { reported.append(String(describing: $0)) }
        view.render(fileDiff: try brokenDiff())
        view.layoutSubtreeIfNeeded()
        #expect(reported.count == 1)
        #expect(reported.first?.contains("trailing context mismatch") == true)
        let errorView = try #require(view.subviews.first { $0 is RenderErrorView })
        #expect(view.grid.isHidden)
        #expect(errorView.frame.height > 0)

        try view.render(oldFile: FileContents(name: "a.txt", contents: "a\n"), newFile: FileContents(name: "a.txt", contents: "b\n"))
        view.layoutSubtreeIfNeeded()
        #expect(!view.subviews.contains { $0 is RenderErrorView })
        #expect(!view.grid.isHidden)

        var options = view.options
        options.code.disableErrorHandling = true
        view.options = options
        try view.render(oldFile: FileContents(name: "a.txt", contents: "a\n"), newFile: FileContents(name: "a.txt", contents: "c\n"))
        view.render(fileDiff: try brokenDiff())
        #expect(reported.count == 2)
        #expect(!view.subviews.contains { $0 is RenderErrorView })
    }
}
