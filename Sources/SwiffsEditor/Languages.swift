// Port of `editor/languages.ts`: comment tokens and line/block comment
// toggling.

import Foundation

/// Comment configuration for a language (`LanguageConfig`). A nil
/// `lineComment` means "use the default"; `.some(nil)` means "no line
/// comments" (upstream's `null`).
public struct LanguageConfig: Sendable {
    public var lineComment: String??
    public var blockComment: (open: String, close: String)?

    public init(lineComment: String?? = nil, blockComment: (open: String, close: String)? = nil) {
        self.lineComment = lineComment
        self.blockComment = blockComment
    }
}

public struct ResolvedLanguageConfig: Sendable {
    public var lineComment: String?
    public var blockComment: (open: String, close: String)
}

private let languageCommentConfigs: [String: LanguageConfig] = [
    "sql": LanguageConfig(lineComment: "--"),
    "ruby": LanguageConfig(lineComment: "#", blockComment: ("=begin", "=end")),
    "rst": LanguageConfig(lineComment: ".."),
    "coffeescript": LanguageConfig(lineComment: "#", blockComment: ("###", "###")),
    "cmd": LanguageConfig(lineComment: "@REM"),
    "julia": LanguageConfig(lineComment: "#", blockComment: ("#=", "=#")),
    "yaml": LanguageConfig(lineComment: "#"),
    "yml": LanguageConfig(lineComment: "#"),
    "markdown": LanguageConfig(lineComment: .some(nil), blockComment: ("<!--", "-->")),
    "zsh": LanguageConfig(lineComment: "#"),
    "makefile": LanguageConfig(lineComment: "#"),
    "handlebars": LanguageConfig(lineComment: .some(nil), blockComment: ("{{!--", "--}}")),
    "ini": LanguageConfig(lineComment: ";", blockComment: (";", " ")),
    "powershell": LanguageConfig(lineComment: "#", blockComment: ("<#", "#>")),
    "vb": LanguageConfig(lineComment: "'"),
    "xml": LanguageConfig(lineComment: .some(nil), blockComment: ("<!--", "-->")),
    "lua": LanguageConfig(lineComment: "--", blockComment: ("--[[", "]]")),
    "html": LanguageConfig(lineComment: .some(nil), blockComment: ("<!--", "-->")),
    "diff": LanguageConfig(lineComment: "#", blockComment: ("#", " ")),
    "r": LanguageConfig(lineComment: "#"),
    "fsharp": LanguageConfig(blockComment: ("(*", "*)")),
    "pug": LanguageConfig(lineComment: "//-"),
    "perl": LanguageConfig(lineComment: "#"),
    "tex": LanguageConfig(lineComment: "%"),
    "clojure": LanguageConfig(lineComment: ";;"),
    "css": LanguageConfig(lineComment: .some(nil)),
    "python": LanguageConfig(lineComment: "#", blockComment: ("\"\"\"", "\"\"\"")),
    "dotenv": LanguageConfig(lineComment: "#"),
    "dockerfile": LanguageConfig(lineComment: "#"),
    "razor": LanguageConfig(lineComment: .some(nil), blockComment: ("<!--", "-->")),
    "prompt": LanguageConfig(lineComment: .some(nil), blockComment: ("<!--", "-->")),
]

/// Language comment tokens over the defaults (`resolveCommentConfig`).
public func resolveCommentConfig(_ languageId: String, overrides: [String: LanguageConfig]? = nil) -> ResolvedLanguageConfig {
    let base = languageCommentConfigs[languageId]
    let override = overrides?[languageId]
    let lineComment: String?? = override?.lineComment ?? base?.lineComment
    let blockComment = override?.blockComment ?? base?.blockComment
    return ResolvedLanguageConfig(
        lineComment: lineComment == nil ? "//" : lineComment!,
        blockComment: blockComment ?? ("/*", "*/")
    )
}

private struct LineCommentInfo {
    var line: Int
    var comment: Int
    var empty: Bool
    var indent: Int
    var single: Bool
}

