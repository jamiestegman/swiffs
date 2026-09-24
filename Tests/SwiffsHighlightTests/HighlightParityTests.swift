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

    /// One tokenization resolving every theme must match Shiki's separate
    /// per-theme runs.
    @Test func singlePassMultiThemeTokensMatchShiki() throws {
        let cases = try Self.loadCases()
        let highlighter = try Self.makeHighlighter(langs: cases.map(\.lang), themes: cases[0].themes)
        var mismatches: [String] = []
        for testCase in cases where !isPlainLang(testCase.lang) {
            guard let grammar = highlighter.getGrammar(testCase.lang) else { continue }
            let options = TokenizeOptions(tokenizeMaxLineLength: testCase.name == "long-line" ? 120 : 0, tokenizeTimeLimit: 0)
            // Rotate so every theme is resolved both as the primary and as an
            // extra theme.
            for rotation in testCase.themes.indices {
                let themes = Array(testCase.themes[rotation...] + testCase.themes[..<rotation])
                let perTheme = try highlighter.tokenizeWithThemes(testCase.code, grammar: grammar, themeNames: themes, options: options)
                for (index, theme) in themes.enumerated() {
                    let actual: [[[JSONValue]]] = perTheme[index].map { line in
                        line.map { [.int($0.content.utf16.count), $0.color.map { .string($0) } ?? .null, .int($0.fontStyle.rawValue)] }
                    }
                    if actual != testCase.expected[theme]! {
                        mismatches.append("\(testCase.name) [\(testCase.lang)/\(theme)] rotation \(rotation)")
                    }
                }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches: \(mismatches.prefix(12))")
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
