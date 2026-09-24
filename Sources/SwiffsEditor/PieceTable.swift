// Port of `editor/pieceTable.ts`: a treap of pieces over an original and an
// append-only "added" UTF-16 buffer, with per-subtree line break counts so
// line/offset lookups and edits are O(log P).

import Foundation
import SwiffsCore

private let lineFeed: UInt16 = 10
private let carriageReturn: UInt16 = 13
private let maxFindMatches = 100_000
private let wordSeparators = Set("`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/?".utf16)

/// A segment of the original or added buffer.
private struct Piece {
    static let original = 0
    static let added = 1

    let source: Int
    let offset: Int
    let length: Int
    let lineOffsetStart: Int
    let lineOffsetEnd: Int
    let hasVirtualTrailingCRBreak: Bool
    /// -1 when the piece is empty (JS `NaN` char codes never match).
    let firstCharCode: Int
    let lastCharCode: Int

    /// A slice ending between a backing-buffer CRLF needs its own lone-CR
    /// break until the tree reconnects it to a piece beginning with LF.
    var lineBreakCount: Int {
        lineOffsetEnd - lineOffsetStart + (hasVirtualTrailingCRBreak ? 1 : 0)
    }
}

/// A text buffer with its line start offsets.
private final class TextBuffer {
    var units: [UInt16]
    var lineOffsets: [Int]

    init(_ units: [UInt16]) {
        self.units = units
        lineOffsets = computeLineOffsets(utf16: units)
    }

    /// Appends text, extending `lineOffsets`; returns the start offset.
    func append(_ text: [UInt16]) -> Int {
        let offset = units.count
        var i = 0
        while i < text.count {
            let code = text[i]
            if code != lineFeed, code != carriageReturn {
                i += 1
                continue
            }
            if code == carriageReturn, i + 1 < text.count, text[i + 1] == lineFeed {
                i += 1
            }
            lineOffsets.append(offset + i + 1)
            i += 1
        }
        units.append(contentsOf: text)
        return offset
    }

    func unit(_ index: Int) -> Int {
        index >= 0 && index < units.count ? Int(units[index]) : -1
    }
}

/// A treap node: a binary search tree on document offset and a max-heap on
/// `priority`.
private final class PieceNode {
    var left: PieceNode?
    var right: PieceNode?
    weak var parent: PieceNode?
    var priority: UInt32 = 0
    var piece: Piece
    var subtreeLength: Int
    var subtreeLineBreakCount: Int
    var subtreeFirstCharCode: Int
    var subtreeLastCharCode: Int

    init(_ piece: Piece) {
        self.piece = piece
        subtreeLength = piece.length
        subtreeLineBreakCount = piece.lineBreakCount
        subtreeFirstCharCode = piece.firstCharCode
        subtreeLastCharCode = piece.lastCharCode
    }

    func updateSubtreeLength() {
        subtreeLength = (left?.subtreeLength ?? 0) + piece.length + (right?.subtreeLength ?? 0)
        // Pieces count their edge characters in isolation. Collapse a CRLF
        // only when the two characters are adjacent in this subtree.
        subtreeLineBreakCount = (left?.subtreeLineBreakCount ?? 0) + piece.lineBreakCount + (right?.subtreeLineBreakCount ?? 0)
            - (formsCRLF(left?.subtreeLastCharCode, piece.firstCharCode) ? 1 : 0)
            - (formsCRLF(piece.lastCharCode, right?.subtreeFirstCharCode) ? 1 : 0)
        subtreeFirstCharCode = left?.subtreeFirstCharCode ?? piece.firstCharCode
        subtreeLastCharCode = right?.subtreeLastCharCode ?? piece.lastCharCode
    }
}

private func formsCRLF(_ left: Int?, _ right: Int?) -> Bool {
    left == Int(carriageReturn) && right == Int(lineFeed)
}

