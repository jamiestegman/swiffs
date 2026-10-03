import AppKit
import Testing
import SwiffsCore
@testable import SwiffsUI

@MainActor
struct CodeViewResizeTests {
    final class Fixed: NSView {
        let size: NSSize
        init(_ size: NSSize) {
            self.size = size
            super.init(frame: NSRect(origin: .zero, size: size))
        }
        required init?(coder: NSCoder) { nil }
        override var fittingSize: NSSize { size }
    }

    @Test func aWidthChangeRelaysOutAndRedrawsEachFile() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.wantsLayer = true
        let code = CodeView<String>(options: CodeViewOptions())
        code.frame = window.contentView!.bounds
        code.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(code)
        code.renderHeaderMetadata = { _ in Fixed(NSSize(width: 40, height: 16)) }
        code.renderDiffAnnotation = { _, _ in Fixed(NSSize(width: 10, height: 30)) }
        let old = "one\ntwo\nthree\n"
        let file = try parseDiffFromFile(oldFile: FileContents(name: "a.txt", contents: old), newFile: FileContents(name: "a.txt", contents: old.replacingOccurrences(of: "two", with: "2")))
        code.setItems([.diff(id: "a.txt", file, annotations: [DiffLineAnnotation(side: .additions, lineNumber: 2, metadata: "note")])])
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let view = try #require(code.renderedView(for: "a.txt") as? FileDiffView<String>)

        func draw() {
            window.displayIfNeeded()
            view.header.layer?.displayIfNeeded()
            view.grid.layer?.displayIfNeeded()
        }
        draw()
        for width in [900.0, 480.0] {
            #expect(view.header.layer?.needsDisplay() == false && view.grid.layer?.needsDisplay() == false, "drawn before the resize")
            window.setContentSize(NSSize(width: width, height: 500))
            window.contentView?.layoutSubtreeIfNeeded()
            let content = try #require(view.superview).bounds.width
            #expect(content > width - 20 && view.frame.width == content)
            let metadata = try #require(view.header.subviews.first { $0 is Fixed })
            #expect(metadata.frame.maxX == content - 16, "the header's trailing slot follows the width")
            let note = try #require(view.grid.subviews.first { $0 is Fixed })
            #expect(note.frame.maxX > content - 40, "the annotation row follows the width")
            #expect(view.header.layer?.needsDisplay() == true, "the header redraws at the new width")
            #expect(view.grid.layer?.needsDisplay() == true, "the rows redraw at the new width")
            draw()
        }
    }

    @Test func anAnnotationThatGrowsIsMeasuredAgainWhenItsOwnerSaysSo() throws {
        final class Growing: NSView {
            var height: CGFloat = 30
            override var fittingSize: NSSize { NSSize(width: frame.width, height: height) }
        }
        let note = Growing()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        let code = CodeView<String>(options: CodeViewOptions())
        code.frame = window.contentView!.bounds
        window.contentView?.addSubview(code)
        code.renderDiffAnnotation = { _, _ in note }
        let old = "one\ntwo\nthree\n"
        let file = try parseDiffFromFile(oldFile: FileContents(name: "a.txt", contents: old), newFile: FileContents(name: "a.txt", contents: old.replacingOccurrences(of: "two", with: "2")))
        code.setItems([.diff(id: "a.txt", file, annotations: [DiffLineAnnotation(side: .additions, lineNumber: 2, metadata: "note")])])
        window.contentView?.layoutSubtreeIfNeeded()
        let view = try #require(code.renderedView(for: "a.txt") as? FileDiffView<String>)
        let before = view.frame.height
        #expect(note.frame.height == 30)

        note.height = 90
        code.noteHeightOfAnnotationsChanged(inItem: "a.txt")
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(note.frame.height == 90, "the annotation gets its new height")
        #expect(view.frame.height == before + 60, "and the file grows to hold it")
    }
}