private func unitSlice(_ units: [UInt16], _ start: Int, _ end: Int) -> ArraySlice<UInt16> {
    let lower = max(0, min(start, units.count))
    let upper = max(lower, min(end, units.count))
    return units[lower ..< upper]
}

/// One aligned batch of line-comment edits (`resolveLineCommentEdits`).
public func resolveLineCommentEdits<A>(_ document: TextDocument<A>, _ selections: [EditorSelection], token: String) -> [TextEdit] {
    let tokenUnits = Array(token.utf16)
    var lines: [LineCommentInfo] = []
    var seen = Set<Int>()
    for selection in selections {
        var endLine = selection.end.line
        if selection.start.line < endLine, selection.end.character == 0 { endLine -= 1 }
        let startIndex = lines.count
        var minIndent = Int.max
        var line = selection.start.line
        while line <= endLine {
            defer { line += 1 }
            if seen.contains(line) { continue }
            seen.insert(line)
            let text = document.getLineUnits(line)
            let indent = text.count - jsTrimStart(text).count
            let empty = indent == text.count
            if !empty { minIndent = min(minIndent, indent) }
            lines.append(LineCommentInfo(
                line: line,
                comment: unitSlice(text, indent, indent + tokenUnits.count).elementsEqual(tokenUnits) ? indent : -1,
                empty: empty,
                indent: indent,
                single: false
            ))
        }
        if minIndent != Int.max {
            for index in startIndex ..< lines.count where !lines[index].empty {
                lines[index].indent = minIndent
            }
        }
        if lines.count == startIndex + 1 { lines[startIndex].single = true }
    }
    let shouldComment = lines.contains { $0.comment < 0 && (!$0.empty || $0.single) }
    var edits: [TextEdit] = []
    if shouldComment {
        for line in lines where !(line.empty && !line.single) {
            let position = Position(line: line.line, character: line.indent)
            edits.append(TextEdit(range: TextRange(start: position, end: position), newText: token + " "))
        }
        return edits
    }
    for line in lines where line.comment >= 0 {
        let text = document.getLineUnits(line.line)
        let start = line.comment
        let after = start + tokenUnits.count
        let end = after + (after < text.count && text[after] == 0x20 ? 1 : 0)
        edits.append(TextEdit(range: TextRange(start: Position(line: line.line, character: start), end: Position(line: line.line, character: end)), newText: ""))
    }
    return edits
}

private struct OffsetEdit {
    var start: Int
    var end: Int
    var text: String
    var textLength: Int { text.utf16.count }
}

private struct BlockCommentMatch {
    var open: OffsetEdit
    var close: OffsetEdit
    var contentStart: Int
    var contentEnd: Int
}

/// Block comment edits and the selections to restore
/// (`BlockCommentEditResult`).
public struct BlockCommentEditResult: Sendable {
    public var edits: [TextEdit]
    public var nextSelectionOffsets: [(start: Int, end: Int, direction: SelectionDirection)]
}

private let blockCommentSearchMargin = 50

private func jsTrimEnd(_ units: [UInt16]) -> ArraySlice<UInt16> {
    guard let last = units.lastIndex(where: { !(Unicode.Scalar($0).map(isJSWhitespace) ?? false) }) else { return [] }
    return units[...last]
}

private func isWhitespaceText(_ units: some Collection<UInt16>) -> Bool {
    // `/\s/.test(text)`: any whitespace unit.
    units.contains { Unicode.Scalar($0).map(isJSWhitespace) ?? false }
}