/// A piece table over UTF-16 text (`PieceTable`).
public final class PieceTable {
    private let original: TextBuffer
    private let add = TextBuffer([])
    private var root: PieceNode?
    public private(set) var length = 0
    public private(set) var lineCount = 0
    private var lastVisitedLine: (line: Int, includeLineBreak: Bool, text: [UInt16])?
    private var lastVisitedLineLength: (line: Int, includeLineBreak: Bool, length: Int)?
    private var lastPosition: (line: Int, character: Int, offset: Int)?
    /// Treap priority seed (the 32-bit golden-ratio constant).
    private var priorityState: UInt32 = 0x9E37_79B9

    public convenience init(_ text: String) {
        self.init(units: Array(text.utf16))
    }

    public init(units: [UInt16]) {
        original = TextBuffer(units)
        let piece = createPiece(Piece.original, 0, units.count)
        root = piece.length > 0 ? createNode(piece) : nil
        length = root?.subtreeLength ?? 0
        lineCount = (root?.subtreeLineBreakCount ?? 0) + 1
    }

    // MARK: Reading

    public func getText() -> String {
        UTF16Text.string(textUnits())
    }

    public func getText(_ range: DocumentRange) throws -> String {
        let start = try offsetAt(range.start)
        let end = try offsetAt(range.end)
        return getTextSlice(start, end)
    }

    /// The document's UTF-16 code units.
    public func textUnits() -> [UInt16] {
        var result: [UInt16] = []
        result.reserveCapacity(length)
        forEachPieceSegment { buffer, start, end in
            result.append(contentsOf: buffer.units[start ..< end])
            return true
        }
        return result
    }

    public func getLineText(_ line: Int, includeLineBreak: Bool = false) throws -> String {
        UTF16Text.string(try getLineUnits(line, includeLineBreak: includeLineBreak))
    }

    public func getLineUnits(_ line: Int, includeLineBreak: Bool = false) throws -> [UInt16] {
        if let cached = lastVisitedLine, cached.line == line, cached.includeLineBreak == includeLineBreak {
            return cached.text
        }
        let offset = try getLineOffset(line)
        let text = sliceUnits(offset.start, offset.end, trimEOL: !includeLineBreak)
        lastVisitedLine = (line, includeLineBreak, text)
        lastVisitedLineLength = (line, includeLineBreak, text.count)
        return text
    }

    public func getLineLength(_ line: Int, includeLineBreak: Bool = false) throws -> Int {
        if let cached = lastVisitedLineLength, cached.line == line, cached.includeLineBreak == includeLineBreak {
            return cached.length
        }
        if let cached = lastVisitedLine, cached.line == line, cached.includeLineBreak == includeLineBreak {
            lastVisitedLineLength = (line, includeLineBreak, cached.text.count)
            return cached.text.count
        }
        let offset = try getLineOffset(line)
        var length = offset.end - offset.start
        if !includeLineBreak {
            while length > 0, let unit = unitAt(offset.start + length - 1), UTF16Text.isEOL(unit) {
                length -= 1
            }
        }
        lastVisitedLineLength = (line, includeLineBreak, length)
        return length
    }

    public func getTextSlice(_ start: Int, _ end: Int, trimEOL: Bool = false) -> String {
        UTF16Text.string(sliceUnits(start, end, trimEOL: trimEOL))
    }

    /// UTF-16 units in `[start, end)`. With `trimEOL`, line break units at
    /// the end of each piece chunk are dropped (as upstream does per chunk).
    public func sliceUnits(_ start: Int, _ end: Int, trimEOL: Bool = false) -> [UInt16] {
        if start >= end { return [] }
        let sliceStart = clamp(start, 0, length)
        let sliceEnd = clamp(end, sliceStart, length)
        if sliceStart >= sliceEnd { return [] }
        guard var location = findPieceAtOffset(sliceStart) else { return [] }
        var result: [UInt16] = []
        var remaining = sliceEnd - sliceStart
        var node: PieceNode? = location.node
        while let current = node, remaining > 0 {
            let take = min(current.piece.length - location.offsetInPiece, remaining)
            let buffer = bufferFor(current.piece.source)
            let chunkStart = current.piece.offset + location.offsetInPiece
            var chunkEnd = chunkStart + take
            if trimEOL {
                while chunkEnd > chunkStart, UTF16Text.isEOL(buffer.units[chunkEnd - 1]) {
                    chunkEnd -= 1
                }
            }
            result.append(contentsOf: buffer.units[chunkStart ..< chunkEnd])
            remaining -= take
            location.offsetInPiece = 0
            node = nextNode(current)
        }
        return result
    }

