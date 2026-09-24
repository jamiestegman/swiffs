import AppKit
import Testing
import SwiffsCore
import SwiffsEditor
@testable import SwiffsUI

/// Drives `DiffsEditor` attached to real views, like upstream's editor
/// component tests.
@MainActor
struct EditorIntegrationTests {
    private func window(for view: NSView, height: CGFloat = 400) -> NSWindow {
        view.frame = CGRect(x: 0, y: 0, width: 800, height: height)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func key(_ grid: CodeGridView, _ window: NSWindow, keyCode: UInt16, chars: String, flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode
        )!
        if !grid.performKeyEquivalent(with: event) { grid.keyDown(with: event) }
    }

    private func makeFileEditor(_ contents: String) -> (FileView<Void>, DiffsEditor<LineAnnotation<Void>>, NSWindow) {
        let view = FileView<Void>()
        view.synchronousHighlightLineLimit = .max
        view.render(file: FileContents(name: "a.ts", contents: contents))
        let window = window(for: view)
        let editor = DiffsEditor<LineAnnotation<Void>>()
        _ = editor.edit(view)
        window.makeFirstResponder(view.grid)
        return (view, editor, window)
    }

    @Test func typingAndUndo() throws {
        let (view, editor, window) = makeFileEditor("const a = 1;\nconst b = 2;\n")
        editor.setSelections([EditorSelection(caret: Position(line: 0, character: 12))])
        view.grid.insertText(" // one", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.grid.insertText(" two", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.getText() == "const a = 1; // one two\nconst b = 2;\n")
        // Consecutive typing coalesces into one undo step.
        key(view.grid, window, keyCode: 6, chars: "z", flags: .command)
        #expect(editor.getText() == "const a = 1;\nconst b = 2;\n")
        key(view.grid, window, keyCode: 6, chars: "z", flags: [.command, .shift])
        #expect(editor.getText() == "const a = 1; // one two\nconst b = 2;\n")
    }

    @Test func enterKeepsIndentationAndBackspaceRemovesSoftTab() throws {
        let (view, editor, _) = makeFileEditor("function f() {\n    return 1;\n}\n")
        editor.setSelections([EditorSelection(caret: Position(line: 1, character: 13))])
        view.grid.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(editor.getText() == "function f() {\n    return 1;\n    \n}\n")
        #expect(editor.selections.last?.focus == Position(line: 2, character: 4))
        view.grid.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(editor.getText() == "function f() {\n    return 1;\n  \n}\n")
    }

    @Test func commandsAndMultipleSelections() throws {
        let (view, editor, window) = makeFileEditor("foo bar\nfoo baz\nfoo qux\n")
        editor.setSelections([EditorSelection(caret: Position(line: 0, character: 1))])
        // Cmd+D selects the word, then adds the next occurrences.
        key(view.grid, window, keyCode: 2, chars: "d", flags: .command)
        key(view.grid, window, keyCode: 2, chars: "d", flags: .command)
        key(view.grid, window, keyCode: 2, chars: "d", flags: .command)
        #expect(editor.selections.count == 3)
        view.grid.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.getText() == "x bar\nx baz\nx qux\n")
        // Toggle comment on every line.
        key(view.grid, window, keyCode: 44, chars: "/", flags: .command)
        #expect(editor.getText() == "// x bar\n// x baz\n// x qux\n")
        // Move the last line up.
        editor.setSelections([EditorSelection(caret: Position(line: 2, character: 0))])
        key(view.grid, window, keyCode: 126, chars: "\u{F700}", flags: .option)
        #expect(editor.getText() == "// x bar\n// x qux\n// x baz\n")
    }

