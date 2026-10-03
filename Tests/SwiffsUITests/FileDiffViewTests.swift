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

    @Test func expandButtonsAreAccessible() throws {
        let old = (1 ... 60).map { "line \($0)\n" }.joined()
        let view = FileDiffView<Void>()
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        try view.render(oldFile: FileContents(name: "a.txt", contents: old), newFile: FileContents(name: "a.txt", contents: old.replacingOccurrences(of: "line 30\n", with: "x\n")))
        view.layoutSubtreeIfNeeded()
        let buttons = try #require(view.grid.accessibilityChildren() as? [GridAccessibilityButton])
        #expect(!buttons.isEmpty)
        #expect(buttons.allSatisfy { $0.accessibilityRole() == .button })
        let before = view.grid.model.rows.count
        let up = try #require(buttons.first { $0.accessibilityLabel() == "Expand up" || $0.accessibilityLabel() == "Expand all" })
        #expect(up.accessibilityPerformPress())
        #expect(view.grid.model.rows.count > before)
    }

    @Test func newAnnotationsOnTheSameLineReplaceTheirViews() throws {
        final class Note: NSView {
            let height: CGFloat
            init(_ text: String, height: CGFloat) {
                self.height = height
                super.init(frame: .zero)
                identifier = NSUserInterfaceItemIdentifier(text)
            }
            required init?(coder: NSCoder) { nil }
            override var fittingSize: NSSize { NSSize(width: frame.width, height: height) }
        }
        let old = "one\ntwo\nthree\n"
        let view = FileDiffView<String>()
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        view.renderAnnotation = { Note($0.metadata, height: $0.metadata == "short" ? 20 : 60) }
        let file = try parseDiffFromFile(
            oldFile: FileContents(name: "a.txt", contents: old), newFile: FileContents(name: "a.txt", contents: old.replacingOccurrences(of: "two", with: "2")))
        func notes() -> [String] { view.grid.subviews.compactMap { ($0 as? Note)?.identifier?.rawValue } }

        view.render(fileDiff: file, lineAnnotations: [DiffLineAnnotation(side: .additions, lineNumber: 2, metadata: "short")])
        view.layoutSubtreeIfNeeded()
        #expect(notes() == ["short"])
        let before = view.grid.frame.height

        view.render(fileDiff: file, lineAnnotations: [DiffLineAnnotation(side: .additions, lineNumber: 2, metadata: "tall")])
        view.layoutSubtreeIfNeeded()
        #expect(notes() == ["tall"], "An annotation's view is rebuilt when its annotations change, not only when its line does")
        #expect(view.grid.frame.height == before + 40)
    }

    @Test func annotationsSharingALineEachFillTheColumn() throws {
        final class Note: NSView {
            let height: CGFloat
            init(width: CGFloat, height: CGFloat) {
                self.height = height
                super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
            }
            required init?(coder: NSCoder) { nil }
            override var fittingSize: NSSize { NSSize(width: frame.width, height: height) }
        }
        let old = "one\ntwo\nthree\n"
        let view = FileDiffView<Int>()
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        view.renderAnnotation = { Note(width: CGFloat($0.metadata) * 30, height: 20) }
        let file = try parseDiffFromFile(
            oldFile: FileContents(name: "a.txt", contents: old), newFile: FileContents(name: "a.txt", contents: old.replacingOccurrences(of: "two", with: "2")))
        view.render(fileDiff: file, lineAnnotations: [DiffLineAnnotation(side: .additions, lineNumber: 2, metadata: 1), DiffLineAnnotation(side: .additions, lineNumber: 2, metadata: 2)])
        view.layoutSubtreeIfNeeded()
        let single = FileDiffView<Int>()
        single.frame = view.frame
        single.renderAnnotation = { Note(width: CGFloat($0.metadata) * 30, height: 20) }
        single.render(fileDiff: file, lineAnnotations: [DiffLineAnnotation(side: .additions, lineNumber: 2, metadata: 1)])
        single.layoutSubtreeIfNeeded()
        let column = try #require(single.grid.subviews.first { $0 is Note }).frame.width
        func notes(_ v: NSView) -> [NSView] { v.subviews.flatMap { ($0 is Note ? [$0] : []) + notes($0) } }
        let stacked = notes(view.grid)
        #expect(stacked.count == 2)
        #expect(stacked.allSatisfy { $0.frame.width == column }, "each fills the column, as a single annotation does")
        #expect(Set(stacked.map(\.frame.minY)).count == 2, "one above the other")
    }
}