    /// The UTF-16 unit at an offset (`charAt`), nil outside the document.
    public func unitAt(_ offset: Int) -> UInt16? {
        guard let location = findPieceAtOffset(offset) else { return nil }
        let buffer = bufferFor(location.node.piece.source)
        return buffer.units[location.node.piece.offset + location.offsetInPiece]
    }

    /// `charAt`: the unit as a one-unit string, "" outside the document.
    public func charAt(_ offset: Int) -> String {
        unitAt(offset).map { UTF16Text.string([$0]) } ?? ""
    }

    public func includes(_ needle: String) -> Bool {
        let needle = Array(needle.utf16)
        if needle.isEmpty { return true }
        let table = createPrefixTable(needle)
        var matched = 0
        var found = false
        forEachPieceSegment { buffer, start, end in
            for offset in start ..< end {
                let code = buffer.units[offset]
                while matched > 0, code != needle[matched] { matched = table[matched - 1] }
                if code == needle[matched] { matched += 1 }
                if matched == needle.count {
                    found = true
                    return false
                }
            }
            return true
        }
        return found
    }

    public func findNextNonOverlappingSubstring(_ needle: String, occupied: [(start: Int, end: Int)]) -> Int? {
        let needle = Array(needle.utf16)
        if needle.isEmpty || needle.count > length { return nil }
        let ranges = normalizeRanges(occupied, length)
        let pivot = ranges.reduce(0) { max($0, $1.end) }
        let table = createPrefixTable(needle)
        var matched = 0
        var documentOffset = 0
        var wrappedOffset: Int?
        var foundOffset: Int?
        forEachPieceSegment { buffer, start, end in
            for offset in start ..< end {
                let code = buffer.units[offset]
                while matched > 0, code != needle[matched] { matched = table[matched - 1] }
                if code == needle[matched] { matched += 1 }
                if matched == needle.count {
                    let matchStart = documentOffset - needle.count + 1
                    if !rangeOverlaps(ranges, matchStart, matchStart + needle.count) {
                        if matchStart >= pivot {
                            foundOffset = matchStart
                            return false
                        }
                        if wrappedOffset == nil { wrappedOffset = matchStart }
                    }
                    matched = table[matched - 1]
                }
                documentOffset += 1
            }
            return true
        }
        return foundOffset ?? wrappedOffset
    }

    /// Line-by-line search (newline-spanning patterns are unsupported).
    public func search(_ params: SearchParams) -> [(start: Int, end: Int)] {
        if params.text.isEmpty || length == 0 { return [] }
        if params.text.contains("\n") || params.text.unicodeScalars.contains("\n") || params.text.unicodeScalars.contains("\r")
            || (params.regex && (params.text.contains("\\n") || params.text.contains("\\r")))
        {
            return []
        }
        guard let pattern = compileSearchRegExp(params.text, isRegex: params.regex, caseSensitive: params.caseSensitive) else {
            return []
        }
        return collectSearchMatchesLineByLine(pattern, wholeWord: params.wholeWord, limit: maxFindMatches)
    }

    private func collectSearchMatchesLineByLine(_ pattern: NSRegularExpression, wholeWord: Bool, limit: Int) -> [(start: Int, end: Int)] {
        var out: [(start: Int, end: Int)] = []
        let document = textUnits()
        let lineOffsets = computeLineOffsets(utf16: document)
        for line in 0 ..< lineOffsets.count {
            let lineStart = lineOffsets[line]
            var lineEnd = line + 1 < lineOffsets.count ? lineOffsets[line + 1] : document.count
            while lineEnd > lineStart, UTF16Text.isEOL(document[lineEnd - 1]) { lineEnd -= 1 }
            let lineText = UTF16Text.string(document[lineStart ..< lineEnd]) as NSString
            var location = 0
            while location <= lineText.length {
                // Like JS `lastIndex`: lookbehind and `^` still see the whole line.
                guard let match = pattern.firstMatch(
                    in: lineText as String,
                    options: [.withTransparentBounds, .withoutAnchoringBounds],
                    range: NSRange(location: location, length: lineText.length - location)
                ) else { break }
                let rel = match.range.location
                let fragmentLength = match.range.length
                if fragmentLength == 0 {
                    location = advancePastEmptyMatch(lineText, rel)
                    continue
                }
                let docStart = lineStart + rel
                if !wholeWord || isWholeWordAtDocOffsets(document, docStart, fragmentLength) {
                    out.append((docStart, docStart + fragmentLength))
                    if out.count >= limit { return out }
                }
                location = rel + fragmentLength
            }
        }
        return out
    }

