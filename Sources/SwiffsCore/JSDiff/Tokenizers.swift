// Ports of jsdiff's `diff/line.js`, `diff/word.js` (diffWordsWithSpace) and
// `diff/character.js`.

import Foundation

// MARK: - Lines

struct LineDiff: TokenDiff {
    func tokenize(_ value: String, options: DiffOptions) -> [String] {
        var value = value
        if options.stripTrailingCr {
            // remove one \r before \n to match GNU diff's --strip-trailing-cr
            value = value.replacingOccurrences(of: "\r\n", with: "\n")
        }
        // Equivalent of `value.split(/(\n|\r\n)/)` followed by merging each
        // separator back onto its line.
        var lines: [String] = []
        let utf8 = value.utf8
        var start = utf8.startIndex
        var index = start
        while index != utf8.endIndex {
            let byte = utf8[index]
            let next = utf8.index(after: index)
            if byte == UInt8(ascii: "\n") {
                if options.newlineIsToken {
                    // Split the line content from its separator (`\n` or `\r\n`).
                    var contentEnd = index
                    if contentEnd > start, utf8[utf8.index(before: contentEnd)] == UInt8(ascii: "\r") {
                        contentEnd = utf8.index(before: contentEnd)
                    }
                    lines.append(String(value[start ..< contentEnd]))
                    lines.append(String(value[contentEnd ..< next]))
                } else {
                    lines.append(String(value[start ..< next]))
                }
                start = next
            }
            index = next
        }
        if start != utf8.endIndex {
            lines.append(String(value[start...]))
        }
        return lines
    }

    func equalityKey(_ token: String, options: DiffOptions) -> String {
        var token = token
        if options.ignoreWhitespace {
            if !options.newlineIsToken || !token.contains("\n") {
                token = JSString.trim(token)
            }
        } else if options.ignoreNewlineAtEof, !options.newlineIsToken {
            if token.utf8.last == UInt8(ascii: "\n") {
                token = String(token.utf8.dropLast())!
            }
        }
        return options.ignoreCase ? token.lowercased() : token
    }
}

/// `diffLines` from jsdiff.
public func diffLines(_ oldString: String, _ newString: String, options: DiffOptions = DiffOptions()) -> [ChangeObject]? {
    LineDiff().diff(oldString, newString, options: options)
}

/// `diffTrimmedLines` from jsdiff.
public func diffTrimmedLines(_ oldString: String, _ newString: String, options: DiffOptions = DiffOptions()) -> [ChangeObject]? {
    var options = options
    options.ignoreWhitespace = true
    return LineDiff().diff(oldString, newString, options: options)
}

// MARK: - Words with space

/// Word characters as defined by jsdiff's `extendedWordChars`.
@inline(__always)
func isExtendedWordChar(_ scalar: Unicode.Scalar) -> Bool {
    let v = scalar.value
    switch v {
    case 0x61 ... 0x7A, 0x41 ... 0x5A, 0x30 ... 0x39, 0x5F: return true
    case 0xAD: return true
    case 0xC0 ... 0xD6, 0xD8 ... 0xF6, 0xF8 ... 0x2C6, 0x2C8 ... 0x2D7, 0x2DE ... 0x2FF: return true
    case 0x1E00 ... 0x1EFF: return true
    default: return false
    }
}

struct WordsWithSpaceDiff: TokenDiff {
    /// Equivalent to matching
    /// `/(\r?\n)|[word]+|[^\S\n\r]+|[^word]/ug` against the value.
    func tokenize(_ value: String, options: DiffOptions) -> [String] {
        let scalars = Array(value.unicodeScalars)
        var tokens: [String] = []
        var index = 0
        let count = scalars.count
        func makeString(_ range: Range<Int>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[range])
            return String(view)
        }
        while index < count {
            let scalar = scalars[index]
            if scalar == "\r", index + 1 < count, scalars[index + 1] == "\n" {
                tokens.append("\r\n")
                index += 2
                continue
            }
            if scalar == "\n" {
                tokens.append("\n")
                index += 1
                continue
            }
            if isExtendedWordChar(scalar) {
                var end = index + 1
                while end < count, isExtendedWordChar(scalars[end]) { end += 1 }
                tokens.append(makeString(index ..< end))
                index = end
                continue
            }
            if JSString.isWhitespace(scalar), scalar != "\n", scalar != "\r" {
                var end = index + 1
                while end < count, JSString.isWhitespace(scalars[end]), scalars[end] != "\n", scalars[end] != "\r" {
                    end += 1
                }
                tokens.append(makeString(index ..< end))
                index = end
                continue
            }
            tokens.append(String(scalar))
            index += 1
        }
        return tokens
    }
}

/// `diffWordsWithSpace` from jsdiff.
public func diffWordsWithSpace(_ oldString: String, _ newString: String, options: DiffOptions = DiffOptions()) -> [ChangeObject] {
    WordsWithSpaceDiff().diff(oldString, newString, options: options) ?? []
}

// MARK: - Characters

struct CharacterDiff: TokenDiff {
    /// `Array.from(value)` splits by code point.
    func tokenize(_ value: String, options: DiffOptions) -> [String] {
        value.unicodeScalars.map { String($0) }
    }
}

/// `diffChars` from jsdiff.
public func diffChars(_ oldString: String, _ newString: String, options: DiffOptions = DiffOptions()) -> [ChangeObject] {
    CharacterDiff().diff(oldString, newString, options: options) ?? []
}
