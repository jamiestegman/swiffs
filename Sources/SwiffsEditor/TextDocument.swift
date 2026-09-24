// Port of `editor/textDocument.ts`: a vscode-languageserver-textdocument
// compatible document over a piece table, with undo history.

import Foundation
import SwiffsCore

/// Result of applying edits (`TextDocumentChange`).
public struct TextDocumentChange: Hashable, Sendable {
    public struct LineChange: Hashable, Sendable {
        public var startLine: Int
        public var endLine: Int
        public var lineDelta: Int
        public var startCharacter: Int
        public var endCharacter: Int
        public var endedAtDocumentEnd: Bool
    }

    public var changes: [EditorChange]
    /// First line whose content or tokenizer state may have changed.
    public var startLine: Int
    public var startCharacter: Int
    public var endCharacter: Int
    /// Last line whose content may have changed after the edit.
    public var endLine: Int
    public var endedAtDocumentEnd: Bool
    public var previousLineCount: Int
    public var lineCount: Int
    public var lineDelta: Int
    /// Line ranges touched by the edits after they applied.
    public var changedLineRanges: [ClosedRange<Int>]
    public var changedLineChanges: [LineChange]
    /// Edits applied and their inverse (`TextDocumentChangeTransaction`).
    public var appliedEdits: [ResolvedTextEdit] = []
    public var inverseEdits: [ResolvedTextEdit] = []
}

/// Result of undo/redo: the change, the selections to restore (when the
/// entry recorded them), the line annotations, and otherwise the edits to
/// remap live selections with.
public struct TextDocumentHistoryResult<Annotation> {
    public var change: TextDocumentChange
    public var selections: [EditorSelection]?
    public var lineAnnotations: [Annotation]?
    public var selectionEdits: [ResolvedTextEdit]?
}

public final class TextDocument<Annotation> {
    public let uri: String
    public let languageId: String
    public private(set) var version: Int
    public let eol: EndOfLine
    let pieceTable: PieceTable
    let editStack: EditStack<Annotation>

    public init(
        uri: String,
        text: String,
        languageId: String = "text",
        version: Int = 0,
        editStack: EditStack<Annotation> = EditStack(),
        eol: EndOfLine? = nil
    ) {
        self.uri = URL(string: uri, relativeTo: URL(string: "file:///"))?.absoluteString ?? uri
        self.languageId = languageId
        self.version = version
        pieceTable = PieceTable(text)
        self.editStack = editStack
        if let eol {
            self.eol = eol
        } else {
            // Detected once from the first line; defaults to `\n`.
            let first = (try? pieceTable.getLineUnits(0, includeLineBreak: true)) ?? []
            if first.count >= 2, first[first.count - 2] == 0x0D, first[first.count - 1] == 0x0A {
                self.eol = .crlf
            } else if first.last == 0x0D {
                self.eol = .cr
            } else {
                self.eol = .lf
            }
        }
    }

    public var lineCount: Int { pieceTable.lineCount }
    /// UTF-16 length of the document.
    public var length: Int { pieceTable.length }
    public var history: EditHistoryState<Annotation> { editStack.state }
    public var canUndo: Bool { editStack.canUndo }
    public var canRedo: Bool { editStack.canRedo }

    public func clearHistory() {
        editStack.clear()
    }

    public func positionAt(_ offset: Int) -> Position {
        normalizePosition(pieceTable.positionAt(offset))
    }

    public func positionsAt(_ offsets: [Int]) -> [Position] {
        pieceTable.positionsAt(offsets).map(normalizePosition)
    }

    public func offsetAt(_ position: Position) -> Int {
        (try? pieceTable.offsetAt(normalizePosition(position))) ?? 0
    }

    public func getText() -> String {
        pieceTable.getText()
    }

    /// Text in a range, clamped to visible line content (a goal column past
    /// a line's end must not pull in its line break).
    public func getText(_ range: DocumentRange) -> String {
        (try? pieceTable.getText(DocumentRange(start: normalizePosition(range.start), end: normalizePosition(range.end)))) ?? ""
    }

