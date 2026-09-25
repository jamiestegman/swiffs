import Foundation
import SwiffsCore
import Testing
@testable import SwiffsHighlight

/// Parity with upstream `ShikiStreamTokenizer` (see
/// `generate-stream-fixtures.ts`).
struct StreamParityTests {
    struct Token: Decodable {
        var content: String
        var htmlStyle: [String: String]?
        var color: String?
        var fontStyle: Int
    }

    struct Step: Decodable {
        var chunk: String
        var recall: Int
        var stable: [Token]
        var unstable: [Token]
    }

    struct Case: Decodable {
        var name: String
        var lang: String
        var themes: String
        var steps: [Step]
        var closed: [Token]
    }

    /// `getTokenStyleObject`
    private static func styleObject(_ style: TokenStyle) -> [(String, String)] {
        var result: [(String, String)] = []
        if let color = style.color { result.append(("color", color)) }
        if style.fontStyle.contains(.italic) { result.append(("font-style", "italic")) }
        if style.fontStyle.contains(.bold) { result.append(("font-weight", "bold")) }
        var decorations: [String] = []
        if style.fontStyle.contains(.underline) { decorations.append("underline") }
        if style.fontStyle.contains(.strikethrough) { decorations.append("line-through") }
        if !decorations.isEmpty { result.append(("text-decoration", decorations.joined(separator: " "))) }
        return result
    }

    /// `flatTokenVariants` with `defaultColor: false`.
    private static func htmlStyle(_ styles: [TokenStyle], slots: [String]) -> [String: String] {
        let objects = styles.map(styleObject)
        var keys: [String] = []
        for object in objects {
            for (key, _) in object where !keys.contains(key) { keys.append(key) }
        }
        var merged: [String: String] = [:]
        for (index, object) in objects.enumerated() {
            for key in keys {
                let value = object.first { $0.0 == key }?.1 ?? "inherit"
                merged["--diffs-token-\(slots[index])\(key == "color" ? "" : "-\(key)")"] = value
            }
        }
        return merged
    }

    private static func matches(_ actual: StreamToken, _ expected: Token, pair: Bool) -> Bool {
        guard actual.content.utf16.elementsEqual(expected.content.utf16) else { return false }
        if actual.isLineBreak {
            return expected.htmlStyle == nil && expected.color == nil
        }
        if pair {
            return htmlStyle(Array(actual.styles), slots: ["dark", "light"]) == (expected.htmlStyle ?? [:])
        }
        let style = actual.styles.first ?? TokenStyle()
        return style.color == expected.color && style.fontStyle.rawValue == expected.fontStyle
    }

    private static func compare(_ actual: [StreamToken], _ expected: [Token], pair: Bool, label: String) {
        guard actual.count == expected.count else {
            Issue.record("\(label): count \(actual.count) != \(expected.count): \(actual.map(\.content)) vs \(expected.map(\.content))")
            return
        }
        for (index, token) in actual.enumerated() where !matches(token, expected[index], pair: pair) {
            Issue.record("\(label)[\(index)]: \(token) != \(expected[index])")
            return
        }
    }

    @Test func streamTokenizerMatchesUpstream() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/stream.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        #expect(cases.count > 10)
        let highlighter = DiffsHighlighter()
        try highlighter.prepare(langs: ["typescript", "python", "markdown", "html"], themes: ["pierre-dark", "pierre-light", "github-dark"])
        for testCase in cases {
            let pair = testCase.themes == "pair"
            let themes: ThemeSlots = pair ? .pair(dark: "pierre-dark", light: "pierre-light") : .single("github-dark")
            let tokenizer = StreamTokenizer(highlighter: highlighter, lang: testCase.lang, themes: themes)
            for (index, step) in testCase.steps.enumerated() {
                let result = try tokenizer.enqueue(step.chunk)
                let label = "\(testCase.name) step \(index)"
                #expect(result.recall == step.recall, "\(label) recall")
                compare(result.stable, step.stable, pair: pair, label: "\(label) stable")
                compare(result.unstable, step.unstable, pair: pair, label: "\(label) unstable")
            }
            compare(tokenizer.close(), testCase.closed, pair: pair, label: "\(testCase.name) closed")
        }
    }

    private func compare(_ actual: [StreamToken], _ expected: [Token], pair: Bool, label: String) {
        Self.compare(actual, expected, pair: pair, label: label)
    }
}
