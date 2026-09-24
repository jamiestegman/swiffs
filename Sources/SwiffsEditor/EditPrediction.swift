// Port of `editor/editPrediction.ts`: edit history capture and the bounded
// request sent to an inline edit prediction provider.

import Foundation

/// A prediction request (`EditPredictRequest`).
public struct EditPredictRequest: Hashable, Sendable, Codable {
    public struct EditableRange: Hashable, Sendable, Codable {
        public var start: Int
        public var end: Int
    }

    public struct HistoryEntry: Hashable, Sendable, Codable {
        /// The edit as a unified diff.
        public var diff: String
        public var source: EditPredictionSource
    }

    public var path: String
    public var version: Int
    public var eol: String
    /// Bounded slice of the file around the cursor.
    public var excerptText: String
    /// Zero-based line where the excerpt starts.
    public var excerptStartLine: Int
    /// UTF-16 cursor offset within `excerptText`.
    public var cursorOffsetInExcerpt: Int
    /// Half-open UTF-16 range within `excerptText` that may be edited.
    public var editableRange: EditableRange
    public var editHistory: [HistoryEntry]
}

public enum EditPredictionSource: String, Hashable, Sendable, Codable {
    case user, prediction
}

/// A prediction (`EditPredictResponse`).
public struct EditPredictResponse: Hashable, Sendable {
    /// Non-overlapping edits in absolute document positions.
    public var edits: [TextEdit]
    /// Post-edit cursor.
    public var newCursor: Position

    public init(edits: [TextEdit], newCursor: Position) {
        self.edits = edits
        self.newCursor = newCursor
    }
}

/// Predicts the next edit. Cancelled (task cancellation) when the document
/// or cursor changes.
public protocol EditPredictProvider: Sendable {
    func predict(_ request: EditPredictRequest) async throws -> EditPredictResponse
}

/// One recorded edit (`EditPredictionHistoryRecord`).
public struct EditPredictionHistoryRecord: Hashable, Sendable {
    public var path: String
    public var hunk: String
    public var start: Int
    public var end: Int
    /// Milliseconds.
    public var at: Double
    public var source: EditPredictionSource
    var fragment: HistoryFragment?
}

struct HistoryFragment: Hashable, Sendable {
    var baseText: [UInt16]
    var currentText: [UInt16]
    var currentStart: Int
    var currentEnd: Int
    var startLine: Int
}

private struct TransactionFragment {
    var beforeText: [UInt16]
    var afterText: [UInt16]
    var startOffset: Int
    var startLine: Int
    var bounds: LineDiffBounds
}

private struct LineDiffBounds {
    var oldLineCount: Int
    var newLineCount: Int
    var prefixLines: Int
    var suffixLines: Int
}

private let editableTokens = 350
private let contextTokens = 150
private let maxEditableTokens = 512
private let maxContextTokens = 662
private let maxRequestBytes = 128 * 1024
private let maxHistoryEntries = 10
private let maxCaptureBytes = 6144
private let coalesceMilliseconds = 1000.0
private let coalesceLines = 8
private let diffContextLines = 3
private let captureContextOptions = [diffContextLines + coalesceLines, diffContextLines]

private func utf8Count(_ units: some Collection<UInt16>) -> Int {
    String(decoding: units, as: UTF16.self).utf8.count
}

private func unit(_ text: [UInt16], _ index: Int) -> UInt16? {
    index >= 0 && index < text.count ? text[index] : nil
}

private func lineStarts(_ text: [UInt16]) -> [Int] {
    var starts = [0]
    var index = 0
    while index < text.count {
        if text[index] == 13, unit(text, index + 1) == 10 { index += 1 }
        if text[index] == 10 || text[index] == 13 { starts.append(index + 1) }
        index += 1
    }
    return starts
}

private func diffLineCount(_ text: [UInt16], _ starts: [Int]) -> Int {
    if text.isEmpty { return 0 }
    return starts.last == text.count ? starts.count - 1 : starts.count
}

private func lineEnd(_ text: [UInt16], _ starts: [Int], _ line: Int) -> Int {
    guard line + 1 < starts.count else { return text.count }
    let next = starts[line + 1]
    return next - (unit(text, next - 1) == 10 && unit(text, next - 2) == 13 ? 2 : 1)
}