    public func getLineText(_ line: Int, includeLineBreak: Bool = false) -> String {
        (try? pieceTable.getLineText(line, includeLineBreak: includeLineBreak)) ?? ""
    }

    public func getLineUnits(_ line: Int, includeLineBreak: Bool = false) -> [UInt16] {
        (try? pieceTable.getLineUnits(line, includeLineBreak: includeLineBreak)) ?? []
    }

    public func getLineLength(_ line: Int, includeLineBreak: Bool = false) -> Int {
        (try? pieceTable.getLineLength(line, includeLineBreak: includeLineBreak)) ?? 0
    }

    /// Rewrites every line break to the document's EOL (`normalizeEol`).
    public func normalizeEol(_ text: String) -> String {
        let units = Array(text.utf16)
        let eolUnits = Array(eol.rawValue.utf16)
        var result: [UInt16] = []
        result.reserveCapacity(units.count)
        var i = 0
        while i < units.count {
            let unit = units[i]
            if unit == 0x0D {
                result.append(contentsOf: eolUnits)
                if i + 1 < units.count, units[i + 1] == 0x0A { i += 1 }
            } else if unit == 0x0A {
                result.append(contentsOf: eolUnits)
            } else {
                result.append(unit)
            }
            i += 1
        }
        return UTF16Text.string(result)
    }

    public func charAt(_ offset: Int) -> String {
        pieceTable.charAt(offset)
    }

    public func charAt(_ position: Position) -> String {
        pieceTable.charAt(offsetAt(position))
    }

    public func unitAt(_ offset: Int) -> UInt16? {
        pieceTable.unitAt(offset)
    }

    public func getTextSlice(_ start: Int, _ end: Int) -> String {
        pieceTable.getTextSlice(start, end)
    }

    public func findNextNonOverlappingSubstring(_ needle: String, occupied: [(start: Int, end: Int)]) -> Int? {
        pieceTable.findNextNonOverlappingSubstring(needle, occupied: occupied)
    }

    public func search(_ params: SearchParams) -> [(start: Int, end: Int)] {
        pieceTable.search(params)
    }

    // MARK: Edits

    @discardableResult
    public func applyEdits(
        _ edits: [TextEdit],
        updateHistory: Bool = true,
        selectionsBefore: [EditorSelection]? = nil,
        selectionsAfter: [EditorSelection]? = nil,
        undoBoundary: Bool = false
    ) throws -> TextDocumentChange? {
        if edits.isEmpty { return nil }
        return try applyResolved(
            sortAndValidate(resolveEdits(edits)),
            updateHistory: updateHistory,
            selectionsBefore: selectionsBefore,
            selectionsAfter: selectionsAfter,
            undoBoundary: undoBoundary
        )
    }

    /// Converts ranges to UTF-16 offsets, widening boundaries so no edit
    /// splits a surrogate pair.
    public func resolveEdits(_ edits: [TextEdit]) -> [ResolvedTextEdit] {
        edits.map(resolveEdit)
    }

    @discardableResult
    public func applyResolvedEdits(
        _ edits: [ResolvedTextEdit],
        updateHistory: Bool = true,
        selectionsBefore: [EditorSelection]? = nil,
        selectionsAfter: [EditorSelection]? = nil,
        undoBoundary: Bool = false
    ) throws -> TextDocumentChange? {
        if edits.isEmpty { return nil }
        return try applyResolved(
            sortAndValidate(edits.map(normalizeResolvedEdit)),
            updateHistory: updateHistory,
            selectionsBefore: selectionsBefore,
            selectionsAfter: selectionsAfter,
            undoBoundary: undoBoundary
        )
    }