    // MARK: Editing

    public func insert(_ text: String, at offset: Int) {
        let units = Array(text.utf16)
        if units.isEmpty { return }
        let start = clamp(offset, 0, length)
        replaceRangeIncremental(start, start, units)
        invalidateCaches()
    }

    public func delete(_ offset: Int, length deleteLength: Int) {
        if deleteLength <= 0 || length == 0 { return }
        let start = clamp(offset, 0, length)
        let end = clamp(start + deleteLength, start, length)
        if start == end { return }
        replaceRangeIncremental(start, end, [])
        invalidateCaches()
    }

    /// Applies edits sorted ascending and non-overlapping.
    public func applyEdits(_ edits: [ResolvedTextEdit]) {
        if edits.isEmpty { return }
        for edit in edits.reversed() {
            let start = clamp(edit.start, 0, length)
            let end = clamp(edit.end, start, length)
            replaceRangeIncremental(start, end, Array(edit.text.utf16))
        }
        invalidateCaches()
    }

    // MARK: Positions

    public func positionAt(_ offset: Int) -> Position {
        let clamped = clamp(offset, 0, length)
        if length == 0 { return Position(line: 0, character: 0) }
        let line = lineAtOffset(clamped)
        let lineStart = line == 0 ? 0 : lineBreakOffset(line - 1)
        let character = clamped - lineStart
        lastPosition = (line, character, clamped)
        return Position(line: line, character: character)
    }

    public func positionsAt(_ offsets: [Int]) -> [Position] {
        if length == 0 { return offsets.map { _ in Position(line: 0, character: 0) } }
        return offsets.map(positionAt)
    }

    public func offsetAt(_ position: Position) throws -> Int {
        if position.line < 0 || length == 0 { return 0 }
        if position.line >= lineCount {
            throw DiffsError("Line index out of range: \(position.line)")
        }
        if let last = lastPosition, last.line == position.line, last.character == position.character {
            return last.offset
        }
        let offset = try getLineOffset(position.line)
        let character = clamp(position.character, 0, offset.end - offset.start)
        return offset.start + character
    }

    // MARK: Tree queries

    private func findPieceAtOffset(_ offset: Int) -> (node: PieceNode, offsetInPiece: Int)? {
        if offset < 0 || offset >= length { return nil }
        var node = root
        var remaining = offset
        while let current = node {
            let leftLength = current.left?.subtreeLength ?? 0
            if remaining < leftLength {
                node = current.left
                continue
            }
            remaining -= leftLength
            if remaining < current.piece.length {
                return (current, remaining)
            }
            remaining -= current.piece.length
            node = current.right
        }
        return nil
    }

    private func nextNode(_ node: PieceNode) -> PieceNode? {
        if var next = node.right {
            while let left = next.left { next = left }
            return next
        }
        var current = node
        while let parent = current.parent, current === parent.right {
            current = parent
        }
        return current.parent
    }

    private func getLineOffset(_ line: Int) throws -> (start: Int, end: Int) {
        if line < 0 { throw DiffsError("Line index out of range: \(line)") }
        if length == 0 {
            if line == 0 { return (0, 0) }
            throw DiffsError("Line index out of range: \(line)")
        }
        if line >= lineCount { throw DiffsError("Line index out of range: \(line)") }
        let start = line == 0 ? 0 : lineBreakOffset(line - 1)
        let end = line < lineCount - 1 ? lineBreakOffset(line) : length
        return (start, end)
    }