private func linesEqual(_ left: [UInt16], _ leftStarts: [Int], _ leftLine: Int, _ right: [UInt16], _ rightStarts: [Int], _ rightLine: Int) -> Bool {
    let leftStart = leftStarts[leftLine]
    let rightStart = rightStarts[rightLine]
    let length = lineEnd(left, leftStarts, leftLine) - leftStart
    if length != lineEnd(right, rightStarts, rightLine) - rightStart { return false }
    return left[leftStart ..< leftStart + length].elementsEqual(right[rightStart ..< rightStart + length])
}

private func lineDiffBounds(_ oldText: [UInt16], _ oldStarts: [Int], _ newText: [UInt16], _ newStarts: [Int]) -> LineDiffBounds {
    let oldCount = diffLineCount(oldText, oldStarts)
    let newCount = diffLineCount(newText, newStarts)
    var prefix = 0
    while prefix < oldCount, prefix < newCount, linesEqual(oldText, oldStarts, prefix, newText, newStarts, prefix) {
        prefix += 1
    }
    var suffix = 0
    while suffix < oldCount - prefix, suffix < newCount - prefix,
          linesEqual(oldText, oldStarts, oldCount - 1 - suffix, newText, newStarts, newCount - 1 - suffix)
    {
        suffix += 1
    }
    return LineDiffBounds(oldLineCount: oldCount, newLineCount: newCount, prefixLines: prefix, suffixLines: suffix)
}

private func slice(_ text: [UInt16], _ start: Int, _ end: Int) -> ArraySlice<UInt16> {
    let lower = max(0, min(start, text.count))
    let upper = max(lower, min(end, text.count))
    return text[lower ..< upper]
}

private func formatEditHunk(_ path: String, _ oldText: [UInt16], _ newText: [UInt16], _ lineOffset: Int = 0) -> (hunk: String, bounds: LineDiffBounds)? {
    if oldText == newText { return nil }
    let oldStarts = lineStarts(oldText)
    let newStarts = lineStarts(newText)
    let bounds = lineDiffBounds(oldText, oldStarts, newText, newStarts)
    if bounds.prefixLines == bounds.oldLineCount, bounds.prefixLines == bounds.newLineCount { return nil }
    let oldChangedEnd = bounds.oldLineCount - bounds.suffixLines
    let newChangedEnd = bounds.newLineCount - bounds.suffixLines
    func start(_ starts: [Int], _ line: Int, _ fallback: Int) -> Int { line < starts.count ? starts[line] : fallback }
    let oldChanged = slice(oldText, start(oldStarts, bounds.prefixLines, oldText.count), start(oldStarts, oldChangedEnd, oldText.count))
    let newChanged = slice(newText, start(newStarts, bounds.prefixLines, newText.count), start(newStarts, newChangedEnd, newText.count))
    if utf8Count(oldChanged) > maxCaptureBytes || utf8Count(newChanged) > maxCaptureBytes { return nil }
    let first = max(0, bounds.prefixLines - diffContextLines)
    let oldEnd = min(bounds.oldLineCount, oldChangedEnd + diffContextLines)
    let newEnd = min(bounds.newLineCount, newChangedEnd + diffContextLines)
    let oldCount = oldEnd - first
    let newCount = newEnd - first
    let line = first + lineOffset
    var output = [
        "--- a/\(path)",
        "+++ b/\(path)",
        "@@ -\(oldCount == 0 ? line : line + 1),\(oldCount) +\(newCount == 0 ? line : line + 1),\(newCount) @@",
    ]
    func lineText(_ text: [UInt16], _ starts: [Int], _ line: Int) -> String {
        String(decoding: slice(text, starts[line], lineEnd(text, starts, line)), as: UTF16.self)
    }
    for l in first ..< max(first, bounds.prefixLines) { output.append(" " + lineText(oldText, oldStarts, l)) }
    for l in bounds.prefixLines ..< max(bounds.prefixLines, oldChangedEnd) { output.append("-" + lineText(oldText, oldStarts, l)) }
    for l in bounds.prefixLines ..< max(bounds.prefixLines, newChangedEnd) { output.append("+" + lineText(newText, newStarts, l)) }
    for l in oldChangedEnd ..< max(oldChangedEnd, oldEnd) { output.append(" " + lineText(oldText, oldStarts, l)) }
    let hunk = output.joined(separator: "\n")
    return hunk.utf8.count <= maxCaptureBytes ? (hunk, bounds) : nil
}

