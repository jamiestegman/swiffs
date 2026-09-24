import AppKit
import Testing
import SwiffsCore
import SwiffsEditor
@testable import SwiffsUI

/// Editor options and callbacks that need an attached view.
@MainActor
struct EditorOptionsTests {
    private func makeEditor(_ contents: String, height: CGFloat = 400, options: DiffsEditorOptions = DiffsEditorOptions()) -> (FileView<Void>, DiffsEditor<LineAnnotation<Void>>, NSWindow) {
        let view = FileView<Void>()
        view.render(file: FileContents(name: "a.ts", contents: contents))
        view.frame = CGRect(x: 0, y: 0, width: 600, height: height)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let editor = DiffsEditor<LineAnnotation<Void>>(options: options)
        _ = editor.edit(view)
        return (view, editor, window)
    }

    private func settle(until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func customClipboardSuppliesPasteText() async throws {
        var options = DiffsEditorOptions()
        options.clipboard = DiffsEditorClipboard { type in
            type == nil ? "one\r\ntwo" : #"["A","B"]"#
        }
        let (view, editor, _) = makeEditor("x\ny\n", options: options)
        editor.setSelections([EditorSelection(caret: Position(line: 0, character: 1))])
        view.grid.paste(nil)
        try await settle { editor.getText() != "x\ny\n" }
        // Line breaks are normalized to the document's EOL.
        #expect(editor.getText() == "xone\ntwo\ny\n")

        editor.setSelections([EditorSelection(caret: Position(line: 0, character: 0)), EditorSelection(caret: Position(line: 2, character: 0))])
        view.grid.paste(nil)
        try await settle { editor.getText().hasPrefix("A") }
        #expect(editor.getText() == "Axone\ntwo\nBy\n")
    }

    @Test func selectionActionRequiresOptIn() throws {
        let (view, editor, window) = makeEditor("hello world\n")
        var rendered = 0
        editor.renderSelectionAction = { _ in
            rendered += 1
            return NSView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        func selectWord() {
            editor.setSelections([EditorSelection(caret: Position(line: 0, character: 0))])
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124
            )!
            view.grid.keyDown(with: event)
        }
        selectWord()
        #expect(rendered == 0)
        editor.options.enabledSelectionAction = true
        selectWord()
        #expect(rendered == 1)
    }

    @Test func onAttachRunsAfterAttaching() async throws {
        let view = FileView<Void>()
        view.render(file: FileContents(name: "a.ts", contents: "x\n"))
        let editor = DiffsEditor<LineAnnotation<Void>>()
        var attachedTo: NSView?
        editor.onAttach = { _, view in attachedTo = view }
        _ = editor.edit(view)
        #expect(attachedTo == nil)
        try await settle { attachedTo != nil }
        #expect(attachedTo === view)
    }

    @Test func focusPlacesCaretByLineNumberAndFirstVisibleLine() throws {
        let contents = (1 ... 60).map { "line \($0)\n" }.joined()
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 200))
        let view = FileView<Void>()
        view.render(file: FileContents(name: "a.ts", contents: contents))
        view.frame = CGRect(x: 0, y: 0, width: 600, height: view.preferredHeight(forWidth: 600))
        let flipped = FlippedClipView()
        scroll.contentView = flipped
        scroll.documentView = view
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        view.layoutSubtreeIfNeeded()
        let editor = DiffsEditor<LineAnnotation<Void>>()
        _ = editor.edit(view)

        editor.focus(DiffsEditorFocusOptions(lineNumber: .number(3), character: 2))
        #expect(editor.selections.last?.focus == Position(line: 2, character: 2))

        let rowTop = view.grid.editorCaretRect(Position(line: 20, character: 0))!.minY
        scroll.contentView.scroll(to: CGPoint(x: 0, y: view.grid.convert(CGPoint(x: 0, y: rowTop), to: view).y - 1))
        editor.focus(DiffsEditorFocusOptions(lineNumber: .firstVisible, preventScroll: true))
        #expect(editor.selections.last?.focus == Position(line: 20, character: 0))
        // `offset` skips rows whose top is within that distance.
        editor.focus(DiffsEditorFocusOptions(lineNumber: .firstVisible, offset: 5, preventScroll: true))
        #expect(editor.selections.last?.focus == Position(line: 21, character: 0))
    }

    @Test func remoteCaretsRenderOnlyWithRenderCaret() throws {
        let (view, editor, _) = makeEditor("const value = 1;\n")
        editor.setCarets([DiffsEditorCaret(anchor: Position(line: 0, character: 6), focus: Position(line: 0, character: 11), color: .systemPink, metadata: "Ada")])
        #expect(!editor.editorOverlays.contains { if case .remoteSelection = $0.kind { true } else { false } })
        var names: [AnyHashable?] = []
        editor.renderCaret = { caret in
            names.append(caret.metadata)
            return NSView(frame: CGRect(x: 0, y: 0, width: 2, height: 20))
        }
        #expect(names == ["Ada"])
        #expect(editor.editorOverlays.contains { if case .remoteSelection = $0.kind { true } else { false } })
        let caretView = try #require(view.grid.subviews.last)
        let expected = try #require(view.grid.editorCaretRect(Position(line: 0, character: 11)))
        #expect(caretView.frame.origin == expected.origin)
        // Carets follow edits.
        try editor.applyEdits([TextEdit(range: DocumentRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 0)), newText: "  ")])
        let moved = try #require(view.grid.editorCaretRect(Position(line: 0, character: 13)))
        #expect(caretView.frame.origin == moved.origin)
    }
}

private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