    /// Every edit joins the undo timeline; `updateHistory` only controls
    /// whether selections and the undo boundary are recorded.
    private func applyResolved(
        _ resolvedEdits: [ResolvedTextEdit],
        updateHistory: Bool,
        selectionsBefore: [EditorSelection]?,
        selectionsAfter: [EditorSelection]?,
        undoBoundary: Bool
    ) -> TextDocumentChange {
        var entry = createEditStackEntry(
            self,
            resolvedEdits,
            versionBefore: version,
            versionAfter: version + 1,
            selectionsBefore: updateHistory ? selectionsBefore : nil,
            selectionsAfter: updateHistory ? selectionsAfter : nil
        )
        if updateHistory, undoBoundary { entry.undoBoundary = true }
        let previousEntry = editStack.peekUndoForCoalescing()
        var change = applyToBuffer(resolvedEdits)
        version += 1
        if change.lineDelta == 0, shouldCoalesceEditStackEntry(previousEntry, entry), let previousEntry {
            editStack.replaceLastUndo(coalesceEditStackEntries(previousEntry, entry))
        } else {
            editStack.push(entry)
        }
        change.appliedEdits = entry.forwardEdits
        change.inverseEdits = entry.inverseEdits
        return change
    }

    public func setLastUndoSelectionsAfter(_ selections: [EditorSelection]) {
        editStack.setLastUndoSelectionsAfter(selections)
    }

    public func setLastUndoLineAnnotations(before: [Annotation], after: [Annotation]) {
        editStack.setLastUndoLineAnnotations(before: before, after: after)
    }

    public func undo() -> TextDocumentHistoryResult<Annotation>? {
        guard let entry = editStack.popUndoToRedo() else { return nil }
        var change = applyToBuffer(entry.inverseEdits)
        change.appliedEdits = entry.inverseEdits
        change.inverseEdits = entry.forwardEdits
        version = entry.versionBefore
        let selections = entry.selectionsBefore
        return TextDocumentHistoryResult(
            change: change,
            selections: selections,
            lineAnnotations: entry.lineAnnotationsBefore,
            selectionEdits: selections == nil ? entry.inverseEdits : nil
        )
    }

    public func redo() -> TextDocumentHistoryResult<Annotation>? {
        guard let entry = editStack.popRedoToUndo() else { return nil }
        var change = applyToBuffer(entry.forwardEdits)
        change.appliedEdits = entry.forwardEdits
        change.inverseEdits = entry.inverseEdits
        version = entry.versionAfter
        let selections = entry.selectionsAfter
        return TextDocumentHistoryResult(
            change: change,
            selections: selections,
            lineAnnotations: entry.lineAnnotationsAfter,
            selectionEdits: selections == nil ? entry.forwardEdits : nil
        )
    }

    public func normalizePosition(_ position: Position) -> Position {
        let line = max(0, min(position.line, lineCount - 1))
        return Position(line: line, character: max(0, min(position.character, getLineLength(line))))
    }

    private func resolveEdit(_ edit: TextEdit) -> ResolvedTextEdit {
        var start = offsetAt(edit.range.start)
        var end = offsetAt(edit.range.end)
        if start > end { swap(&start, &end) }
        return normalizeResolvedEdit(ResolvedTextEdit(start: start, end: end, text: edit.newText))
    }

    /// Snaps insertions before a surrogate pair and widens replacements
    /// outward so every edit addresses whole pairs.
    private func normalizeResolvedEdit(_ edit: ResolvedTextEdit) -> ResolvedTextEdit {
        var start = edit.start
        var end = edit.end
        let isInsertion = start == end
        if isInsideSurrogatePair(start) { start -= 1 }
        if isInsertion {
            end = start
        } else if isInsideSurrogatePair(end) {
            end += 1
        }
        return ResolvedTextEdit(start: start, end: end, text: edit.text)
    }

    private func isInsideSurrogatePair(_ offset: Int) -> Bool {
        guard let previous = pieceTable.unitAt(offset - 1), let next = pieceTable.unitAt(offset) else { return false }
        return UTF16Text.isHighSurrogate(previous) && UTF16Text.isLowSurrogate(next)
    }

