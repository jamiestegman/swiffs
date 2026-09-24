// Single-theme line tokenization for the editor (`tokenizeLine` in
// `editor/tokenizer.ts`).

import Foundation

/// A token of an editor line: UTF-16 start offset, theme color and text
/// (`HighlightedToken` = `[char, fg, text]`).
public struct EditorLineToken: Hashable, Sendable {
    public var offset: Int
    /// The theme color, or "" for unstyled text.
    public var color: String
    public var text: String

    public init(offset: Int, color: String, text: String) {
        self.offset = offset
        self.color = color
        self.text = text
    }
}

public struct EditorLineTokenizeResult {
    public var ruleStack: StateStack
    public var tokens: [EditorLineToken]
    /// Ranges of string, comment and regexp tokens (bracket matching skips
    /// them).
    public var bracketIgnoredRanges: [(start: Int, end: Int)]
    public var stoppedEarly: Bool
}

/// Tokenizes one line with a grammar and a theme color map.
public func tokenizeEditorLine(
    grammar: Grammar,
    colorMap: [String],
    lineText: String,
    state: StateStack,
    timeLimit: Double = 500,
    collectBracketIgnoredRanges: Bool = true,
    resolveTokens: Bool = true
) -> EditorLineTokenizeResult {
    let result = grammar.tokenizeLine2(lineText, state, timeLimit: timeLimit)
    var tokens: [EditorLineToken] = []
    var ignored: [(start: Int, end: Int)] = []
    if !resolveTokens, !collectBracketIgnoredRanges {
        return EditorLineTokenizeResult(ruleStack: result.ruleStack, tokens: [], bracketIgnoredRanges: [], stoppedEarly: result.stoppedEarly)
    }
    let units = Array(lineText.utf16)
    let count = result.tokens.count / 2
    for j in 0 ..< count {
        let offset = Int(result.tokens[2 * j])
        let next = j + 1 < count ? Int(result.tokens[2 * j + 2]) : units.count
        if offset == next { continue }
        let metadata = result.tokens[2 * j + 1]
        if resolveTokens {
            let fg = EncodedTokenMetadata.getForeground(metadata)
            let lower = min(offset, units.count)
            let upper = min(max(next, lower), units.count)
            tokens.append(EditorLineToken(
                offset: offset,
                color: fg < colorMap.count ? colorMap[fg] : "",
                text: String(decoding: units[lower ..< upper], as: UTF16.self)
            ))
        }
        if collectBracketIgnoredRanges, EncodedTokenMetadata.getTokenType(metadata) > 0 {
            ignored.append((offset, next))
        }
    }
    return EditorLineTokenizeResult(ruleStack: result.ruleStack, tokens: tokens, bracketIgnoredRanges: ignored, stoppedEarly: result.stoppedEarly)
}

extension DiffsHighlighter {
    /// The loaded grammar for a language, when attached.
    public func grammar(for lang: String) -> Grammar? {
        guard areLanguagesAttached([lang]) else { return nil }
        return highlighter.getGrammar(lang)
    }

    /// Activates a theme and returns its color map (`highlighter.setTheme`).
    public func activateTheme(_ name: String) throws -> (theme: ThemeRegistration, colorMap: [String]) {
        try attachThemes([name])
        return try highlighter.setTheme(name)
    }
}
