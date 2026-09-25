// Builds highlighted lines directly from the grammar's binary tokens: the
// native equivalent of Shiki's `codeToTokensWithThemes` + theme alignment +
// `mergeWhitespaceTokens`, working on UTF-16 offsets instead of token
// strings. Output is identical to the string-based pipeline.

import Foundation

extension DiffsHighlighter {
    /// Highlights `code` into one line per Shiki line (`\n` or `\r\n`
    /// separated), with tokens as UTF-16 ranges into the line text.
    func highlightLines(_ code: String, lang: String, slots: ThemeSlots, tokenizeMaxLineLength: Int) throws -> [HighlightedLine] {
        let effectiveLang = streamLanguage(lang)
        let names = slots.themeNames
        let grammar = isPlainLang(effectiveLang) ? nil : highlighter.getGrammar(effectiveLang)
        if effectiveLang == "ansi" || names.contains("none") || (grammar == nil && !isPlainLang(effectiveLang)) {
            // Rare paths keep the string pipeline (ANSI escapes, the `none`
            // theme, and the missing-language error).
            return try tokenize(code, lang: lang, themes: slots, tokenizeMaxLineLength: tokenizeMaxLineLength).map(Self.line(from:))
        }
        let lines = splitHighlightLines(code)
        var result: [HighlightedLine] = []
        result.reserveCapacity(lines.count)
        guard let grammar else {
            // Plain text: one unstyled token per non-empty line.
            for line in lines {
                let length = line.utf16.count
                let tokens = length == 0 ? [] : [HighlightedToken(start: 0, end: length, styles: TokenStyles(repeating: TokenStyle(), count: names.count))]
                result.append(HighlightedLine(text: line, tokens: tokens))
            }
            return result
        }

        let options = TokenizeOptions(tokenizeMaxLineLength: tokenizeMaxLineLength, tokenizeTimeLimit: 0)
        let prepared = try highlighter.prepareThemes(names, grammar: grammar, options: options)
        var colors = prepared.colors
        var builder = LineTokenBuilder(themeCount: names.count)
        var state = StateStack.initial
        for line in lines {
            let length = line.utf16.count
            if length == 0 {
                result.append(HighlightedLine(text: line, tokens: []))
                continue
            }
            if tokenizeMaxLineLength > 0, length >= tokenizeMaxLineLength {
                // Too long to tokenize: one token in the default color; the
                // grammar state is not advanced.
                let styles = TokenStyles(repeating: TokenStyle(), count: names.count)
                result.append(HighlightedLine(text: line, tokens: [HighlightedToken(start: 0, end: length, styles: styles)]))
                continue
            }
            let tokenized = grammar.tokenizeLine2(line, state, timeLimit: 0, extraThemes: prepared.attributes)
            state = tokenized.primary.ruleStack
            let tokens = builder.build(
                line: line,
                length: length,
                primary: tokenized.primary.tokens,
                extra: tokenized.extra,
                colors: &colors
            )
            result.append(HighlightedLine(text: line, tokens: tokens))
        }
        return result
    }

    private static func line(from tokens: [(content: String, styles: [TokenStyle])]) -> HighlightedLine {
        var text = ""
        var highlighted: [HighlightedToken] = []
        highlighted.reserveCapacity(tokens.count)
        var offset = 0
        for token in tokens {
            let length = token.content.utf16.count
            if length == 0 { continue }
            text += token.content
            highlighted.append(HighlightedToken(start: offset, end: offset + length, styles: TokenStyles(token.styles)))
            offset += length
        }
        return HighlightedLine(text: text, tokens: highlighted)
    }
}

/// Shiki `splitLines` without offsets: splits on `\n`, dropping a `\r`
/// before it. Works on UTF-8, so lines are copied without transcoding.
func splitHighlightLines(_ code: String) -> [String] {
    var lines: [String] = []
    var start = code.utf8.startIndex
    var index = start
    let utf8 = code.utf8
    while index != utf8.endIndex {
        if utf8[index] == UInt8(ascii: "\n") {
            var end = index
            if end > start, utf8[utf8.index(before: end)] == UInt8(ascii: "\r") {
                end = utf8.index(before: end)
            }
            lines.append(String(code[start ..< end]))
            start = utf8.index(after: index)
        }
        index = utf8.index(after: index)
    }
    lines.append(String(code[start...]))
    return lines
}