    /// Zero-width edits sort before ranges at the same start (a stable sort,
    /// like `Array.prototype.sort`).
    private func sortAndValidate(_ edits: [ResolvedTextEdit]) throws -> [ResolvedTextEdit] {
        let sorted = edits.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            if a.element.end != b.element.end { return a.element.end < b.element.end }
            return a.offset < b.offset
        }.map(\.element)
        for i in 0 ..< max(0, sorted.count - 1) where sorted[i].end > sorted[i + 1].start {
            throw DiffsError("Overlapping text edits are not supported")
        }
        return sorted
    }

    private func applyToBuffer(_ edits: [ResolvedTextEdit]) -> TextDocumentChange {
        let previousLineCount = pieceTable.lineCount
        let editPositions = positionsAt(edits.flatMap { [$0.start, $0.end] })
        let changed = computeChangedLineRange(edits, editPositions)
        let startPosition = editPositions.first ?? Position(line: 0, character: 0)
        let endPosition = editPositions.last ?? Position(line: 0, character: 0)
        let endedAtDocumentEnd = endPosition.line == previousLineCount - 1 && endPosition.character == getLineLength(endPosition.line)
        pieceTable.applyEdits(edits)
        let lineCount = pieceTable.lineCount
        return TextDocumentChange(
            changes: edits.enumerated().map { index, edit in
                EditorChange(start: edit.start, end: edit.end, text: edit.text, range: DocumentRange(start: editPositions[index * 2], end: editPositions[index * 2 + 1]))
            },
            startLine: changed.startLine,
            startCharacter: startPosition.character,
            endCharacter: endPosition.character,
            endLine: min(changed.endLine, max(0, lineCount - 1)),
            endedAtDocumentEnd: endedAtDocumentEnd,
            previousLineCount: previousLineCount,
            lineCount: lineCount,
            lineDelta: lineCount - previousLineCount,
            changedLineRanges: changed.ranges,
            changedLineChanges: changed.changes
        )
    }

    private func computeChangedLineRange(_ edits: [ResolvedTextEdit], _ positions: [Position]) -> (startLine: Int, endLine: Int, ranges: [ClosedRange<Int>], changes: [TextDocumentChange.LineChange]) {
        var startLine = Int.max
        var endLine = 0
        var lineDeltaBeforeEdit = 0
        var ranges: [ClosedRange<Int>] = []
        var changes: [TextDocumentChange.LineChange] = []
        let previousLastLine = pieceTable.lineCount - 1
        let previousLastLineLength = getLineLength(previousLastLine)
        for (i, edit) in edits.enumerated() {
            let editStart = positions[i * 2]
            let editEnd = positions[i * 2 + 1]
            let insertedLineSpan = countLineBreaks(edit.text)
            let changedStartLine = editStart.line + lineDeltaBeforeEdit
            let changedEndLine = changedStartLine + insertedLineSpan
            let lineDelta = insertedLineSpan - (editEnd.line - editStart.line)
            startLine = min(startLine, editStart.line)
            endLine = max(endLine, changedEndLine)
            if let last = ranges.last, changedStartLine <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound ... max(last.upperBound, changedEndLine)
            } else {
                ranges.append(changedStartLine ... changedEndLine)
            }
            changes.append(TextDocumentChange.LineChange(
                startLine: changedStartLine,
                endLine: changedEndLine,
                lineDelta: lineDelta,
                startCharacter: editStart.character,
                endCharacter: editEnd.character,
                endedAtDocumentEnd: editEnd.line == previousLastLine && editEnd.character == previousLastLineLength
            ))
            lineDeltaBeforeEdit += lineDelta
        }
        if startLine == Int.max {
            return (0, 0, [0 ... 0], [TextDocumentChange.LineChange(startLine: 0, endLine: 0, lineDelta: 0, startCharacter: 0, endCharacter: 0, endedAtDocumentEnd: false)])
        }
        return (startLine, endLine, ranges, changes)
    }
}
