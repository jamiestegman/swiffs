import Foundation
import SwiffsCore
import SwiffsHighlight
import Testing
@testable import SwiffsEditor

/// Parity with upstream `command.ts`, `languages.ts`, `tokenizer.ts` and
/// `matchBrackets.ts` (see `generate-editor-features-fixtures.ts`).
struct EditorFeaturesParityTests {
    nonisolated(unsafe) static let fixture: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/editor-features.json")
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    private static func json<T: Encodable>(_ value: T) -> Any {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }

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

    @Test func keymapMatchesUpstream() {
        let custom = CompiledEditorKeymap([EditorKeymapGroup(bindings: ["cmdOrCtrl+k": .toggleComment, "alt+z": .undo])])
        for entry in Self.fixture["keyEvents"] as! [[String: Any]] {
            let e = entry["event"] as! [String: Any]
            let event = EditorKeyEvent(key: e["key"] as! String, code: e["code"] as? String, altKey: e["altKey"] as! Bool, ctrlKey: e["ctrlKey"] as! Bool, metaKey: e["metaKey"] as! Bool, shiftKey: e["shiftKey"] as! Bool)
            #expect(resolveEditorCommand(event, platform: .mac)?.rawValue == entry["mac"] as? String, "\(e)")
            #expect(resolveEditorCommand(event, keymap: custom, platform: .mac)?.rawValue == entry["custom"] as? String, "custom \(e)")
            let find = resolveFindAgainShortcut(event, platform: .mac).map { $0 == .next ? "next" : "previous" }
            #expect(find == entry["findAgain"] as? String, "find \(e)")
        }
    }

    @Test func commentsMatchUpstream() {
        for testCase in Self.fixture["commentCases"] as! [[String: Any]] {
            let lang = testCase["lang"] as! String
            let document = TextDocument<Never>(uri: "f", text: testCase["text"] as! String, languageId: lang)
            let selections = (testCase["selections"] as! [Any]).map(Self.selection)
            let config = resolveCommentConfig(lang)
            let expectedConfig = testCase["config"] as! [String: Any]
            #expect(config.lineComment == expectedConfig["lineComment"] as? String, "\(lang) line comment")
            let block = expectedConfig["blockComment"] as! [String]
            #expect(config.blockComment.open == block[0] && config.blockComment.close == block[1], "\(lang) block comment")
            let label = "\(lang) \(testCase["selections"]!)"
            if let token = config.lineComment {
                #expect(Self.same(Self.json(resolveLineCommentEdits(document, selections, token: token)), testCase["lineEdits"]), "\(label) line")
            }
            for (key, linewise) in [("blockEdits", false), ("blockLinewise", true)] {
                let result = resolveBlockCommentEdits(document, selections, open: config.blockComment.open, close: config.blockComment.close, linewise: linewise)
                let actual: Any = result.map { result -> Any in
                    [
                        "edits": Self.json(result.edits),
                        "nextSelectionOffsets": result.nextSelectionOffsets.map { [$0.start, $0.end, $0.direction.rawValue] },
                    ]
                } ?? NSNull()
                if !Self.same(actual, testCase[key]) {
                    Issue.record("\(label) \(key): \(actual) != \(String(describing: testCase[key]))")
                }
            }
        }
    }

    private static func tokens(_ lines: [Int: [EditorLineToken]]) -> [Any] {
        lines.keys.sorted().map { line in [line, lines[line]!.map { [$0.offset, $0.color, $0.text] }] }
    }

    private static func sortedEntries(_ value: Any?) -> [Any] {
        (value as! [[Any]]).sorted { ($0[0] as! Int) < ($1[0] as! Int) }
    }

    @Test func tokenizerAndBracketsMatchUpstream() throws {
        let highlighter = DiffsHighlighter()
        try highlighter.prepare(langs: ["typescript", "python"], themes: ["pierre-dark", "pierre-light"])
        for testCase in Self.fixture["tokenizerCases"] as! [[String: Any]] {
            let lang = testCase["lang"] as! String
            let document = TextDocument<Never>(uri: "f", text: testCase["text"] as! String, languageId: lang)
            let tokenizer = EditorTokenizer(highlighter: highlighter, document: document, themeName: "pierre-dark")
            tokenizer.scheduler = { _ in }
            var deferred: [[Int: [EditorLineToken]]] = []
            tokenizer.onDeferTokenize = { lines, _ in deferred.append(lines) }
            let renderRange = (testCase["renderRange"] as? [String: Any]).map {
                RenderRange(startingLine: $0["startingLine"] as! Int, totalLines: $0["totalLines"] as! Int)
            }
            let label = "\(lang) range=\(String(describing: renderRange))"
            let steps = testCase["steps"] as! [[String: Any]]
            let lineCount = document.lineCount
            let initial = try tokenizer.tokenize(TextDocumentChange(
                changes: [], startLine: 0, startCharacter: 0, endCharacter: 0, endLine: lineCount - 1, endedAtDocumentEnd: false,
                previousLineCount: lineCount, lineCount: lineCount, lineDelta: 0, changedLineRanges: [0 ... lineCount - 1],
                changedLineChanges: [.init(startLine: 0, endLine: lineCount - 1, lineDelta: 0, startCharacter: 0, endCharacter: 0, endedAtDocumentEnd: false)]
            ), renderRange: renderRange)
            #expect(Self.same(Self.tokens(initial), Self.sortedEntries(steps[0]["dirty"])), "\(label) initial")
            for (index, step) in steps.enumerated().dropFirst() {
                let edit = step["edit"] as! [String: Any]
                let range = edit["range"] as! [String: Any]
                deferred.removeAll()
                let change = try document.applyEdits([TextEdit(range: TextRange(start: Self.position(range["start"]), end: Self.position(range["end"])), newText: edit["newText"] as! String)])!
                #expect(document.getText() == step["text"] as! String, "\(label) step \(index) text")
                let dirty = try tokenizer.tokenize(change, renderRange: renderRange)
                if !Self.same(Self.tokens(dirty), Self.sortedEntries(step["dirty"])) {
                    Issue.record("\(label) step \(index) dirty: \(Self.tokens(dirty)) != \(Self.sortedEntries(step["dirty"]))")
                }
                let expectedDeferred = (step["deferred"] as! [Any]).map { Self.sortedEntries($0) }
                #expect(Self.same(deferred.map { Self.tokens($0) }, expectedDeferred), "\(label) step \(index) deferred")
                var brackets: [Any] = []
                for line in 0 ..< document.lineCount {
                    for character in 0 ... document.getLineLength(line) {
                        if let match = findBracketMatchRanges(document, tokenizer, Position(line: line, character: character)) {
                            brackets.append([line, character, [Self.json(match.open), Self.json(match.close)]])
                        }
                    }
                }
                if !Self.same(brackets, step["brackets"]) {
                    Issue.record("\(label) step \(index) brackets: \(brackets) != \(String(describing: step["brackets"]))")
                }
                let ignored: [Any] = (0 ..< document.lineCount).map { line in
                    tokenizer.getStringCommentRegexpRangesInLine(line).map { ranges -> Any in ranges.map { [$0.start, $0.end] } } ?? NSNull()
                }
                #expect(Self.same(ignored, step["ignored"]), "\(label) step \(index) ignored")
            }
            tokenizer.cleanUp()
        }
    }
}
