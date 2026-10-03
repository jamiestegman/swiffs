import Foundation
import SwiffsCore

/// Highlights a file as text is appended to it, tokenizing only what is new:
/// complete lines keep their tokens, and the trailing partial line is
/// tokenized again with each append.
public actor HighlightStream {
    private let tokenizer: StreamTokenizer
    private let slots: Int
    /// Highlighted complete lines so far.
    private var lineCount = 0
    private var lineText = ""
    private var lineTokens: [HighlightedToken] = []
    /// A carriage return ending the last append, held until the next shows
    /// whether a line feed follows it.
    private var heldCarriageReturn = false

    init(lang: String, options: RenderFileOptions, registry: HighlighterRegistry) throws {
        let highlighter = DiffsHighlighter(registry: registry)
        let themes = ThemeSlots(options.theme)
        try highlighter.prepare(langs: [lang], themes: themes.themeNames)
        tokenizer = StreamTokenizer(highlighter: highlighter, lang: lang, themes: themes, tokenizeMaxLineLength: options.tokenizeMaxLineLength)
        slots = themes.count
    }

    /// Appends text. Returns the index of the first line that changed and
    /// that line and every line after it, the last one partial.
    public func append(_ text: String) throws -> (firstLine: Int, lines: [HighlightedLine]) {
        let firstLine = lineCount
        var text = heldCarriageReturn ? "\r" + text : text
        heldCarriageReturn = text.utf16.last == 0x0D
        if heldCarriageReturn { text.removeLast() }
        let result = try tokenizer.enqueue(normalizeHighlightLineEndings(text))
        var lines: [HighlightedLine] = []
        // The partial line is tokenized again from its start each time.
        lineText = ""
        lineTokens = []
        for token in result.stable {
            if token.isLineBreak {
                lines.append(finishedLine())
                lineText = ""
                lineTokens = []
                lineCount += 1
            } else {
                add(token)
            }
        }
        for token in result.unstable { add(token) }
        lines.append(finishedLine())
        return (firstLine, lines)
    }

    /// The current line without the carriage return of a CRLF ending.
    private func finishedLine() -> HighlightedLine {
        guard lineText.utf16.last == 0x0D else { return HighlightedLine(text: lineText, tokens: lineTokens) }
        let length = lineText.utf16.count - 1
        let text = String(decoding: lineText.utf16.prefix(length), as: UTF16.self)
        let tokens = lineTokens.compactMap { token -> HighlightedToken? in
            guard token.start < length else { return nil }
            return HighlightedToken(start: token.start, end: min(token.end, length), styles: token.styles)
        }
        return HighlightedLine(text: text, tokens: tokens)
    }

    private func add(_ token: StreamToken) {
        let start = lineText.utf16.count
        lineText += token.content
        let styles = token.styles.isEmpty ? TokenStyles(repeating: TokenStyle(), count: slots) : token.styles
        lineTokens.append(HighlightedToken(start: start, end: lineText.utf16.count, styles: styles))
    }
}

extension HighlightService {
    /// A stream that highlights a file as it grows, off the caller's thread.
    public func stream(for file: FileContents, options: RenderFileOptions) throws -> HighlightStream {
        try HighlightStream(lang: file.lang ?? getFiletypeFromFileName(file.name), options: options, registry: registry)
    }
}
