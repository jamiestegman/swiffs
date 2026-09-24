import Foundation
import Testing
@testable import SwiffsEditor

/// Parity with upstream `PieceTable`, `TextDocument` and `EditStack` (see
/// `generate-editor-model-fixtures.ts`).
struct EditorModelParityTests {
    nonisolated(unsafe) static let fixture: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/editor-model.json")
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    private static func units(_ value: Any?) -> [UInt16] {
        (value as? [Int] ?? []).map { UInt16($0) }
    }

    @Test func pieceTableMatchesUpstream() throws {
        let cases = Self.fixture["pieceTableCases"] as! [[String: Any]]
        for testCase in cases {
            let seed = testCase["seed"] as! Int
            let table = PieceTable(testCase["initial"] as! String)
            for (step, op) in (testCase["ops"] as! [[String: Any]]).enumerated() {
                switch op["type"] as! String {
                case "insert":
                    table.insert(op["text"] as! String, at: op["offset"] as! Int)
                case "delete":
                    table.delete(op["offset"] as! Int, length: op["length"] as! Int)
                default:
                    let edits = (op["edits"] as! [[String: Any]]).map {
                        ResolvedTextEdit(start: $0["start"] as! Int, end: $0["end"] as! Int, text: $0["text"] as! String)
                    }
                    table.applyEdits(edits)
                }
                let after = op["after"] as! [String: Any]
                let label = "seed \(seed) step \(step) \(op["type"]!)"
                guard table.textUnits() == Self.units(after["text"]) else {
                    Issue.record("\(label): text differs")
                    break
                }
                #expect(table.lineCount == after["lineCount"] as! Int, "\(label) lineCount")
                let lines = after["lines"] as! [[Int]]
                let lengths = after["lineLengths"] as! [Int]
                let lengthsWithBreak = after["lineLengthsWithBreak"] as! [Int]
                for line in 0 ..< min(lines.count, table.lineCount) {
                    #expect(try table.getLineUnits(line, includeLineBreak: true) == lines[line].map { UInt16($0) }, "\(label) line \(line)")
                    #expect(try table.getLineLength(line) == lengths[line], "\(label) length \(line)")
                    #expect(try table.getLineLength(line, includeLineBreak: true) == lengthsWithBreak[line], "\(label) length+break \(line)")
                }
                let positions = after["positions"] as! [[Int]]
                for (offset, expected) in positions.enumerated() {
                    let position = table.positionAt(offset)
                    if position.line != expected[0] || position.character != expected[1] {
                        Issue.record("\(label): positionAt(\(offset)) = \(position), expected \(expected)")
                        break
                    }
                    #expect(try table.offsetAt(position) == offset, "\(label) offsetAt(\(position))")
                }
            }
        }
    }

    @Test func searchMatchesUpstream() {
        let cases = Self.fixture["searchCases"] as! [[String: Any]]
        for testCase in cases {
            let params = testCase["params"] as! [String: Any]
            let table = PieceTable(testCase["text"] as! String)
            let matches = table.search(SearchParams(
                text: params["text"] as! String,
                replaceText: params["replaceText"] as! String,
                caseSensitive: params["caseSensitive"] as! Bool,
                wholeWord: params["wholeWord"] as! Bool,
                regex: params["regex"] as! Bool
            ))
            let expected = (testCase["matches"] as! [[Int]]).map { ($0[0], $0[1]) }
            #expect(matches.map(\.start) == expected.map(\.0) && matches.map(\.end) == expected.map(\.1), "\(params["text"]!)")
        }
    }

    private static func position(_ value: Any?) -> Position {
        let object = value as! [String: Any]
        return Position(line: object["line"] as! Int, character: object["character"] as! Int)
    }

    private static func selection(_ value: [String: Any]) -> EditorSelection {
        EditorSelection(start: position(value["start"]), end: position(value["end"]), direction: SelectionDirection(rawValue: value["direction"] as! Int) ?? .none)
    }

    private static func resolved(_ value: Any?) -> [ResolvedTextEdit] {
        (value as! [[String: Any]]).map { ResolvedTextEdit(start: $0["start"] as! Int, end: $0["end"] as! Int, text: $0["text"] as! String) }
    }