    private func lineAtOffset(_ offset: Int) -> Int {
        var node = root
        var remaining = clamp(offset, 0, length)
        var line = 0
        while let current = node {
            let leftLength = current.left?.subtreeLength ?? 0
            if remaining < leftLength {
                node = current.left
                continue
            }
            line += (current.left?.subtreeLineBreakCount ?? 0)
                - (formsCRLF(current.left?.subtreeLastCharCode, current.piece.firstCharCode) ? 1 : 0)
            remaining -= leftLength
            if remaining <= current.piece.length {
                let buffer = bufferFor(current.piece.source)
                let lineOffsetEnd = min(upperBound(buffer.lineOffsets, current.piece.offset + remaining), current.piece.lineOffsetEnd)
                line += lineOffsetEnd - current.piece.lineOffsetStart
                if remaining == current.piece.length, current.piece.hasVirtualTrailingCRBreak {
                    line += 1
                }
                if remaining == current.piece.length, formsCRLF(current.piece.lastCharCode, nextNode(current)?.piece.firstCharCode) {
                    line -= 1
                }
                return line
            }
            line += current.piece.lineBreakCount - (formsCRLF(current.piece.lastCharCode, current.right?.subtreeFirstCharCode) ? 1 : 0)
            remaining -= current.piece.length
            node = current.right
        }
        return lineCount - 1
    }

    private func lineBreakOffset(_ lineBreakIndex: Int) -> Int {
        var node = root
        var remaining = lineBreakIndex
        var documentOffset = 0
        var followingCharCode: Int?
        while let current = node {
            let leftLineBreakCount = (current.left?.subtreeLineBreakCount ?? 0)
                - (formsCRLF(current.left?.subtreeLastCharCode, current.piece.firstCharCode) ? 1 : 0)
            if remaining < leftLineBreakCount {
                followingCharCode = current.piece.firstCharCode
                node = current.left
                continue
            }
            documentOffset += current.left?.subtreeLength ?? 0
            remaining -= leftLineBreakCount
            let nextCharCode = current.right?.subtreeFirstCharCode ?? followingCharCode
            let pieceLineBreakCount = current.piece.lineBreakCount - (formsCRLF(current.piece.lastCharCode, nextCharCode) ? 1 : 0)
            if remaining < pieceLineBreakCount {
                return documentOffset + pieceLineBreakOffset(current.piece, remaining)
            }
            documentOffset += current.piece.length
            remaining -= pieceLineBreakCount
            node = current.right
        }
        return length
    }

    private func pieceLineBreakOffset(_ piece: Piece, _ lineBreakIndex: Int) -> Int {
        let bufferLineBreakCount = piece.lineOffsetEnd - piece.lineOffsetStart
        if lineBreakIndex < bufferLineBreakCount {
            return bufferFor(piece.source).lineOffsets[piece.lineOffsetStart + lineBreakIndex] - piece.offset
        }
        return piece.length
    }

    private func forEachPieceSegment(_ callback: (TextBuffer, Int, Int) -> Bool) {
        _ = walk(root) { node in
            callback(bufferFor(node.piece.source), node.piece.offset, node.piece.offset + node.piece.length)
        }
    }

    private func walk(_ node: PieceNode?, _ visit: (PieceNode) -> Bool) -> Bool {
        // Iterative in-order walk (deep treaps are rare but possible).
        var stack: [PieceNode] = []
        var current = node
        while current != nil || !stack.isEmpty {
            while let c = current {
                stack.append(c)
                current = c.left
            }
            let top = stack.removeLast()
            if !visit(top) { return false }
            current = top.right
        }
        return true
    }

    private func bufferFor(_ source: Int) -> TextBuffer {
        source == Piece.original ? original : add
    }

