import AppKit
import Testing
import SwiffsCore
import SwiffsEditor
@testable import SwiffsUI

/// `EditStateManager` and keyed editor sessions, like upstream's
/// EditStateManager and editor edit-state tests.
@MainActor
struct EditStateTests {
    private func host<V: NSView>(_ view: V) -> (V, NSWindow) {
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    private func fileView(_ contents: String) -> (FileView<Void>, NSWindow) {
        let view = FileView<Void>()
        view.render(file: FileContents(name: "a.ts", contents: contents))
        return host(view)
    }

    private func diffView(old: String, new: String) throws -> (FileDiffView<Void>, NSWindow) {
        let view = FileDiffView<Void>()
        var options = DiffsDiffOptions()
        options.diffStyle = .unified
        view.options = options
        try view.render(oldFile: FileContents(name: "f.txt", contents: old), newFile: FileContents(name: "f.txt", contents: new))
        return host(view)
    }

    private func type(_ text: String, _ view: FileView<Void>) {
        view.grid.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test func managerExcludesActiveKeysAndClearsParts() throws {
        let manager = EditStateManager()
        let ownerA = NSObject(), ownerB = NSObject()
        let session: DiffsEditState<LineAnnotation<Void>> = try manager.activate(.file, "k", owner: ownerA, initialState: nil)
        #expect(throws: EditStateManagerError.keyInUse("k")) {
            let _: DiffsEditState<LineAnnotation<Void>> = try manager.activate(.file, "k", owner: ownerB, initialState: nil)
        }
        // Namespaces are independent.
        let _: DiffsEditState<DiffLineAnnotation<Void>> = try manager.activate(.fileDiff, "k", owner: ownerB, initialState: nil)
        // Incomplete sessions are not retained.
        manager.release(.file, "k", owner: ownerA)
        #expect(manager.get(.file, "k", annotation: LineAnnotation<Void>.self) == nil)

        let document = TextDocument<LineAnnotation<Void>>(uri: "a.ts", text: "a", languageId: "typescript")
        try document.applyEdits([TextEdit(range: DocumentRange(start: Position(line: 0, character: 1), end: Position(line: 0, character: 1)), newText: "b")])
        session.document = document
        session.fileInfo = ("a.ts", nil)
        session.editor = EditorViewState(selections: [EditorSelection(caret: Position(line: 0, character: 2))], view: EditorViewportState(scrollLeft: 4))
        let again: DiffsEditState<LineAnnotation<Void>> = try manager.activate(.file, "k", owner: ownerA, initialState: session)
        #expect(again === session)
        // Active sessions cannot be cleared.
        #expect(!manager.clear(.file, "k"))
        manager.release(.file, "k", owner: ownerA)
        #expect(manager.get(.file, "k", annotation: LineAnnotation<Void>.self) === session)

        #expect(manager.clear(.file, "k", parts: [.selections]))
        #expect(session.editor?.selections == nil)
        #expect(session.editor?.view?.scrollLeft == 4)
        #expect(manager.clear(.file, "k", parts: [.history]))
        #expect(!document.canUndo)
        #expect(manager.clear(.file, "k"))
        #expect(manager.get(.file, "k", annotation: LineAnnotation<Void>.self) == nil)
        #expect(!manager.clear(.file, "missing"))
        #expect(throws: EditStateManagerError.invalidCapacity) { try manager.setCapacity(0) }
    }

    @Test func managerEvictsLeastRecentlyUsed() throws {
        let manager = EditStateManager()
        try manager.setCapacity(2)
        let owner = NSObject()
        for key in ["a", "b", "c"] {
            let session: DiffsEditState<LineAnnotation<Void>> = try manager.activate(.file, key, owner: owner, initialState: nil)
            session.document = TextDocument(uri: key, text: key, languageId: "text")
            session.fileInfo = (key, nil)
            manager.release(.file, key, owner: owner)
        }
        #expect(manager.get(.file, "a", annotation: LineAnnotation<Void>.self) == nil)
        #expect(manager.get(.file, "b", annotation: LineAnnotation<Void>.self) != nil)
        #expect(manager.get(.file, "c", annotation: LineAnnotation<Void>.self) != nil)
    }

    @Test func keyedFileSessionResumesDocumentAndSelections() throws {
        let key = "file-\(UUID().uuidString)"
        let (view, _) = fileView("const a = 1;\n")
        let editor = DiffsEditor<LineAnnotation<Void>>(editStateKey: key)
        _ = editor.edit(view)
        editor.setSelections([EditorSelection(caret: Position(line: 0, character: 12))])
        type(" // x", view)
        view.onEditComplete = { _ in .reject }
        editor.cleanUp(.discard)
        #expect(view.line(side: .additions, lineIndex: 0).text == "const a = 1;")

        let state = EditStateManager.shared.get(.file, key, annotation: LineAnnotation<Void>.self)
        #expect(state?.document?.getText() == "const a = 1; // x\n")

        let (other, _) = fileView("const a = 1;\n")
        let resumed = DiffsEditor<LineAnnotation<Void>>(editStateKey: key)
        _ = resumed.edit(other)
        #expect(resumed.getText() == "const a = 1; // x\n")
        #expect(other.line(side: .additions, lineIndex: 0).text == "const a = 1; // x")
        #expect(resumed.selections.last?.focus == Position(line: 0, character: 17))
        #expect(resumed.canUndo)
        resumed.undo()
        #expect(resumed.getText() == "const a = 1;\n")
        resumed.cleanUp(.discard)
        EditStateManager.shared.clear(.file, key)
    }

    @Test func recycledSessionResumesOnSameEditor() throws {
        let (view, _) = fileView("x\n")
        let editor = DiffsEditor<LineAnnotation<Void>>()
        _ = editor.edit(view)
        editor.setSelections([EditorSelection(caret: Position(line: 0, character: 1))])
        type("y", view)
        editor.cleanUp(.recycle)
        #expect(editor.getText() == "")
        _ = editor.edit(view)
        #expect(editor.getText() == "xy\n")
        #expect(editor.canUndo)
        editor.cleanUp(.discard)
    }

    @Test func initialStateTransfersSession() throws {
        let (view, _) = fileView("one\n")
        let editor = DiffsEditor<LineAnnotation<Void>>()
        _ = editor.edit(view)
        editor.setSelections([EditorSelection(caret: Position(line: 0, character: 3))])
        type("!", view)
        let state = try #require(editor.getEditState())
        #expect(state.editor?.selections?.last?.focus == Position(line: 0, character: 4))
        editor.cleanUp(.discard)

        let (other, _) = fileView("one\n")
        let next = DiffsEditor<LineAnnotation<Void>>(initialState: state)
        _ = next.edit(other)
        #expect(next.getText() == "one!\n")
        #expect(next.selections.last?.focus == Position(line: 0, character: 4))
        next.cleanUp(.discard)
    }

    @Test func viewStateRoundTrips() throws {
        let (view, _) = fileView(String(repeating: "x", count: 400) + "\nshort\n")
        let editor = DiffsEditor<LineAnnotation<Void>>()
        #expect(throws: DiffsEditorError.notAttached) { try editor.setViewState(EditorViewState()) }
        _ = editor.edit(view)
        try editor.setViewState(EditorViewState(selections: [EditorSelection(caret: Position(line: 1, character: 2))], view: EditorViewportState(scrollLeft: 50)))
        let state = editor.getViewState()
        #expect(state.selections?.last?.focus == Position(line: 1, character: 2))
        #expect(state.view?.scrollLeft == 50)
        editor.cleanUp(.discard)
    }

    @Test func keyedDiffSessionRestoresHunks() throws {
        let key = "diff-\(UUID().uuidString)"
        let old = (1 ... 30).map { "line \($0)\n" }.joined()
        let (view, _) = try diffView(old: old, new: old.replacingOccurrences(of: "line 5\n", with: "line five\n"))
        let editor = DiffsEditor<DiffLineAnnotation<Void>>(editStateKey: key)
        _ = editor.edit(view)
        try editor.applyEdits([TextEdit(range: DocumentRange(start: Position(line: 19, character: 0), end: Position(line: 19, character: 7)), newText: "line twenty")])
        let editedHunks = try #require(view.fileDiff?.hunks)
        #expect(editedHunks.count == 2)
        editor.cleanUp(.discard)
        #expect(view.fileDiff?.hunks.count == 1)
        let retained = try #require(EditStateManager.shared.get(.fileDiff, key, annotation: DiffLineAnnotation<Void>.self))
        #expect(retained.diffSession?.hunks == editedHunks)

        let resumed = DiffsEditor<DiffLineAnnotation<Void>>(editStateKey: key)
        _ = resumed.edit(view)
        #expect(resumed.getText().contains("line twenty\n"))
        #expect(view.fileDiff?.hunks == editedHunks)
        resumed.cleanUp(.discard)
        EditStateManager.shared.clear(.fileDiff, key)
    }
}
