// Port of `shiki-stream` (`ShikiStreamTokenizer`): tokenizes code as it
// arrives in chunks. Complete lines become stable; the trailing partial line
// is re-tokenized on the next chunk and its previous tokens are recalled.

import Foundation
import SwiffsCore

/// A streamed token. Line breaks are emitted as `"\n"` tokens without styles.
public struct StreamToken: Hashable, Sendable {
    public var content: String
    /// One style per theme slot; empty for line break tokens.
    public var styles: TokenStyles

    public init(content: String, styles: TokenStyles) {
        self.content = content
        self.styles = styles
    }

    public var isLineBreak: Bool { content == "\n" && styles.isEmpty }
}

/// Output of `CodeToTokenTransformStream` with `allowRecalls: true`.
public enum StreamEvent: Hashable, Sendable {
    /// Remove this many previously emitted tokens.
    case recall(Int)
    case token(StreamToken)
}

public struct StreamEnqueueResult: Sendable {
    /// Number of previously emitted unstable tokens to remove.
    public var recall: Int
    public var stable: [StreamToken]
    /// Tokens of the trailing partial line; they may be recalled.
    public var unstable: [StreamToken]
}

/// `ShikiStreamTokenizer`. Not thread safe.
public final class StreamTokenizer {
    public let highlighter: DiffsHighlighter
    public let lang: String
    public let themes: ThemeSlots
    public let tokenizeMaxLineLength: Int

    public private(set) var tokensStable: [StreamToken] = []
    public private(set) var tokensUnstable: [StreamToken] = []
    private var lastUnstableCodeChunk = ""
    /// One grammar stack per theme slot (`GrammarState`).
    private var lastStableGrammarState: [StateStack]?

    public init(highlighter: DiffsHighlighter, lang: String, themes: ThemeSlots, tokenizeMaxLineLength: Int = 0) {
        self.highlighter = highlighter
        self.lang = lang
        self.themes = themes
        self.tokenizeMaxLineLength = tokenizeMaxLineLength
    }

    /// Enqueues a chunk of code.
    public func enqueue(_ chunk: String) throws -> StreamEnqueueResult {
        let text = lastUnstableCodeChunk + chunk
        let chunkLines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        var stable: [StreamToken] = []
        var unstable: [StreamToken] = []
        let recall = tokensUnstable.count
        for (index, line) in chunkLines.enumerated() {
            let isLastLine = index == chunkLines.count - 1
            let result = try highlighter.tokenizeStreamLine(
                line,
                lang: lang,
                themes: themes,
                grammarState: lastStableGrammarState,
                tokenizeMaxLineLength: tokenizeMaxLineLength
            )
            var tokens = result.tokens
            if !isLastLine {
                tokens.append(StreamToken(content: "\n", styles: []))
                lastStableGrammarState = result.grammarState
                stable.append(contentsOf: tokens)
            } else {
                unstable = tokens
                lastUnstableCodeChunk = line
            }
        }
        tokensStable.append(contentsOf: stable)
        tokensUnstable = unstable
        return StreamEnqueueResult(recall: recall, stable: stable, unstable: unstable)
    }

    /// Finishes the stream; the unstable tokens become final.
    public func close() -> [StreamToken] {
        let stable = tokensUnstable
        tokensUnstable = []
        lastUnstableCodeChunk = ""
        lastStableGrammarState = nil
        return stable
    }

    public func clear() {
        tokensStable = []
        tokensUnstable = []
        lastUnstableCodeChunk = ""
        lastStableGrammarState = nil
    }

    /// `CodeToTokenTransformStream.transform` with `allowRecalls: true`.
    public func transform(_ chunk: String) throws -> [StreamEvent] {
        let result = try enqueue(chunk)
        var events: [StreamEvent] = []
        if result.recall > 0 { events.append(.recall(result.recall)) }
        events.append(contentsOf: result.stable.map(StreamEvent.token))
        events.append(contentsOf: result.unstable.map(StreamEvent.token))
        return events
    }
}

extension DiffsHighlighter {
    /// Tokenizes one line for streaming (`highlighter.codeToTokens(line, {
    /// grammarState })` with `defaultColor: false`). Whitespace tokens are not
    /// merged, matching `codeToTokens`.
    func tokenizeStreamLine(
        _ line: String,
        lang: String,
        themes: ThemeSlots,
        grammarState: [StateStack]?,
        tokenizeMaxLineLength: Int
    ) throws -> (tokens: [StreamToken], grammarState: [StateStack]?) {
        let effectiveLang = streamLanguage(lang)
        if effectiveLang == "ansi" {
            // ANSI has no grammar state; each line starts fresh.
            let lines = try tokenizeLines(line, lang: "ansi", themes: themes, tokenizeMaxLineLength: tokenizeMaxLineLength)
            return ((lines.first ?? []).map { StreamToken(content: $0.content, styles: TokenStyles($0.styles)) }, nil)
        }
        let options = TokenizeOptions(tokenizeMaxLineLength: tokenizeMaxLineLength, tokenizeTimeLimit: 0)
        let names = themes.themeNames
        var perTheme: [[[ThemedToken]]] = []
        var states: [StateStack] = []
        var hasState = true
        for (index, name) in names.enumerated() {
            let state = grammarState.flatMap { index < $0.count ? $0[index] : nil }
            let result = try highlighter.codeToTokensBase(line, lang: effectiveLang, theme: name, options: options, grammarState: state)
            perTheme.append(result.tokens)
            if let next = result.grammarState { states.append(next) } else { hasState = false }
        }
        let aligned = names.count > 1 ? alignThemesTokenization(perTheme) : perTheme
        guard let first = aligned.first, let firstLine = first.first else {
            return ([], hasState ? states : nil)
        }
        let tokens = firstLine.enumerated().map { tokenIndex, token in
            StreamToken(content: token.content, styles: TokenStyles(aligned.map { themeTokens in
                let t = themeTokens[0][tokenIndex]
                return TokenStyle(color: t.color.flatMap { $0.isEmpty ? nil : $0 }, fontStyle: t.fontStyle)
            }))
        }
        return (tokens, hasState ? states : nil)
    }
}