    private func createPiece(_ source: Int, _ offset: Int, _ length: Int) -> Piece {
        let buffer = bufferFor(source)
        let end = offset + length
        let lineOffsetStart = upperBound(buffer.lineOffsets, offset)
        let lineOffsetEnd = upperBound(buffer.lineOffsets, end)
        let lastCharCode = buffer.unit(end - 1)
        let lastLineOffset = lineOffsetEnd - 1 >= 0 && lineOffsetEnd - 1 < buffer.lineOffsets.count ? buffer.lineOffsets[lineOffsetEnd - 1] : nil
        return Piece(
            source: source,
            offset: offset,
            length: length,
            lineOffsetStart: lineOffsetStart,
            lineOffsetEnd: lineOffsetEnd,
            hasVirtualTrailingCRBreak: lastCharCode == Int(carriageReturn) && lastLineOffset != end,
            firstCharCode: length > 0 ? buffer.unit(offset) : -1,
            lastCharCode: length > 0 ? lastCharCode : -1
        )
    }

    // MARK: Tree mutation

    /// Replaces `[start, end)` with `text` by splitting at the start,
    /// dropping the deleted prefix and joining the inserted piece back in.
    private func replaceRangeIncremental(_ start: Int, _ end: Int, _ text: [UInt16]) {
        if start == end, text.isEmpty { return }
        let (left, rest) = split(root, start)
        let right = dropPrefix(rest, end - start)
        var newRoot: PieceNode?
        if !text.isEmpty {
            let inserted = createPiece(Piece.added, add.append(text), text.count)
            newRoot = mergeNodes(appendCoalescing(left, inserted), right)
        } else {
            let (seamPiece, restRight) = popLeftmost(right)
            if let seamPiece {
                newRoot = mergeNodes(appendCoalescing(left, seamPiece), restRight)
            } else {
                newRoot = left
            }
        }
        newRoot?.parent = nil
        root = newRoot
        length = newRoot?.subtreeLength ?? 0
        lineCount = (newRoot?.subtreeLineBreakCount ?? 0) + 1
    }

    private func invalidateCaches() {
        lastVisitedLine = nil
        lastVisitedLineLength = nil
        lastPosition = nil
    }

    private func nextPriority() -> UInt32 {
        priorityState = priorityState &* 1_664_525 &+ 1_013_904_223
        return priorityState
    }

    private func createNode(_ piece: Piece) -> PieceNode {
        let node = PieceNode(piece)
        node.priority = nextPriority()
        return node
    }

    private func setLeft(_ node: PieceNode, _ child: PieceNode?) {
        node.left = child
        child?.parent = node
    }

    private func setRight(_ node: PieceNode, _ child: PieceNode?) {
        node.right = child
        child?.parent = node
    }

    private func split(_ node: PieceNode?, _ offset: Int) -> (PieceNode?, PieceNode?) {
        guard let node else { return (nil, nil) }
        if offset <= 0 { return (nil, node) }
        if offset >= node.subtreeLength { return (node, nil) }
        let leftLength = node.left?.subtreeLength ?? 0
        if offset <= leftLength {
            let (l, r) = split(node.left, offset)
            setLeft(node, r)
            node.updateSubtreeLength()
            return (l, node)
        }
        let pieceLength = node.piece.length
        if offset >= leftLength + pieceLength {
            let (l, r) = split(node.right, offset - leftLength - pieceLength)
            setRight(node, l)
            node.updateSubtreeLength()
            return (node, r)
        }
        // Slice the piece; both halves inherit the node's priority.
        let inPiece = offset - leftLength
        let leftNode = PieceNode(createPiece(node.piece.source, node.piece.offset, inPiece))
        let rightNode = PieceNode(createPiece(node.piece.source, node.piece.offset + inPiece, pieceLength - inPiece))
        leftNode.priority = node.priority
        rightNode.priority = node.priority
        setLeft(leftNode, node.left)
        setRight(rightNode, node.right)
        leftNode.updateSubtreeLength()
        rightNode.updateSubtreeLength()
        return (leftNode, rightNode)
    }

