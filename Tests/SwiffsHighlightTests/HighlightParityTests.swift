import Foundation
import Testing
@testable import SwiffsHighlight

/// Differential tests against Shiki 4.4.1 (Oniguruma engine) output.
struct HighlightParityTests {
    struct Case: Decodable {
        var lang: String
        var code: String
        var name: String
        var themes: [String]
        /// theme -> lines -> [length, color, fontStyle]
        var expected: [String: [[[JSONValue]]]]
        var jsEngineDiffers: Bool
    }

    enum JSONValue: Decodable, Equatable {
        case int(Int)
        case string(String)
        case null

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null; return }
            if let int = try? container.decode(Int.self) { self = .int(int); return }
            self = .string(try container.decode(String.self))
        }
    }

    static func loadCases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/highlight.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    static func makeHighlighter(langs: [String], themes: [String]) throws -> Highlighter {
        let highlighter = Highlighter()
        for lang in Set(langs) where !isPlainLang(lang) {
            highlighter.loadLanguages(try BundledData.languageRegistrations(lang))
        }
        for theme in themes {
            highlighter.loadTheme(try BundledData.theme(theme))
        }
        return highlighter
    }

    @Test func tokensMatchShiki() throws {
        let cases = try Self.loadCases()
        let highlighter = try Self.makeHighlighter(langs: cases.map(\.lang), themes: cases[0].themes)
        var mismatches: [String] = []
        for testCase in cases {
            for theme in testCase.themes {
                let tokens = try highlighter.codeToTokensBase(
                    testCase.code,
                    lang: testCase.lang,
                    theme: theme,
                    options: TokenizeOptions(tokenizeMaxLineLength: testCase.name == "long-line" ? 120 : 0, tokenizeTimeLimit: 0)
                )
                let actual: [[[JSONValue]]] = tokens.map { line in
                    line.map { token in
                        [
                            .int(token.content.utf16.count),
                            token.color.map { .string($0) } ?? .null,
                            .int(token.fontStyle.rawValue),
                        ]
                    }
                }
                let expected = testCase.expected[theme]!
                if actual != expected {
                    let lineIndex = (0 ..< min(actual.count, expected.count)).first { actual[$0] != expected[$0] } ?? min(actual.count, expected.count)
                    let lines = shikiSplitLines(testCase.code)
                    let lineText = lineIndex < lines.count ? lines[lineIndex].line : "<eof>"
                    mismatches.append(
                        "\(testCase.name) [\(testCase.lang)/\(theme)] line \(lineIndex): \(lineText.debugDescription)\n  actual:   \(lineIndex < actual.count ? "\(actual[lineIndex])" : "-")\n  expected: \(lineIndex < expected.count ? "\(expected[lineIndex])" : "-")"
                    )
                }
            }
        }
        if !mismatches.isEmpty {
            let summary = mismatches.prefix(12).joined(separator: "\n")
            Issue.record("\(mismatches.count) mismatches:\n\(summary)")
        }
    }
}