    private static func compareChange(_ change: TextDocumentChange?, _ expected: Any?, _ label: String) {
        guard let expected = expected as? [String: Any] else {
            #expect(change == nil, "\(label) change should be nil")
            return
        }
        guard let change else {
            Issue.record("\(label): missing change")
            return
        }
        #expect(change.startLine == expected["startLine"] as! Int, "\(label) startLine")
        #expect(change.endLine == expected["endLine"] as! Int, "\(label) endLine")
        #expect(change.startCharacter == expected["startCharacter"] as! Int, "\(label) startCharacter")
        #expect(change.endCharacter == expected["endCharacter"] as! Int, "\(label) endCharacter")
        #expect(change.endedAtDocumentEnd == expected["endedAtDocumentEnd"] as! Bool, "\(label) endedAtDocumentEnd")
        #expect(change.lineCount == expected["lineCount"] as! Int, "\(label) lineCount")
        #expect(change.lineDelta == expected["lineDelta"] as! Int, "\(label) lineDelta")
        let ranges = (expected["changedLineRanges"] as! [[Int]]).map { $0[0] ... $0[1] }
        #expect(change.changedLineRanges == ranges, "\(label) ranges")
        let changes = expected["changes"] as! [[String: Any]]
        #expect(change.changes.count == changes.count, "\(label) change count")
        for (actual, object) in zip(change.changes, changes) {
            let range = object["range"] as! [String: Any]
            #expect(actual.start == object["start"] as! Int && actual.end == object["end"] as! Int && actual.text == object["text"] as! String, "\(label) change")
            #expect(actual.range == TextRange(start: position(range["start"]), end: position(range["end"])), "\(label) change range")
        }
    }

    @Test func textDocumentMatchesUpstream() throws {
        let cases = Self.fixture["documentCases"] as! [[String: Any]]
        for testCase in cases {
            let seed = testCase["seed"] as! Int
            let doc = TextDocument<Never>(uri: "file.ts", text: testCase["initial"] as! String, languageId: "typescript")
            #expect(doc.uri == testCase["uri"] as! String)
            for (step, op) in (testCase["ops"] as! [[String: Any]]).enumerated() {
                let label = "seed \(seed) step \(step) \(op["type"]!)"
                switch op["type"] as! String {
                case "applyEdits":
                    let edits = (op["edits"] as! [[String: Any]]).map { edit -> TextEdit in
                        let range = edit["range"] as! [String: Any]
                        return TextEdit(range: TextRange(start: Self.position(range["start"]), end: Self.position(range["end"])), newText: edit["newText"] as! String)
                    }
                    let selections = (op["selectionsBefore"] as? [[String: Any]])?.map(Self.selection)
                    do {
                        let change = try doc.applyEdits(edits, selectionsBefore: selections, undoBoundary: op["undoBoundary"] as? Bool ?? false)
                        #expect(op["error"] == nil, "\(label) expected error")
                        Self.compareChange(change, op["change"], label)
                    } catch {
                        #expect(op["error"] != nil, "\(label) unexpected error \(error)")
                    }
                case "normalizeEol":
                    #expect(doc.normalizeEol(op["text"] as! String) == op["result"] as! String, "\(label)")
                case "undo", "redo":
                    let result = op["type"] as! String == "undo" ? doc.undo() : doc.redo()
                    if let expected = op["result"] as? [String: Any] {
                        guard let result else {
                            Issue.record("\(label): expected a result")
                            continue
                        }
                        Self.compareChange(result.change, expected["change"], label)
                        let selections = (expected["selections"] as? [[String: Any]])?.map(Self.selection)
                        #expect(result.selections == selections, "\(label) selections")
                        let selectionEdits = (expected["selectionEdits"] as? [[String: Any]]).map { Self.resolved($0) }
                        #expect(result.selectionEdits == selectionEdits, "\(label) selectionEdits")
                    } else {
                        #expect(result == nil, "\(label) expected nil")
                    }
                default:
                    Issue.record("unknown op")
                }
                let after = op["after"] as! [String: Any]
                #expect(doc.getText() == after["text"] as! String, "\(label) text")
                #expect(doc.version == after["version"] as! Int, "\(label) version")
                #expect(doc.lineCount == after["lineCount"] as! Int, "\(label) lineCount")
                #expect(doc.eol.rawValue == after["eol"] as! String, "\(label) eol")
                #expect(doc.canUndo == after["canUndo"] as! Bool && doc.canRedo == after["canRedo"] as! Bool, "\(label) can undo/redo")
                let undoStack = after["undoStack"] as! [[String: Any]]
                let actualStack = doc.history.undoStack
                #expect(actualStack.count == undoStack.count, "\(label) undo count")
                for (entry, expected) in zip(actualStack, undoStack) {
                    #expect(entry.forwardEdits == Self.resolved(expected["forwardEdits"]), "\(label) forward")
                    #expect(entry.inverseEdits == Self.resolved(expected["inverseEdits"]), "\(label) inverse")
                    #expect(entry.versionBefore == expected["versionBefore"] as! Int && entry.versionAfter == expected["versionAfter"] as! Int, "\(label) versions")
                    #expect(entry.coalescingMode?.rawValue == expected["coalescingMode"] as? String, "\(label) coalescing")
                    #expect(entry.undoBoundary == expected["undoBoundary"] as? Bool, "\(label) boundary")
                }
                #expect(doc.history.redoStack.count == after["redoCount"] as! Int, "\(label) redo count")
            }
        }
    }
}