    private func dropPrefix(_ node: PieceNode?, _ offset: Int) -> PieceNode? {
        guard let node, offset < node.subtreeLength else { return nil }
        if offset <= 0 { return node }
        let leftLength = node.left?.subtreeLength ?? 0
        if offset <= leftLength {
            setLeft(node, dropPrefix(node.left, offset))
            node.updateSubtreeLength()
            return node
        }
        let pieceEnd = leftLength + node.piece.length
        if offset >= pieceEnd {
            return dropPrefix(node.right, offset - pieceEnd)
        }
        let inPiece = offset - leftLength
        let rightNode = PieceNode(createPiece(node.piece.source, node.piece.offset + inPiece, node.piece.length - inPiece))
        rightNode.priority = node.priority
        setRight(rightNode, node.right)
        rightNode.updateSubtreeLength()
        return rightNode
    }

    private func mergeNodes(_ left: PieceNode?, _ right: PieceNode?) -> PieceNode? {
        guard let left else { return right }
        guard let right else { return left }
        if left.priority >= right.priority {
            setRight(left, mergeNodes(left.right, right))
            left.updateSubtreeLength()
            return left
        }
        setLeft(right, mergeNodes(left, right.left))
        right.updateSubtreeLength()
        return right
    }

    /// Appends a piece after every node in `tree`, merging it into the last
    /// piece when they are contiguous in the same buffer.
    private func appendCoalescing(_ tree: PieceNode?, _ piece: Piece) -> PieceNode {
        guard let tree else { return createNode(piece) }
        var last = tree
        while let right = last.right { last = right }
        if canCoalescePieces(last.piece, piece) {
            last.piece = coalesceTwoPieces(last.piece, piece)
            var node: PieceNode? = last
            while let current = node {
                current.updateSubtreeLength()
                if current === tree { break }
                node = current.parent
            }
            return tree
        }
        return mergeNodes(tree, createNode(piece))!
    }

    private func popLeftmost(_ tree: PieceNode?) -> (Piece?, PieceNode?) {
        guard let tree else { return (nil, nil) }
        guard let left = tree.left else { return (tree.piece, tree.right) }
        let (piece, newLeft) = popLeftmost(left)
        setLeft(tree, newLeft)
        tree.updateSubtreeLength()
        return (piece, tree)
    }
}

// MARK: - Helpers

private func canCoalescePieces(_ prev: Piece, _ next: Piece) -> Bool {
    prev.source == next.source && prev.offset + prev.length == next.offset && !formsCRLF(prev.lastCharCode, next.firstCharCode)
}

private func coalesceTwoPieces(_ prev: Piece, _ next: Piece) -> Piece {
    Piece(
        source: prev.source,
        offset: prev.offset,
        length: prev.length + next.length,
        lineOffsetStart: prev.lineOffsetStart,
        lineOffsetEnd: next.lineOffsetEnd,
        hasVirtualTrailingCRBreak: next.hasVirtualTrailingCRBreak,
        firstCharCode: prev.firstCharCode,
        lastCharCode: next.lastCharCode
    )
}

/// Index of the first element greater than `target`.
private func upperBound(_ values: [Int], _ target: Int) -> Int {
    var lo = 0
    var hi = values.count
    while lo < hi {
        let mid = lo + (hi - lo) / 2
        if values[mid] <= target { lo = mid + 1 } else { hi = mid }
    }
    return lo
}

private func createPrefixTable(_ text: [UInt16]) -> [Int] {
    var table = [Int](repeating: 0, count: text.count)
    var matched = 0
    var i = 1
    while i < text.count {
        let code = text[i]
        while matched > 0, code != text[matched] { matched = table[matched - 1] }
        if code == text[matched] { matched += 1 }
        table[i] = matched
        i += 1
    }
    return table
}

private func normalizeRanges(_ ranges: [(start: Int, end: Int)], _ length: Int) -> [(start: Int, end: Int)] {
    var normalized: [(start: Int, end: Int)] = []
    for range in ranges {
        let start = clamp(range.start, 0, length)
        let end = clamp(range.end, start, length)
        if start < end { normalized.append((start, end)) }
    }
    normalized.sort { $0.start < $1.start }
    var merged: [(start: Int, end: Int)] = []
    for range in normalized {
        if let previous = merged.last, range.start <= previous.end {
            merged[merged.count - 1].end = max(previous.end, range.end)
            continue
        }
        merged.append(range)
    }
    return merged
}