private func applyEditsToSlice(_ text: [UInt16], _ sliceStart: Int, _ edits: [ResolvedTextEdit]) -> [UInt16]? {
    var result: [UInt16] = []
    var offset = 0
    for edit in edits {
        let start = edit.start - sliceStart
        let end = edit.end - sliceStart
        if start < offset || end < start || end > text.count { return nil }
        result.append(contentsOf: text[offset ..< start])
        result.append(contentsOf: edit.text.utf16)
        offset = end
    }
    result.append(contentsOf: text[offset...])
    return result
}

private func captureTransaction<A>(_ document: TextDocument<A>, _ change: TextDocumentChange) -> TransactionFragment? {
    let inverse = change.inverseEdits
    guard var changedStart = inverse.first?.start, var changedEnd = inverse.first?.end else { return nil }
    for edit in inverse.dropFirst() {
        changedStart = min(changedStart, edit.start)
        changedEnd = max(changedEnd, edit.end)
    }
    let positions = document.positionsAt([changedStart, changedEnd])
    for contextLines in captureContextOptions {
        let startLine = max(0, positions[0].line - contextLines)
        let endLine = min(document.lineCount - 1, positions[1].line + contextLines)
        let afterStart = document.offsetAt(Position(line: startLine, character: 0))
        let afterEnd = endLine + 1 < document.lineCount
            ? document.offsetAt(Position(line: endLine + 1, character: 0))
            : document.offsetAt(Position(line: endLine, character: document.getLineLength(endLine)))
        if afterEnd - afterStart > maxCaptureBytes { continue }
        let afterText = document.pieceTable.sliceUnits(afterStart, afterEnd)
        if utf8Count(afterText) > maxCaptureBytes { continue }
        guard let beforeText = applyEditsToSlice(afterText, afterStart, inverse),
              beforeText.count <= maxCaptureBytes, utf8Count(beforeText) <= maxCaptureBytes
        else { continue }
        let bounds = lineDiffBounds(beforeText, lineStarts(beforeText), afterText, lineStarts(afterText))
        return TransactionFragment(beforeText: beforeText, afterText: afterText, startOffset: afterStart, startLine: startLine, bounds: bounds)
    }
    return nil
}

