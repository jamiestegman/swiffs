// Port of `editor/matchBrackets.ts`: finds the bracket pair next to a
// caret, skipping strings, comments and regexps.

import Foundation

private let openBrackets: [UInt16: UInt16] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]
private let closeBrackets: [UInt16: UInt16] = [0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B]
private let maxBracketScanLines = 1000
private let maxBracketScanCharacters = 50000

private struct BracketPosition {
    var line: Int
    var character: Int
    var char: UInt16
}

/// Provides string/comment/regexp ranges per line (the editor tokenizer).
public protocol BracketIgnoredRangesProvider {
    func getStringCommentRegexpRangesInLine(_ line: Int) -> [(start: Int, end: Int)]?
}

extension EditorTokenizer: BracketIgnoredRangesProvider {}

/// Ranges of the bracket at the caret and its partner
/// (`findBracketMatchRanges`).
public func findBracketMatchRanges<A>(_ document: TextDocument<A>, _ tokenizer: BracketIgnoredRangesProvider, _ position: Position) -> (open: TextRange, close: TextRange)? {
    guard let bracket = findAdjacentBracket(document, tokenizer, document.normalizePosition(position)) else { return nil }
    if let closing = openBrackets[bracket.char] {
        return createBracketMatchRanges(bracket, findClosingBracket(document, tokenizer, bracket, closing))
    }
    if let opening = closeBrackets[bracket.char] {
        return createBracketMatchRanges(findOpeningBracket(document, tokenizer, bracket, opening), bracket)
    }
    return nil
}

private func findAdjacentBracket<A>(_ document: TextDocument<A>, _ tokenizer: BracketIgnoredRangesProvider, _ position: Position) -> BracketPosition? {
    // Adjacency is line-local: a column-zero caret is not next to the
    // previous line's last character.
    if position.character > 0, let previous = getBracketAtPosition(document, tokenizer, Position(line: position.line, character: position.character - 1)) {
        return previous
    }
    return getBracketAtPosition(document, tokenizer, position)
}

private func getBracketAtPosition<A>(_ document: TextDocument<A>, _ tokenizer: BracketIgnoredRangesProvider, _ position: Position) -> BracketPosition? {
    let lineText = document.getLineUnits(position.line)
    guard position.character >= 0, position.character < lineText.count else { return nil }
    let char = lineText[position.character]
    guard openBrackets[char] != nil || closeBrackets[char] != nil else { return nil }
    if isCharacterInIgnoredRanges(tokenizer.getStringCommentRegexpRangesInLine(position.line), position.character) { return nil }
    return BracketPosition(line: position.line, character: position.character, char: char)
}

private func findClosingBracket<A>(_ document: TextDocument<A>, _ tokenizer: BracketIgnoredRangesProvider, _ bracket: BracketPosition, _ closing: UInt16) -> BracketPosition? {
    var depth = 0
    var scannedLines = 0
    var scannedCharacters = 0
    var line = bracket.line
    while line < document.lineCount {
        defer { line += 1 }
        if scannedLines >= maxBracketScanLines { return nil }
        scannedLines += 1
        let lineText = document.getLineUnits(line)
        let ignored = tokenizer.getStringCommentRegexpRangesInLine(line)
        var cursor = 0
        var character = line == bracket.line ? bracket.character : 0
        while character < lineText.count {
            defer { character += 1 }
            if scannedCharacters >= maxBracketScanCharacters { return nil }
            scannedCharacters += 1
            if let ignored {
                while cursor < ignored.count, character >= ignored[cursor].end { cursor += 1 }
                if cursor < ignored.count, character >= ignored[cursor].start { continue }
            }
            let char = lineText[character]
            if char == bracket.char {
                depth += 1
            } else if char == closing {
                depth -= 1
                if depth == 0 { return BracketPosition(line: line, character: character, char: char) }
            }
        }
    }
    return nil
}

private func findOpeningBracket<A>(_ document: TextDocument<A>, _ tokenizer: BracketIgnoredRangesProvider, _ bracket: BracketPosition, _ opening: UInt16) -> BracketPosition? {
    var depth = 0
    var scannedLines = 0
    var scannedCharacters = 0
    var line = bracket.line
    while line >= 0 {
        defer { line -= 1 }
        if scannedLines >= maxBracketScanLines { return nil }
        scannedLines += 1
        let lineText = document.getLineUnits(line)
        let ignored = tokenizer.getStringCommentRegexpRangesInLine(line)
        var cursor = (ignored?.count ?? 0) - 1
        var character = line == bracket.line ? bracket.character : lineText.count - 1
        while character >= 0 {
            defer { character -= 1 }
            if scannedCharacters >= maxBracketScanCharacters { return nil }
            scannedCharacters += 1
            if let ignored {
                while cursor >= 0, character < ignored[cursor].start { cursor -= 1 }
                if cursor >= 0, character < ignored[cursor].end { continue }
            }
            guard character < lineText.count else { continue }
            let char = lineText[character]
            if char == bracket.char {
                depth += 1
            } else if char == opening {
                depth -= 1
                if depth == 0 { return BracketPosition(line: line, character: character, char: char) }
            }
        }
    }
    return nil
}

private func isCharacterInIgnoredRanges(_ ranges: [(start: Int, end: Int)]?, _ character: Int) -> Bool {
    guard let ranges else { return false }
    for range in ranges {
        if character < range.start { return false }
        if character < range.end { return true }
    }
    return false
}

private func createBracketMatchRanges(_ first: BracketPosition?, _ second: BracketPosition?) -> (open: TextRange, close: TextRange)? {
    guard let first, let second else { return nil }
    func range(_ position: BracketPosition) -> TextRange {
        TextRange(start: Position(line: position.line, character: position.character), end: Position(line: position.line, character: position.character + 1))
    }
    return (range(first), range(second))
}