private func rangeOverlaps(_ ranges: [(start: Int, end: Int)], _ start: Int, _ end: Int) -> Bool {
    var low = 0
    var high = ranges.count
    while low < high {
        let mid = low + (high - low) / 2
        if ranges[mid].end <= start { low = mid + 1 } else { high = mid }
    }
    return low < ranges.count && ranges[low].start < end
}

private func isWordSeparator(_ code: UInt16) -> Bool {
    code <= 32 || code == 127 || wordSeparators.contains(code)
}

private func isWholeWordAtDocOffsets(_ text: [UInt16], _ docStart: Int, _ length: Int) -> Bool {
    let beforeOk = docStart <= 0 || isWordSeparator(text[docStart - 1])
    let afterOk = docStart + length >= text.count || isWordSeparator(text[docStart + length])
    return beforeOk && afterOk
}

private func escapeRegExp(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
        if ".*+?^${}()|[]\\".unicodeScalars.contains(scalar) { result += "\\" }
        result.unicodeScalars.append(scalar)
    }
    return result
}

/// `new RegExp(body, 'g' + (i) + (m))` using ICU regular expressions.
func compileSearchRegExp(_ source: String, isRegex: Bool, caseSensitive: Bool) -> NSRegularExpression? {
    let body = isRegex ? source : escapeRegExp(source)
    var options: NSRegularExpression.Options = []
    if !caseSensitive { options.insert(.caseInsensitive) }
    if isRegex { options.insert(.anchorsMatchLines) }
    return try? NSRegularExpression(pattern: body, options: options)
}

private func advancePastEmptyMatch(_ text: NSString, _ index: Int) -> Int {
    if index + 1 < text.length {
        let first = text.character(at: index)
        let second = text.character(at: index + 1)
        if UTF16Text.isHighSurrogate(first), UTF16Text.isLowSurrogate(second) {
            return index + 2
        }
    }
    return index + 1
}

/// Expands `$&`, `$1`, `$$` in a regex replacement.
private func expandReplaceString(_ replacement: String, match: NSTextCheckingResult, in text: NSString) -> String {
    let pattern = try! NSRegularExpression(pattern: #"\$([$&]|\d+)"#)
    let ns = replacement as NSString
    var result = ""
    var last = 0
    for token in pattern.matches(in: replacement, range: NSRange(location: 0, length: ns.length)) {
        result += ns.substring(with: NSRange(location: last, length: token.range.location - last))
        let group = ns.substring(with: token.range(at: 1))
        if group == "$" {
            result += "$"
        } else if group == "&" {
            result += text.substring(with: match.range)
        } else if let index = Int(group), index < match.numberOfRanges, match.range(at: index).location != NSNotFound {
            result += text.substring(with: match.range(at: index))
        }
        last = token.range.location + token.range.length
    }
    result += ns.substring(from: last)
    return result
}

/// The text inserted for one search match, including regex capture
/// substitution (`buildSearchReplacementText`).
public func buildSearchReplacementText(
    positionAt: (Int) -> Position,
    offsetAt: (Position) -> Int,
    getLineText: (Int) -> String,
    searchParams: SearchParams,
    matchStart: Int,
    matchEnd: Int
) -> String {
    guard searchParams.regex else { return searchParams.replaceText }
    let position = positionAt(matchStart)
    let lineText = getLineText(position.line) as NSString
    let lineStart = offsetAt(Position(line: position.line, character: 0))
    let relStart = matchStart - lineStart
    guard let pattern = compileSearchRegExp(searchParams.text, isRegex: true, caseSensitive: searchParams.caseSensitive),
          relStart >= 0, relStart <= lineText.length,
          let match = pattern.firstMatch(
              in: lineText as String,
              options: [.withTransparentBounds, .withoutAnchoringBounds],
              range: NSRange(location: relStart, length: lineText.length - relStart)
          ),
          match.range.location == relStart, match.range.length == matchEnd - matchStart
    else { return searchParams.replaceText }
    return expandReplaceString(searchParams.replaceText, match: match, in: lineText)
}