/// Turns one line's binary tokens (per theme) into highlighted tokens,
/// reusing its buffers across lines.
struct LineTokenBuilder {
    /// A theme's styled ranges; `end` is exclusive.
    private struct Run {
        var end: Int
        var style: TokenStyle
    }

    private let themeCount: Int
    private var runs: [[Run]]
    private var segments: [(start: Int, end: Int, styles: TokenStyles)] = []
    private var positions: [Int]
    private var units: [UInt16] = []

    init(themeCount: Int) {
        self.themeCount = themeCount
        runs = Array(repeating: [], count: themeCount)
        positions = Array(repeating: 0, count: themeCount)
    }

    mutating func build(line: String, length: Int, primary: [UInt32], extra: [[UInt32]], colors: inout [ThemeColorResolver]) -> [HighlightedToken] {
        // Each theme's non-empty tokens (Shiki's `tokenizeWithTheme`).
        for theme in 0 ..< themeCount {
            let binary = theme == 0 ? primary : extra[theme - 1]
            runs[theme].removeAll(keepingCapacity: true)
            let count = binary.count / 2
            for j in 0 ..< count {
                let start = min(Int(binary[2 * j]), length)
                let next = j + 1 < count ? Int(binary[2 * j + 2]) : length
                if Int(binary[2 * j]) == next { continue }
                let end = min(max(next, start), length)
                runs[theme].append(Run(end: end, style: colors[theme].style(for: binary[2 * j + 1])))
            }
        }

        // `alignThemesTokenization`: split at every theme's boundaries.
        segments.removeAll(keepingCapacity: true)
        for theme in 0 ..< themeCount { positions[theme] = 0 }
        var offset = 0
        while (0 ..< themeCount).allSatisfy({ positions[$0] < runs[$0].count }) {
            var end = Int.max
            for theme in 0 ..< themeCount {
                end = min(end, runs[theme][positions[theme]].end)
            }
            let first = runs[0][positions[0]].style
            let styles = themeCount == 1 ? TokenStyles(first) : TokenStyles(first, runs[1][positions[1]].style)
            if end > offset {
                segments.append((offset, end, styles))
            }
            for theme in 0 ..< themeCount where runs[theme][positions[theme]].end == end {
                positions[theme] += 1
            }
            offset = end
        }

        // `mergeWhitespaceTokens`: whitespace-only tokens join the following
        // token, unless styled with underline or strikethrough (single
        // theme only).
        units.removeAll(keepingCapacity: true)
        units.append(contentsOf: line.utf16)
        var tokens: [HighlightedToken] = []
        tokens.reserveCapacity(segments.count)
        var carryStart: Int?
        for (index, segment) in segments.enumerated() {
            let merge = themeCount > 1 || !(segment.styles.first?.fontStyle.contains(.underline) == true || segment.styles.first?.fontStyle.contains(.strikethrough) == true)
            if merge, index + 1 < segments.count, isWhitespaceOnly(segment.start, segment.end) {
                if carryStart == nil { carryStart = segment.start }
            } else if let start = carryStart {
                if merge {
                    tokens.append(HighlightedToken(start: start, end: segment.end, styles: segment.styles))
                } else {
                    tokens.append(HighlightedToken(start: start, end: segment.start, styles: TokenStyles(repeating: TokenStyle(), count: themeCount)))
                    tokens.append(HighlightedToken(start: segment.start, end: segment.end, styles: segment.styles))
                }
                carryStart = nil
            } else {
                tokens.append(HighlightedToken(start: segment.start, end: segment.end, styles: segment.styles))
            }
        }
        return tokens
    }

    /// Whether the UTF-16 range holds only JavaScript whitespace. Every
    /// whitespace character is in the BMP, so surrogates never match.
    private func isWhitespaceOnly(_ start: Int, _ end: Int) -> Bool {
        guard start < end else { return false }
        for unit in units[start ..< end] {
            guard let scalar = Unicode.Scalar(unit), JSWhitespace.isWhitespace(scalar) else { return false }
        }
        return true
    }
}