    @Test func autoSurroundAndClipboard() throws {
        let (view, editor, _) = makeFileEditor("value\nother\n")
        editor.setSelections([EditorSelection(start: Position(line: 0, character: 0), end: Position(line: 0, character: 5), direction: .forward)])
        view.grid.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.getText() == "(value)\nother\n")
        // The inner text stays selected.
        #expect(editor.selections.last == EditorSelection(start: Position(line: 0, character: 1), end: Position(line: 0, character: 6), direction: .forward))
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        view.grid.copy(nil)
        #expect(pasteboard.string(forType: .string) == "value")
        editor.setSelections([EditorSelection(caret: Position(line: 1, character: 5))])
        view.grid.paste(nil)
        #expect(editor.getText() == "(value)\nothervalue\n")
    }

    @Test func diffEditingConvergesToAFreshParse() throws {
        let old = (1 ... 40).map { "line \($0)\n" }.joined()
        let new = old.replacingOccurrences(of: "line 10\n", with: "line ten\n").replacingOccurrences(of: "line 30\n", with: "")
        let view = FileDiffView<Void>()
        view.synchronousHighlightLineLimit = .max
        var options = DiffsDiffOptions()
        options.diffStyle = .unified
        view.options = options
        try view.render(oldFile: FileContents(name: "f.txt", contents: old), newFile: FileContents(name: "f.txt", contents: new))
        let window = window(for: view, height: 1200)
        let editor = DiffsEditor<DiffLineAnnotation<Void>>()
        var completed: FileDiffEditCompleteEvent<Void>?
        view.onEditComplete = { event in
            completed = event
            return .accept
        }
        let complete = editor.edit(view)
        window.makeFirstResponder(view.grid)
        try editor.applyEdits([TextEdit(range: DocumentRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 0)), newText: "header\n")])
        try editor.applyEdits([TextEdit(range: DocumentRange(start: Position(line: 20, character: 0), end: Position(line: 21, character: 0)), newText: "")])
        // Live session hunks must describe the current text.
        let live = try #require(view.fileDiff)
        #expect(live.additionLines.joined() == editor.getText())
        complete()
        let event = try #require(completed)
        let newContents = try #require(event.newFile).contents
        let expected = try parseDiffFromFile(oldFile: FileContents(name: "f.txt", contents: old), newFile: FileContents(name: "f.txt", contents: newContents))
        #expect(event.fileDiff.hunks == expected.hunks)
        #expect(view.fileDiff?.additionLines == expected.additionLines)
    }

    @Test func compositionShowsInlineAndCommits() throws {
        let (view, editor, _) = makeFileEditor("ab\n")
        editor.setSelections([EditorSelection(caret: Position(line: 0, character: 1))])
        view.grid.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.grid.hasMarkedText())
        // Display only: the document is unchanged while composing.
        #expect(editor.getText() == "ab\n")
        #expect(view.line(side: .additions, lineIndex: 0).text == "aにほb")
        view.grid.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.grid.hasMarkedText())
        #expect(editor.getText() == "a日本b\n")
        #expect(view.line(side: .additions, lineIndex: 0).text == "a日本b")
    }

    @Test func themeChangesRetokenizeEditedLines() async throws {
        let (view, editor, _) = makeFileEditor("const a = 1;\n")
        editor.setSelections([EditorSelection(caret: Position(line: 0, character: 12))])
        view.grid.insertText(" const b = 2;", replacementRange: NSRange(location: NSNotFound, length: 0))
        func keywordColor() -> String? {
            let line = view.line(side: .additions, lineIndex: 0)
            return line.tokens.first?.styles.first?.color
        }
        let before = keywordColor()
        var options = view.options
        options.theme = .single("github-dark")
        view.options = options
        let deadline = Date().addingTimeInterval(2)
        while keywordColor() == before, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(before != nil)
        #expect(keywordColor() != before)
    }

    @Test func softLineDeleteStopsAtWrapPoint() throws {
        let long = String(repeating: "word ", count: 60)
        let view = FileView<Void>()
        var options = view.options
        options.overflow = .wrap
        view.options = options
        view.render(file: FileContents(name: "a.txt", contents: long + "\n"))
        let window = window(for: view)
        let editor = DiffsEditor<LineAnnotation<Void>>()
        _ = editor.edit(view)
        window.makeFirstResponder(view.grid)
        view.layoutSubtreeIfNeeded()
        let end = long.utf16.count
        editor.setSelections([EditorSelection(caret: Position(line: 0, character: end))])
        view.grid.doCommand(by: #selector(NSResponder.deleteToBeginningOfLine(_:)))
        let remaining = editor.getText().utf16.count - 1
        // Only the last visual segment is removed.
        #expect(remaining > 0)
        #expect(remaining < end)
        #expect(long.hasPrefix(String(editor.getText().dropLast())))
    }

    @Test func accessibilityExposesLabeledTextArea() throws {
        let (view, editor, _) = makeFileEditor("const a = 1;\nconst b = 2;\n")
        let grid = view.grid
        #expect(grid.accessibilityRole() == .textArea)
        #expect(grid.accessibilityLabel() == "a.ts")
        #expect(grid.accessibilityValue() as? String == "const a = 1;\nconst b = 2;\n")
        editor.setSelections([EditorSelection(start: Position(line: 1, character: 0), end: Position(line: 1, character: 5), direction: .forward)])
        #expect(grid.accessibilitySelectedTextRange() == NSRange(location: 13, length: 5))
        #expect(grid.accessibilitySelectedText() == "const")
        #expect(grid.accessibilityInsertionPointLineNumber() == 1)
        #expect(grid.accessibilityRange(forLine: 1) == NSRange(location: 13, length: 13))
        grid.setAccessibilitySelectedTextRange(NSRange(location: 6, length: 1))
        #expect(editor.selections.last?.focus == Position(line: 0, character: 7))
        grid.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(grid.accessibilityValue() as? String == "const x = 1;\nconst b = 2;\n")
    }
}