/// Appends an edit to the prediction history, coalescing nearby quick
/// edits (`recordEditPrediction`). `at` is in milliseconds.
public func recordEditPrediction<A>(
    _ history: [EditPredictionHistoryRecord],
    path: String,
    document: TextDocument<A>,
    change: TextDocumentChange,
    source: EditPredictionSource,
    at: Double = Date().timeIntervalSince1970 * 1000
) -> [EditPredictionHistoryRecord] {
    var kept = Array(history.suffix(maxHistoryEntries))
    guard let fragment = captureTransaction(document, change) else {
        if var previous = kept.last, previous.fragment != nil {
            previous.fragment = nil
            kept[kept.count - 1] = previous
        }
        return kept
    }
    if fragment.beforeText == fragment.afterText { return kept }
    let changedStartLine = fragment.startLine + fragment.bounds.prefixLines
    let beforeChangedEndLine = fragment.startLine + fragment.bounds.oldLineCount - fragment.bounds.suffixLines
    let last = kept.last
    var gap = 0
    if let last {
        if changedStartLine > last.end {
            gap = changedStartLine - last.end
        } else if last.start > beforeChangedEndLine {
            gap = last.start - beforeChangedEndLine
        }
    }
    if let last, let previous = last.fragment, last.path == path, last.source == source, at - last.at < coalesceMilliseconds, gap <= coalesceLines {
        let beforeEnd = fragment.startOffset + fragment.beforeText.count
        let overlapStart = max(previous.currentStart, fragment.startOffset)
        let overlapEnd = min(previous.currentEnd, beforeEnd)
        if overlapStart <= overlapEnd,
           slice(previous.currentText, overlapStart - previous.currentStart, overlapEnd - previous.currentStart)
           .elementsEqual(slice(fragment.beforeText, overlapStart - fragment.startOffset, overlapEnd - fragment.startOffset))
        {
            let unionStart = min(previous.currentStart, fragment.startOffset)
            let currentText: [UInt16] = previous.currentStart <= fragment.startOffset
                ? previous.currentText + slice(fragment.beforeText, max(0, previous.currentEnd - fragment.startOffset), fragment.beforeText.count)
                : fragment.beforeText + slice(previous.currentText, max(0, beforeEnd - previous.currentStart), previous.currentText.count)
            let prefix = slice(currentText, 0, previous.currentStart - unionStart)
            let suffix = slice(currentText, previous.currentEnd - unionStart, currentText.count)
            let baseText = Array(prefix) + previous.baseText + Array(suffix)
            let nextText = applyEditsToSlice(currentText, unionStart, change.appliedEdits)
            let startLine = previous.currentStart <= fragment.startOffset ? previous.startLine : fragment.startLine
            if let nextText, baseText.count <= maxCaptureBytes, nextText.count <= maxCaptureBytes,
               utf8Count(baseText) <= maxCaptureBytes, utf8Count(nextText) <= maxCaptureBytes
            {
                if baseText == nextText {
                    kept.removeLast()
                    return kept
                }
                if let formatted = formatEditHunk(path, baseText, nextText, startLine) {
                    kept[kept.count - 1] = EditPredictionHistoryRecord(
                        path: path,
                        hunk: formatted.hunk,
                        start: startLine + formatted.bounds.prefixLines,
                        end: startLine + formatted.bounds.newLineCount - formatted.bounds.suffixLines,
                        at: at,
                        source: source,
                        fragment: HistoryFragment(baseText: baseText, currentText: nextText, currentStart: unionStart, currentEnd: unionStart + nextText.count, startLine: startLine)
                    )
                    return kept
                }
            }
        }
    }
    if var previous = kept.last, previous.fragment != nil {
        previous.fragment = nil
        kept[kept.count - 1] = previous
    }
    guard let formatted = formatEditHunk(path, fragment.beforeText, fragment.afterText, fragment.startLine) else { return kept }
    kept.append(EditPredictionHistoryRecord(
        path: path,
        hunk: formatted.hunk,
        start: changedStartLine,
        end: fragment.startLine + fragment.bounds.newLineCount - fragment.bounds.suffixLines,
        at: at,
        source: source,
        fragment: HistoryFragment(baseText: fragment.beforeText, currentText: fragment.afterText, currentStart: fragment.startOffset, currentEnd: fragment.startOffset + fragment.afterText.count, startLine: fragment.startLine)
    ))
    return Array(kept.suffix(maxHistoryEntries))
}

private func expandLinewise(_ lineCount: Int, _ costForLine: (Int) -> Int, _ canExpandTo: (Int) -> Bool, _ first: Int, _ last: Int, _ remaining: Int) -> (first: Int, last: Int) {
    var first = first
    var last = last
    var remaining = remaining
    while remaining > 0, first > 0 || last < lineCount - 1 {
        var expanded = false
        if first > 0, canExpandTo(first - 1) {
            let cost = costForLine(first - 1)
            if cost <= remaining {
                first -= 1
                remaining -= cost
                expanded = true
            }
        }
        if last < lineCount - 1, canExpandTo(last + 1) {
            let cost = costForLine(last + 1)
            if cost <= remaining {
                last += 1
                remaining -= cost
                expanded = true
            }
        }
        if !expanded { break }
    }
    return (first, last)
}