private func findBlockComment<A>(_ document: TextDocument<A>, _ open: [UInt16], _ close: [UInt16], _ from: Int, _ to: Int) -> BlockCommentMatch? {
    let beforeStart = max(0, from - blockCommentSearchMargin)
    let textBefore = Array(document.getTextSlice(beforeStart, from).utf16)
    let textAfter = Array(document.getTextSlice(to, to + blockCommentSearchMargin).utf16)
    let spaceBefore = textBefore.count - jsTrimEnd(textBefore).count
    let spaceAfter = textAfter.count - jsTrimStart(textAfter).count
    let beforeOffset = textBefore.count - spaceBefore
    if unitSlice(textBefore, beforeOffset - open.count, beforeOffset).elementsEqual(open) && beforeOffset - open.count >= 0,
       unitSlice(textAfter, spaceAfter, spaceAfter + close.count).elementsEqual(close)
    {
        return BlockCommentMatch(
            open: OffsetEdit(start: from - spaceBefore - open.count, end: from - spaceBefore + (spaceBefore > 0 ? 1 : 0), text: ""),
            close: OffsetEdit(start: to + spaceAfter - (spaceAfter > 0 ? 1 : 0), end: to + spaceAfter + close.count, text: ""),
            contentStart: from,
            contentEnd: to
        )
    }
    let length = to - from
    let shortText = length <= blockCommentSearchMargin * 2 ? Array(document.getTextSlice(from, to).utf16) : nil
    let startText = shortText ?? Array(document.getTextSlice(from, from + blockCommentSearchMargin).utf16)
    let endText = shortText ?? Array(document.getTextSlice(to - blockCommentSearchMargin, to).utf16)
    let startSpace = startText.count - jsTrimStart(startText).count
    let endSpace = endText.count - jsTrimEnd(endText).count
    let closeStart = to - endSpace - close.count
    guard unitSlice(startText, startSpace, startSpace + open.count).elementsEqual(open),
          Array(document.getTextSlice(closeStart, closeStart + close.count).utf16) == close
    else { return nil }
    let openStart = from + startSpace
    let charAfterOpen = open.count + startSpace
    let openEnd = openStart + open.count + (charAfterOpen < startText.count && isWhitespaceText([startText[charAfterOpen]]) ? 1 : 0)
    let closeDeleteStart = closeStart - (isWhitespaceText(Array(document.getTextSlice(closeStart - 1, closeStart).utf16)) ? 1 : 0)
    return BlockCommentMatch(
        open: OffsetEdit(start: openStart, end: openEnd, text: ""),
        close: OffsetEdit(start: closeDeleteStart, end: closeStart + close.count, text: ""),
        contentStart: openEnd,
        contentEnd: closeDeleteStart
    )
}

private func mapOffset(_ offset: Int, _ edits: [OffsetEdit], _ cumulativeDeltas: [Int], _ association: Int) -> Int {
    var low = 0
    var high = edits.count
    while low < high {
        let middle = (low + high) / 2
        if edits[middle].end < offset { low = middle + 1 } else { high = middle }
    }
    var delta = cumulativeDeltas[low]
    var index = low
    while index < edits.count {
        let edit = edits[index]
        defer { index += 1 }
        if offset < edit.start { break }
        if edit.start == edit.end, offset == edit.start {
            if association < 0 { break }
            delta += edit.textLength
            continue
        }
        if offset > edit.end {
            delta += edit.textLength - (edit.end - edit.start)
            continue
        }
        if offset == edit.end { return edit.start + delta + edit.textLength }
        return edit.start + delta + (association > 0 ? edit.textLength : 0)
    }
    return offset + delta
}

private struct BlockRangeInfo {
    var from: Int
    var to: Int
    var direction: SelectionDirection
    var comment: BlockCommentMatch?
}

private struct LogicalRange {
    var start: Int
    var end: Int
    var startAssociation: Int
    var endAssociation: Int
    var collapsedInset: Int?
}

