import AppKit
import Testing
import SwiffsCore
@testable import SwiffsUI

@MainActor
struct FileDiffViewTests {
    @Test func revealLineExpandsFromTheNearestGapEdge() throws {
        let old = (1 ... 200).map { "line \($0)\n" }.joined()
        let new = old.replacingOccurrences(of: "line 10\n", with: "line ten\n").replacingOccurrences(of: "line 190\n", with: "line one-ninety\n")
        let view = FileDiffView<Void>()
        var options = DiffsDiffOptions()
        options.expansionLineCount = 10
        view.options = options
        try view.render(oldFile: FileContents(name: "a.txt", contents: old), newFile: FileContents(name: "a.txt", contents: new))
        // Hunks cover lines 6-14 and 186-194; 15-185 are collapsed.
        #expect(view.fileDiff.map { $0.hunks.map(getHunkAdditionLineRange).map(\.start) } == [6, 186])
        #expect(view.isLineRenderable(14))
        #expect(!view.isLineRenderable(15))
        #expect(view.getNearestRenderableLine(100, direction: .down) == 186)
        #expect(view.getNearestRenderableLine(100, direction: .up) == 14)

        // Equidistant: expand down from the gap start by distance + step.
        #expect(view.revealLine(100))
        #expect(view.expandedRegion(for: 1).fromStart == 96)
        #expect(view.isLineRenderable(110))
        #expect(!view.isLineRenderable(111))

        // Closer to the hunk: expand up from the gap end.
        #expect(view.revealLine(150))
        #expect(view.expandedRegion(for: 1).fromEnd == 46)
        #expect(view.isLineRenderable(140))
        #expect(!view.isLineRenderable(139))

        // Already visible lines and lines inside hunks do nothing.
        #expect(!view.revealLine(150))
        #expect(!view.revealLine(10))

        // Trailing context.
        #expect(!view.isLineRenderable(198))
        #expect(view.revealLine(198))
        #expect(view.isLineRenderable(198))
    }
}