/// Builds the bounded request around the cursor
/// (`buildEditPredictionRequest`); nil when the cursor line is not editable
/// or the budgets are exceeded.
public func buildEditPredictionRequest<A>(
    path: String,
    document: TextDocument<A>,
    cursorOffset: Int,
    history: [EditPredictionHistoryRecord],
    isLineEditable: (Int) -> Bool
) -> EditPredictRequest? {
    if document.lineCount <= 0 { return nil }
    let lastLine = document.lineCount - 1
    let documentLength = document.offsetAt(Position(line: lastLine, character: document.getLineLength(lastLine)))
    var cursor = max(0, min(cursorOffset, documentLength))
    if cursor > 0, cursor < documentLength, let previous = document.unitAt(cursor - 1), let next = document.unitAt(cursor),
       (previous == 13 && next == 10) || (UTF16Text.isHighSurrogate(previous) && UTF16Text.isLowSurrogate(next))
    {
        cursor -= 1
    }
    let cursorLine = document.positionAt(cursor).line
    var editableCache: [Int: Bool] = [:]
    func canEdit(_ line: Int) -> Bool {
        if line < 0 || line >= document.lineCount { return false }
        if let cached = editableCache[line] { return cached }
        let value = isLineEditable(line)
        editableCache[line] = value
        return value
    }
    if !canEdit(cursorLine) { return nil }
    var costCache: [Int: Int] = [:]
    func costForLine(_ line: Int) -> Int {
        if let cached = costCache[line] { return cached }
        let length = document.getLineLength(line)
        let cost = length / 3 > maxContextTokens ? maxContextTokens + 1 : max(1, document.getLineText(line).utf8.count / 3)
        costCache[line] = cost
        return cost
    }
    var editableFirst = cursorLine
    var editableLast = cursorLine
    let initialBudget = editableTokens * 3 / 4
    var remaining = max(0, initialBudget - costForLine(cursorLine))
    while remaining > 0, canEdit(editableFirst - 1) || canEdit(editableLast + 1) {
        if canEdit(editableLast + 1) {
            let cost = costForLine(editableLast + 1)
            if cost > remaining { break }
            editableLast += 1
            remaining -= cost
        }
        if canEdit(editableFirst - 1), remaining > 0 {
            let cost = costForLine(editableFirst - 1)
            if cost > remaining { break }
            editableFirst -= 1
            remaining -= cost
        }
    }
    remaining += editableTokens - initialBudget
    (editableFirst, editableLast) = expandLinewise(document.lineCount, costForLine, canEdit, editableFirst, editableLast, remaining)
    let (contextFirst, contextLast) = expandLinewise(document.lineCount, costForLine, { _ in true }, editableFirst, editableLast, contextTokens)
    let editableTotal = (editableFirst ... editableLast).reduce(0) { $0 + costForLine($1) }
    let contextTotal = (contextFirst ... contextLast).reduce(0) { $0 + costForLine($1) }
    if editableTotal > maxEditableTokens || contextTotal > maxContextTokens { return nil }
    let contextStart = document.offsetAt(Position(line: contextFirst, character: 0))
    let contextEnd = document.offsetAt(Position(line: contextLast, character: document.getLineLength(contextLast)))
    let request = EditPredictRequest(
        path: path,
        version: document.version,
        eol: document.eol.rawValue,
        excerptText: document.getTextSlice(contextStart, contextEnd),
        excerptStartLine: contextFirst,
        cursorOffsetInExcerpt: cursor - contextStart,
        editableRange: .init(
            start: document.offsetAt(Position(line: editableFirst, character: 0)) - contextStart,
            end: document.offsetAt(Position(line: editableLast, character: document.getLineLength(editableLast))) - contextStart
        ),
        editHistory: history.suffix(maxHistoryEntries).map { .init(diff: $0.hunk, source: $0.source) }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let size = (try? encoder.encode(request).count) ?? .max
    return size <= maxRequestBytes ? request : nil
}

/// Glob (`?`, `*`, `**`) or regular expression path matching
/// (`matchesEditPredictionPattern`).
public func matchesEditPredictionPattern(_ path: String, _ pattern: EditPredictionPattern) -> Bool {
    switch pattern {
    case .regex(let regex):
        return regex.firstMatch(in: path, range: NSRange(location: 0, length: (path as NSString).length)) != nil
    case .glob(let glob):
        let characters = Array(glob.replacingOccurrences(of: "\\", with: "/"))
        var source = "^"
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*" {
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    index += 1
                    if index + 1 < characters.count, characters[index + 1] == "/" {
                        index += 1
                        source += "(?:.*/)?"
                    } else {
                        source += ".*"
                    }
                } else {
                    source += "[^/]*"
                }
            } else if character == "?" {
                source += "[^/]"
            } else if "\\^$.*+?()[]{}|".contains(character) {
                source += "\\\(character)"
            } else {
                source.append(character)
            }
            index += 1
        }
        guard let regex = try? NSRegularExpression(pattern: source + "$") else { return false }
        return regex.firstMatch(in: path, range: NSRange(location: 0, length: (path as NSString).length)) != nil
    }
}

public enum EditPredictionPattern: @unchecked Sendable {
    case glob(String)
    case regex(NSRegularExpression)
}
