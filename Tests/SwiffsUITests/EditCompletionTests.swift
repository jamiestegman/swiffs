import AppKit
import Testing
import SwiffsCore
import SwiffsEditor
@testable import SwiffsUI

/// Session endings: `complete` offers the result, `discard` reports it
/// without installing, `recycle` reports nothing.
@MainActor
struct EditCompletionTests {
    @Test func discardEmitsCompletionWithoutInstalling() throws {
        let view = FileView<Void>()
        view.render(file: FileContents(name: "a.ts", contents: "a\n"))
        var events: [String] = []
        view.onEditComplete = { event in
            events.append(event.file.contents)
            return .accept
        }
        let editor = DiffsEditor<LineAnnotation<Void>>()
        var observed = 0
        editor.onComplete = { _ in observed += 1 }
        _ = editor.edit(view)
        try editor.applyEdits([TextEdit(range: DocumentRange(start: Position(line: 0, character: 1), end: Position(line: 0, character: 1)), newText: "b")])
        editor.cleanUp(.discard)
        #expect(events == ["ab\n"])
        #expect(observed == 1)
        #expect(view.line(side: .additions, lineIndex: 0).text == "a")

        _ = editor.edit(view)
        try editor.applyEdits([TextEdit(range: DocumentRange(start: Position(line: 0, character: 1), end: Position(line: 0, character: 1)), newText: "c")])
        editor.cleanUp(.recycle)
        #expect(events.count == 1)
        _ = editor.edit(view)
        editor.complete()
        #expect(events == ["ab\n", "ac\n"])
        #expect(view.line(side: .additions, lineIndex: 0).text == "ac")
    }

    @Test func codeViewResetDiscardsSessionsAndSubscribesToScroll() throws {
        let files = (0 ..< 30).map { FileContents(name: "f\($0).ts", contents: (1 ... 20).map { "line \($0)\n" }.joined()) }
        let codeView = CodeView<Void>(options: CodeViewOptions())
        codeView.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: codeView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = codeView
        var completed: [String] = []
        codeView.onItemEditComplete = { _, context in
            completed.append(context.id)
            return .accept
        }
        codeView.setItems(files.enumerated().map { .file(id: "\($0.offset)", $0.element, edit: $0.offset == 0) })
        codeView.layoutSubtreeIfNeeded()
        #expect(codeView.getEditor("0") != nil)

        var scrolls: [CGFloat] = []
        let unsubscribe = codeView.subscribeToScroll { top, _ in scrolls.append(top) }
        codeView.scrollTo(.position(100))
        let first = codeView.scrollTop
        #expect(first > 0)
        #expect(scrolls.last == first)
        unsubscribe()
        codeView.scrollTo(.position(200))
        #expect(codeView.scrollTop > first)
        #expect(scrolls.last == first)

        codeView.reset()
        #expect(completed == ["0"])
        #expect(codeView.items.isEmpty)
        #expect(codeView.getEditor("0") == nil)
        #expect(codeView.scrollTop == 0)
    }
}