/// Block comment toggling (`resolveBlockCommentEdits`).
public func resolveBlockCommentEdits<A>(_ document: TextDocument<A>, _ selections: [EditorSelection], open: String, close: String, linewise: Bool = false) -> BlockCommentEditResult? {
    let openUnits = Array(open.utf16)
    let closeUnits = Array(close.utf16)
    var ranges = selections.map { selection -> BlockRangeInfo in
        var start = selection.start
        var end = selection.end
        if linewise {
            var endLine = end.line
            if start.line < endLine, end.character == 0 { endLine -= 1 }
            let firstLine = document.getLineUnits(start.line)
            start = Position(line: start.line, character: firstLine.count - jsTrimStart(firstLine).count)
            end = Position(line: endLine, character: document.getLineLength(endLine))
        }
        return BlockRangeInfo(from: document.offsetAt(start), to: document.offsetAt(end), direction: selection.direction)
    }
    if linewise, ranges.count > 1 {
        ranges = ranges.enumerated().sorted { a, b in
            if a.element.from != b.element.from { return a.element.from < b.element.from }
            if a.element.to != b.element.to { return a.element.to < b.element.to }
            return a.offset < b.offset
        }.map(\.element)
        var last = 0
        for index in 1 ..< ranges.count {
            if ranges[index].from <= ranges[last].to {
                ranges[last].to = max(ranges[last].to, ranges[index].to)
            } else {
                last += 1
                ranges[last] = ranges[index]
            }
        }
        ranges.removeLast(ranges.count - (last + 1))
    }
    for index in ranges.indices {
        ranges[index].comment = findBlockComment(document, openUnits, closeUnits, ranges[index].from, ranges[index].to)
    }
    let shouldUncomment = ranges.allSatisfy { $0.comment != nil }
    var offsetEdits: [OffsetEdit] = []
    for range in ranges {
        if shouldUncomment, let comment = range.comment {
            offsetEdits.append(comment.open)
            offsetEdits.append(comment.close)
            continue
        }
        if range.comment != nil { continue }
        if range.from == range.to {
            offsetEdits.append(OffsetEdit(start: range.from, end: range.to, text: open + "  " + close))
            continue
        }
        offsetEdits.append(OffsetEdit(start: range.from, end: range.from, text: open + " "))
        offsetEdits.append(OffsetEdit(start: range.to, end: range.to, text: " " + close))
    }
    if offsetEdits.isEmpty { return nil }
    offsetEdits = offsetEdits.enumerated().sorted { a, b in
        if a.element.start != b.element.start { return a.element.start < b.element.start }
        if a.element.end != b.element.end { return a.element.end < b.element.end }
        return a.offset < b.offset
    }.map(\.element)
    let edits = offsetEdits.map {
        TextEdit(range: TextRange(start: document.positionAt($0.start), end: document.positionAt($0.end)), newText: $0.text)
    }
    if linewise { return BlockCommentEditResult(edits: edits, nextSelectionOffsets: []) }
    let logical = ranges.map { range -> LogicalRange in
        if shouldUncomment, let comment = range.comment {
            return LogicalRange(start: comment.contentStart, end: comment.contentEnd, startAssociation: 1, endAssociation: -1)
        }
        if range.comment != nil {
            return LogicalRange(start: range.from, end: range.to, startAssociation: 1, endAssociation: 1)
        }
        if range.from == range.to {
            return LogicalRange(start: range.from, end: range.to, startAssociation: -1, endAssociation: -1, collapsedInset: openUnits.count + 1)
        }
        return LogicalRange(start: range.from, end: range.to, startAssociation: 1, endAssociation: -1)
    }
    var cumulative = [0]
    for edit in offsetEdits {
        cumulative.append(cumulative[cumulative.count - 1] + edit.textLength - (edit.end - edit.start))
    }
    let next = logical.enumerated().map { index, range -> (start: Int, end: Int, direction: SelectionDirection) in
        let start = mapOffset(range.start, offsetEdits, cumulative, range.startAssociation) + (range.collapsedInset ?? 0)
        let end = range.collapsedInset == nil ? mapOffset(range.end, offsetEdits, cumulative, range.endAssociation) : start
        return (start, end, ranges[index].direction)
    }
    return BlockCommentEditResult(edits: edits, nextSelectionOffsets: next)
}
