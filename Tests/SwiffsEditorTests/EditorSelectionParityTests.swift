import Foundation
import SwiffsCore
import Testing
@testable import SwiffsEditor

/// Parity with upstream `editor/selection.ts` (see
/// `generate-editor-selection-fixtures.ts`).
struct EditorSelectionParityTests {
    private static func json<T: Encodable>(_ value: T) -> Any {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }

    /// Deep JSON comparison; numbers compare numerically.
    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil), (is NSNull, nil), (nil, is NSNull), (is NSNull, is NSNull):
            return true
        case let (a as [String: Any], b as [String: Any]):
            return Set(a.keys) == Set(b.keys) && a.keys.allSatisfy { same(a[$0], b[$0]) }
        case let (a as [Any], b as [Any]):
            return a.count == b.count && zip(a, b).allSatisfy { same($0, $1) }
        case let (a as NSNumber, b as NSNumber):
            return a == b
        case let (a as String, b as String):
            return a == b
        default:
            return false
        }
    }

    private static func position(_ value: Any?) -> Position {
        let object = value as! [String: Any]
        return Position(line: object["line"] as! Int, character: object["character"] as! Int)
    }

    private static func selection(_ value: Any?) -> EditorSelection {
        let object = value as! [String: Any]
        return EditorSelection(start: position(object["start"]), end: position(object["end"]), direction: SelectionDirection(rawValue: object["direction"] as! Int)!)
    }

    private static func softLineOffsets(_ document: TextDocument<LineAnnotation<String>>) -> (Int) -> [Int]? {
        { line in
            let length = document.getLineLength(line)
            if length <= 8 { return nil }
            var offsets = Array(stride(from: 0, to: length, by: 8))
            offsets.append(length)
            return offsets
        }
    }

    @Test func selectionOperationsMatchUpstream() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/editor-selection.json")
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        #expect(cases.count > 100)
        for testCase in cases {
            let seed = testCase["seed"] as! Int
            let op = testCase["op"] as! String
            let label = "seed \(seed) \(op)"
            let expectedError = testCase["error"] as? String
            if let expectedError, !expectedError.hasPrefix("Overlapping") {
                // Upstream throws on stale out-of-range lines; Swift clamps.
                continue
            }
            let document = TextDocument<LineAnnotation<String>>(uri: "file.ts", text: testCase["text"] as! String)
            let selections = (testCase["selections"] as! [Any]).map(Self.selection)
            let annotations = (testCase["annotations"] as! [[String: Any]]).map {
                LineAnnotation(lineNumber: $0["lineNumber"] as! Int, metadata: $0["metadata"] as! String)
            }
            let options = (testCase["wrap"] as! Bool) ? CursorMoveOptions(getSoftLineOffsets: Self.softLineOffsets(document)) : CursorMoveOptions()
            let expected = testCase["result"]

            func checkEdit(_ result: () throws -> AnnotatedSelectionEditResult<LineAnnotation<String>>) {
                do {
                    let result = try result()
                    if let expectedError {
                        Issue.record("\(label): expected error \(expectedError)")
                        return
                    }
                    let actual: [String: Any] = [
                        "nextSelections": Self.json(result.nextSelections),
                        "text": document.getText(),
                        "startLine": result.change.map { $0.startLine as Any } ?? NSNull(),
                        "lineDelta": result.change.map { $0.lineDelta as Any } ?? NSNull(),
                        "undoSelectionsAfter": document.history.undoStack.last?.selectionsAfter.map { Self.json($0) } ?? NSNull(),
                        "lineAnnotationsAfter": document.history.undoStack.last?.lineAnnotationsAfter.map { $0.map(\.lineNumber) as Any } ?? NSNull(),
                    ]
                    if !Self.same(actual, expected) {
                        Issue.record("\(label): \(actual) != \(String(describing: expected))")
                    }
                } catch {
                    if expectedError == nil { Issue.record("\(label): unexpected error \(error)") }
                }
            }
            func check(_ actual: Any) {
                if !Self.same(actual, expected) {
                    Issue.record("\(label): \(actual) != \(String(describing: expected))")
                }
            }

            switch op {
            case "move", "shift":
                let move = CursorMove(rawValue: testCase["move"] as! String)!
                let result = op == "move"
                    ? mapCursorMove(document, selections, move, options: options)
                    : mapSelectionShift(document, selections, move, options: options)
                check(Self.json(result))
            case "typeChar", "typeNewline":
                let primary = selections.last!
                let edit = ResolvedTextEdit(start: document.offsetAt(primary.start), end: document.offsetAt(primary.end), text: testCase["typed"] as! String)
                checkEdit { try applyTextChangeToSelections(document, selections, edit, lineAnnotations: annotations, tabSize: 2) }
            case "replace":
                checkEdit { try applyTextReplaceToSelections(document, selections, testCase["texts"] as! [String], lineAnnotations: annotations) }
            case "autoSurround":
                let result = getAutoSurroundReplacementTexts(document, selections, testCase["char"] as! String, autoSurround: .default)
                check(result.map { $0 as Any } ?? NSNull())
            case "transpose":
                checkEdit { try applyTransposeToSelections(document, selections, lineAnnotations: annotations) }
            case "deleteHardLineForward":
                checkEdit { try applyDeleteHardLineForwardToSelections(document, selections, lineAnnotations: annotations) }
            case "deleteSoftLineBackward":
                checkEdit { try applyDeleteSoftLineBackwardToSelections(document, selections, getSoftLineStart: { _, character in character / 8 * 8 }, lineAnnotations: annotations) }
            case "deleteWordBackward":
                checkEdit { try applyDeleteWordBackwardToSelections(document, selections, lineAnnotations: annotations) }
            case "deleteBackward", "deleteForward":
                checkEdit { try applyDeleteCharacterToSelections(document, selections, forward: op == "deleteForward", lineAnnotations: annotations, tabSize: 4) }
            case "indent", "outdent":
                let result = resolveIndentEdits(document, selections[0], tabSize: 4, outdent: op == "outdent")
                check(["edits": Self.json(result.edits), "next": Self.json(result.nextSelection)])
            case "merge":
                check(Self.json(mergeOverlappingSelections(selections)))
            case "extend":
                check(Self.json(extendSelections(selections, Self.selection(testCase["target"]))))
            case "lineBlocks":
                check(getSelectedLineBlocks(selections).map { ["startLine": $0.startLine, "endLine": $0.endLine] })
            case "findNextMatch":
                check(findNextMatch(document, selections).map { Self.json($0) } ?? NSNull())
            case "selectionText":
                check(getSelectionText(document, selections))
            case "clipboardTexts":
                check(getSelectionClipboardTexts(document, selections))
            case "cut":
                let cut = resolveSelectionCut(document, selections)
                check(["text": cut.text, "edits": Self.json(cut.edits), "nextSelectionOffsets": cut.nextSelectionOffsets])
            case "expandWord":
                var collapsed = selections[0]
                collapsed.end = collapsed.start
                collapsed.direction = .none
                check(Self.json(expandCollapsedSelectionToWord(document, collapsed)))
            case "remap":
                let edits = (testCase["edits"] as! [[String: Any]]).map { ResolvedTextEdit(start: $0["start"] as! Int, end: $0["end"] as! Int, text: $0["text"] as! String) }
                let offsets = selections.map { (document.offsetAt($0.start), document.offsetAt($0.end)) }
                try document.applyResolvedEdits(edits, updateHistory: false)
                check(Self.json(remapSelectionsAfterEdits(document, selections, offsets, edits)))
            case "boundary":
                check(Self.json([getDocumentBoundarySelection(document, atEnd: false), getDocumentBoundarySelection(document, atEnd: true, trimmedEndNewLine: true), getDocumentFullSelection(document)]))
            case "snap":
                let line = document.getLineUnits(selections[0].start.line)
                check((0 ..< line.count + 2).map { snapCharacterToGraphemeBoundary(line, $0) })
            case "undo":
                let primary = selections.last!
                try applyTextChangeToSelections(document, selections, ResolvedTextEdit(start: document.offsetAt(primary.start), end: document.offsetAt(primary.end), text: "q"))
                try applyDeleteCharacterToSelections(document, mapCursorMove(document, selections, .end), forward: false)
                let undone = document.undo()
                check(["text": document.getText(), "selections": undone?.selections.map { Self.json($0) } ?? NSNull()])
            default:
                Issue.record("unknown op \(op)")
            }
        }
    }
}
