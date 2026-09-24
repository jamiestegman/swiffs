// Port of the document logic in `editor/selection.ts`: caret motion,
// multi-selection edits, deletion commands, clipboard regions and selection
// algebra. (The DOM range mapping lives in the view layer.)

import Foundation
import SwiffsCore

private let surroundingPairs: [(String, String)] = [
    ("'", "'"), ("\"", "\""), ("`", "`"), ("{", "}"), ("[", "]"), ("<", ">"), ("(", ")"),
]
private let autoSurroundCloseChars = Dictionary(surroundingPairs, uniquingKeysWith: { a, _ in a })
private let autoSurroundQuoteChars: Set<String> = ["'", "\"", "`"]
private let autoSurroundBracketChars: Set<String> = ["{", "[", "(", "<"]

/// Result of a selection edit command.
public struct SelectionEditResult: Sendable {
    public var nextSelections: [EditorSelection]
    public var change: TextDocumentChange?
}

/// Line annotations updated by an edit, when any moved.
public struct AnnotatedSelectionEditResult<Annotation> {
    public var nextSelections: [EditorSelection]
    public var change: TextDocumentChange?
    public var lineAnnotations: [Annotation]?
}

extension Never: EditorLineAnnotationPosition {
    public var lineNumber: Int {
        get { fatalError() }
        set {}
    }

    public var annotationSide: AnnotationSide? { fatalError() }
}

/// Caret motion options (`CursorMoveOptions`).
public struct CursorMoveOptions {
    /// Soft (wrapped) line start offsets of a document line, ending with the
    /// line length.
    public var getSoftLineOffsets: ((Int) -> [Int]?)?
    /// The nearest renderable line at or beyond a line in a direction (fold
    /// skipping); nil when everything that way is hidden.
    public var resolveRenderableLine: ((Int, VerticalDirection) -> Int?)?

    public init(getSoftLineOffsets: ((Int) -> [Int]?)? = nil, resolveRenderableLine: ((Int, VerticalDirection) -> Int?)? = nil) {
        self.getSoftLineOffsets = getSoftLineOffsets
        self.resolveRenderableLine = resolveRenderableLine
    }
}

public enum VerticalDirection: Sendable {
    case up, down
}

/// Caret motions (`'textStart' | 'start' | 'end' | 'up' | 'down' | 'left' | 'right'`).
public enum CursorMove: String, Sendable {
    case textStart, start, end, up, down, left, right
}

private struct SoftLineInfo {
    var start: Int
    var end: Int
    var index: Int
    var count: Int
}

// MARK: - Indentation

/// Indent or outdent the lines of a selection (`resolveIndentEdits`).
public func resolveIndentEdits<A>(_ document: TextDocument<A>, _ selection: EditorSelection, tabSize: Int, outdent: Bool) -> (edits: [TextEdit], nextSelection: EditorSelection) {
    let start = selection.start
    let end = selection.end
    var edits: [TextEdit] = []
    var newSelection = selection
    let blockIndent = start.line != end.line
    var endLine = end.line
    if start.line < end.line, end.character == 0 { endLine -= 1 }
    var line = start.line
    while line <= endLine {
        defer { line += 1 }
        let lineText = document.getLineUnits(line)
        if blockIndent, jsTrimmed(lineText).isEmpty { continue }
        let startsWithTab = lineText.first == 0x09
        let indentUnit = startsWithTab ? "\t" : String(repeating: " ", count: tabSize)
        var deleteLength = 0
        var newText = indentUnit
        if outdent {
            if startsWithTab {
                deleteLength = 1
            } else if lineText.first == 0x20 {
                let leading = lineText.count - jsTrimStart(lineText).count
                deleteLength = min(indentUnit.utf16.count, leading)
            }
            if deleteLength == 0 { continue }
            newText = ""
        }
        edits.append(TextEdit(range: DocumentRange(start: Position(line: line, character: 0), end: Position(line: line, character: deleteLength)), newText: newText))
        let delta = newText.utf16.count - deleteLength
        if line == start.line {
            newSelection.start = Position(line: start.line, character: max(0, start.character + delta))
        }
        if line == end.line {
            newSelection.end = Position(line: end.line, character: max(0, end.character + delta))
        }
    }
    return (edits, newSelection)
}

// MARK: - Caret motion

/// Moves every selection's caret (`mapCursorMove`).
public func mapCursorMove<A>(_ document: TextDocument<A>, _ selections: [EditorSelection], _ shortcut: CursorMove, options: CursorMoveOptions = CursorMoveOptions()) -> [EditorSelection] {
    let lineCount = document.lineCount
    return selections.map { selection in
        var position = shortcut == .up || shortcut == .left ? selection.start : selection.end
        var line = position.line
        var character = position.character
        switch shortcut {
        case .textStart, .start, .end:
            let caret = getCaretPosition(selection)
            line = caret.line
            character = caret.character
            let softLine = getSoftLineInfo(document, line, character, options)
            if shortcut == .textStart {
                let lineUnits = document.getLineUnits(line)
                let softText = Array(lineUnits[clamp(softLine.start, 0, lineUnits.count) ..< clamp(softLine.end, clamp(softLine.start, 0, lineUnits.count), lineUnits.count)])
                let indent = softLine.start + getLeadingSpaces(softText)
                character = character == indent ? softLine.start : indent
            } else {
                character = shortcut == .start ? softLine.start : softLine.end
            }
        case .up:
            if let moved = moveBySoftLine(document, line, character, -1, options) {
                line = moved.line
                character = moved.character
            } else if line > 0 {
                line = options.resolveRenderableLine.map { $0(line - 1, .up) ?? line } ?? (line - 1)
            }
        case .down:
            if let moved = moveBySoftLine(document, line, character, 1, options) {
                line = moved.line
                character = moved.character
            } else {
                let maxLine = max(lineCount - 1, 0)
                if line < maxLine {
                    line = options.resolveRenderableLine.map { min($0(line + 1, .down) ?? line, maxLine) } ?? (line + 1)
                }
            }
        case .left, .right:
            guard isCollapsedSelection(selection) else { break }
            let lineLength = document.getLineLength(line)
            character = min(character, lineLength)
            if shortcut == .left {
                if character > 0 {
                    character = stepCharacterByGrapheme(document, line, character, forward: false)
                } else if line > 0 {
                    let target = options.resolveRenderableLine.map { $0(line - 1, .up) } ?? (line - 1)
                    if let target {
                        line = target
                        character = document.getLineLength(line)
                    }
                }
            } else if character < lineLength {
                character = stepCharacterByGrapheme(document, line, character, forward: true)
            } else if line < lineCount - 1 {
                let target = options.resolveRenderableLine.map { $0(line + 1, .down) } ?? (line + 1)
                if let target {
                    line = min(target, lineCount - 1)
                    character = 0
                }
            }
        }
        position = Position(line: line, character: character)
        return EditorSelection(start: position, end: position, direction: .none)
    }
}

private func moveBySoftLine<A>(_ document: TextDocument<A>, _ line: Int, _ character: Int, _ direction: Int, _ options: CursorMoveOptions) -> Position? {
    guard options.getSoftLineOffsets != nil else { return nil }
    let current = getSoftLineInfo(document, line, character, options)
    let targetIndex = current.index + direction
    var targetLine = line
    let target: SoftLineInfo
    if targetIndex >= 0, targetIndex < current.count {
        target = getSoftLineInfoAtIndex(document, targetLine, targetIndex, options)
    } else {
        let nextLine = line + direction
        if nextLine < 0 || nextLine >= document.lineCount {
            return Position(line: line, character: character)
        }
        let resolved = options.resolveRenderableLine.map { $0(nextLine, direction < 0 ? .up : .down) } ?? nextLine
        guard let resolved else { return Position(line: line, character: character) }
        targetLine = min(resolved, document.lineCount - 1)
        let targetCount = getSoftLineCount(targetLine, options)
        target = getSoftLineInfoAtIndex(document, targetLine, direction < 0 ? targetCount - 1 : 0, options)
    }
    let column = max(0, character - current.start)
    let targetCharacter = target.start + column
    let landed = target.index == target.count - 1 ? targetCharacter : min(targetCharacter, target.end)
    let targetLineUnits = document.getLineUnits(targetLine)
    // Keep goal-column overshoots, but snap real offsets out of graphemes.
    return Position(
        line: targetLine,
        character: landed > targetLineUnits.count ? landed : snapCharacterToGraphemeBoundary(targetLineUnits, landed)
    )
}

/// Snaps a position to the end of its grapheme so edits cannot split a
/// user-visible character (`snapCharacterToGraphemeBoundary`).
public func snapCharacterToGraphemeBoundary(_ lineText: String, _ character: Int) -> Int {
    snapCharacterToGraphemeBoundary(Array(lineText.utf16), character)
}

func snapCharacterToGraphemeBoundary(_ units: [UInt16], _ character: Int) -> Int {
    if character <= 0 || character >= units.count { return character }
    var index = 0
    for grapheme in UTF16Text.string(units) {
        if character <= index { return character }
        let end = index + grapheme.utf16.count
        if character < end { return end }
        index = end
    }
    return character
}

private func getSoftLineInfo<A>(_ document: TextDocument<A>, _ line: Int, _ character: Int, _ options: CursorMoveOptions) -> SoftLineInfo {
    let lineLength = document.getLineLength(line)
    guard let offsets = options.getSoftLineOffsets?(line), offsets.count >= 2 else {
        return SoftLineInfo(start: 0, end: lineLength, index: 0, count: 1)
    }
    var index = 0
    while index + 1 < offsets.count {
        let softLine = getSoftLineInfoAtIndex(document, line, index, options)
        if character >= softLine.start, character <= softLine.end { return softLine }
        index += 1
    }
    return getSoftLineInfoAtIndex(document, line, character < (offsets.first ?? 0) ? 0 : offsets.count - 2, options)
}

private func getSoftLineCount(_ line: Int, _ options: CursorMoveOptions) -> Int {
    guard let offsets = options.getSoftLineOffsets?(line), offsets.count >= 2 else { return 1 }
    return offsets.count - 1
}

private func getSoftLineInfoAtIndex<A>(_ document: TextDocument<A>, _ line: Int, _ index: Int, _ options: CursorMoveOptions) -> SoftLineInfo {
    let lineLength = document.getLineLength(line)
    guard let offsets = options.getSoftLineOffsets?(line), offsets.count >= 2 else {
        return SoftLineInfo(start: 0, end: lineLength, index: 0, count: 1)
    }
    let count = offsets.count - 1
    let bounded = max(0, min(index, count - 1))
    let start = max(0, min(lineLength, offsets[bounded]))
    let end = max(start, min(lineLength, bounded + 1 < offsets.count ? offsets[bounded + 1] : lineLength))
    return SoftLineInfo(start: start, end: end, index: bounded, count: count)
}

/// `mapCursorMove` with shift: extends the selections (`mapSelectionShift`).
public func mapSelectionShift<A>(_ document: TextDocument<A>, _ selections: [EditorSelection], _ shortcut: CursorMove, options: CursorMoveOptions = CursorMoveOptions()) -> [EditorSelection] {
    selections.map { selection in
        let focus = selection.direction == .backward ? selection.start : selection.end
        let moved = mapCursorMove(document, [EditorSelection(start: focus, end: focus, direction: .none)], shortcut, options: options)[0]
        return createSelectionFrom(selection, moved)
    }
}

// MARK: - Text edits

private struct OrderedEntry {
    var index: Int
    var start: Int
    var end: Int
}

private func orderedEntries<A>(_ document: TextDocument<A>, _ selections: [EditorSelection]) -> [OrderedEntry] {
    var ordered: [OrderedEntry] = []
    var isOrdered = true
    for (index, selection) in selections.enumerated() {
        let entry = OrderedEntry(index: index, start: document.offsetAt(selection.start), end: document.offsetAt(selection.end))
        if let previous = ordered.last, entry.start < previous.start || (entry.start == previous.start && entry.end < previous.end) {
            isOrdered = false
        }
        ordered.append(entry)
    }
    if !isOrdered {
        ordered.sort { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end < b.end }
            return a.index < b.index
        }
    }
    return ordered
}

private func finishEdit<A: EditorLineAnnotationPosition>(
    _ document: TextDocument<A>,
    _ change: TextDocumentChange?,
    _ nextSelections: [EditorSelection],
    _ lineAnnotations: [A]?
) -> AnnotatedSelectionEditResult<A> {
    document.setLastUndoSelectionsAfter(nextSelections)
    var moved: [A]?
    if let change, let lineAnnotations {
        moved = applyDocumentChangeToLineAnnotations(change, lineAnnotations)
        if let moved {
            document.setLastUndoLineAnnotations(before: lineAnnotations, after: moved)
        }
    }
    return AnnotatedSelectionEditResult(nextSelections: nextSelections, change: change, lineAnnotations: moved)
}

/// Applies a text change made at the primary (last) selection to every
/// selection (`applyTextChangeToSelections`).
@discardableResult
public func applyTextChangeToSelections<A: EditorLineAnnotationPosition>(
    _ document: TextDocument<A>,
    _ selections: [EditorSelection],
    _ edit: ResolvedTextEdit,
    lineAnnotations: [A]? = nil,
    tabSize: Int = 2,
    undoBoundary: Bool = false
) throws -> AnnotatedSelectionEditResult<A> {
    guard let primary = selections.last else {
        return AnnotatedSelectionEditResult(nextSelections: [], change: nil, lineAnnotations: nil)
    }
    let primaryStart = document.offsetAt(primary.start)
    let primaryEnd = document.offsetAt(primary.end)
    let ordered = orderedEntries(document, selections)
    let adjusted = normalizeLeadingIndentForChange(document, edit, tabSize)
    var edits: [ResolvedTextEdit] = []
    var nextOffsets = [(Int, Int)?](repeating: nil, count: selections.count)
    var offsetDelta = 0
    var group: (start: Int, end: Int, indices: [Int])?
    func finalizeGroup() {
        guard let current = group else { return }
        let perGroup = normalizeLeadingIndentForChange(document, ResolvedTextEdit(start: current.start, end: current.end, text: adjusted.text), tabSize)
        let newText = expandSingleNewlineInsert(document, perGroup.text, perGroup.start)
        let newLength = newText.utf16.count
        edits.append(ResolvedTextEdit(start: perGroup.start, end: perGroup.end, text: newText))
        let next = (current.start + offsetDelta + newLength, current.start + offsetDelta + newLength)
        for index in current.indices { nextOffsets[index] = next }
        offsetDelta += newLength - (perGroup.end - perGroup.start)
        group = nil
    }
    for entry in ordered {
        let startOffset = max(0, entry.start + (adjusted.start - primaryStart))
        let endOffset = max(startOffset, entry.end + (adjusted.end - primaryEnd))
        if let current = group, startOffset < current.end {
            group!.end = max(current.end, endOffset)
            group!.indices.append(entry.index)
            continue
        }
        finalizeGroup()
        group = (startOffset, endOffset, [entry.index])
    }
    finalizeGroup()
    let change = try document.applyResolvedEdits(edits, updateHistory: true, selectionsBefore: selections, undoBoundary: undoBoundary)
    let nextSelections = createSelectionsFromOffsetPairs(document, nextOffsets.map { $0! })
    return finishEdit(document, change, nextSelections, lineAnnotations)
}

/// Exact auto-surround replacements keep the inner range selected.
private func getAutoSurroundPreservedOffset(_ original: [UInt16], _ newText: [UInt16]) -> Int? {
    guard newText.count == original.count + 2, let first = newText.first else { return nil }
    guard let close = autoSurroundCloseChars[UTF16Text.string([first])],
          UTF16Text.string([newText[newText.count - 1]]) == close,
          Array(newText[1 ..< newText.count - 1]) == original
    else { return nil }
    return 1
}

private func getNextSelectionOffsetPairAfterReplace<A>(_ document: TextDocument<A>, _ entry: OrderedEntry, _ offsetDelta: Int, _ newText: String) -> (Int, Int) {
    let newUnits = Array(newText.utf16)
    let insertStart = entry.start + offsetDelta
    let insertEnd = insertStart + newUnits.count
    if entry.end - entry.start > 0 {
        let original = Array(document.getTextSlice(entry.start, entry.end).utf16)
        let preserved = getAutoSurroundPreservedOffset(original, newUnits) ?? indexOf(newUnits, original)
        if preserved != -1, preserved + original.count <= newUnits.count {
            let rangeStart = insertStart + preserved
            return (rangeStart, rangeStart + original.count)
        }
    }
    return (insertEnd, insertEnd)
}

/// Replaces each selection with a text (`applyTextReplaceToSelections`).
/// Texts pair by selection index unless `documentOrder` is set.
@discardableResult
public func applyTextReplaceToSelections<A: EditorLineAnnotationPosition>(
    _ document: TextDocument<A>,
    _ selections: [EditorSelection],
    _ texts: [String],
    lineAnnotations: [A]? = nil,
    undoBoundary: Bool = false,
    documentOrder: Bool = false
) throws -> AnnotatedSelectionEditResult<A> {
    if selections.count != texts.count {
        throw DiffsError("Selection text replacements must match the selection count")
    }
    let ordered = orderedEntries(document, selections)
    var edits: [ResolvedTextEdit] = []
    var nextPairs = [(Int, Int)?](repeating: nil, count: selections.count)
    if texts.allSatisfy(\.isEmpty) {
        var hasEffect = false
        for entry in ordered {
            nextPairs[entry.index] = (entry.end, entry.end)
            if entry.start >= entry.end { continue }
            hasEffect = true
            if let last = edits.last, entry.start < last.end {
                edits[edits.count - 1] = ResolvedTextEdit(start: last.start, end: max(last.end, entry.end), text: "")
            } else {
                edits.append(ResolvedTextEdit(start: entry.start, end: entry.end, text: ""))
            }
        }
        if !hasEffect {
            return AnnotatedSelectionEditResult(nextSelections: selections, change: nil, lineAnnotations: nil)
        }
        for entry in ordered {
            let caret = entry.end
            var delta = 0
            var next = caret
            for edit in edits {
                if caret <= edit.start { break }
                if caret >= edit.end {
                    delta -= edit.end - edit.start
                    continue
                }
                next = edit.start + delta
                break
            }
            if next == caret { next += delta }
            nextPairs[entry.index] = (next, next)
        }
    } else {
        var offsetDelta = 0
        var previousEditEnd = -1
        for (index, entry) in ordered.enumerated() {
            if entry.start < previousEditEnd {
                throw DiffsError("Overlapping multi-selection edits are not supported")
            }
            previousEditEnd = entry.end
            let newText = expandSingleNewlineInsert(document, texts[documentOrder ? index : entry.index], entry.start)
            edits.append(ResolvedTextEdit(start: entry.start, end: entry.end, text: newText))
            nextPairs[entry.index] = getNextSelectionOffsetPairAfterReplace(document, entry, offsetDelta, newText)
            offsetDelta += newText.utf16.count - (entry.end - entry.start)
        }
    }
    let change = try document.applyResolvedEdits(edits, updateHistory: true, selectionsBefore: selections, undoBoundary: undoBoundary)
    let nextSelections = createSelectionsFromOffsetPairs(document, nextPairs.map { $0! })
    return finishEdit(document, change, nextSelections, lineAnnotations)
}

/// Auto-surround behavior (`AutoSurround`).
public enum AutoSurround: String, Sendable {
    case `default`, never, brackets, quotes, languageDefined
}

private func shouldAutoSurroundChar(_ autoSurround: AutoSurround?, _ char: String) -> Bool {
    switch autoSurround {
    case .never: return false
    case .brackets: return autoSurroundBracketChars.contains(char)
    case .quotes: return autoSurroundQuoteChars.contains(char)
    default: return true
    }
}

/// Replacement texts when typing a surround character over non-collapsed
/// selections (`getAutoSurroundReplacementTexts`).
public func getAutoSurroundReplacementTexts<A>(_ document: TextDocument<A>, _ selections: [EditorSelection], _ char: String, autoSurround: AutoSurround? = nil) -> [String]? {
    guard char.utf16.count == 1, !selections.isEmpty, let close = autoSurroundCloseChars[char], shouldAutoSurroundChar(autoSurround, char) else {
        return nil
    }
    var replacements: [String] = []
    for selection in selections {
        if isCollapsedSelection(selection) { return nil }
        replacements.append(char + document.getText(selection.range) + close)
    }
    return replacements
}

private func slice(_ units: [UInt16], _ start: Int, _ end: Int) -> [UInt16] {
    let lower = clamp(start, 0, units.count)
    let upper = clamp(end, lower, units.count)
    return Array(units[lower ..< upper])
}

/// Swaps the graphemes around each collapsed caret (Ctrl+T,
/// `applyTransposeToSelections`).
@discardableResult
public func applyTransposeToSelections<A: EditorLineAnnotationPosition>(
    _ document: TextDocument<A>,
    _ selections: [EditorSelection],
    lineAnnotations: [A]? = nil
) throws -> AnnotatedSelectionEditResult<A> {
    var edits: [ResolvedTextEdit] = []
    var nextPairs: [(Int, Int)] = []
    for selection in selections {
        let (anchor, focus) = getSelectionAnchorAndFocusOffsets(document, selection)
        if !isCollapsedSelection(selection) {
            nextPairs.append((anchor, focus))
            continue
        }
        let line = selection.start.line
        let character = selection.start.character
        let offset = anchor
        let lineText = document.getLineUnits(line)
        let lineLength = lineText.count
        let lineStart = offset - character
        let starts = getLineGraphemeStarts(lineText)
        let edit: ResolvedTextEdit
        if character > 0, character < lineLength {
            let before = findClusterBreak(lineText, character, forward: false, starts)
            let after = findClusterBreak(lineText, character, forward: true, starts)
            edit = ResolvedTextEdit(start: lineStart + before, end: lineStart + after, text: UTF16Text.string(slice(lineText, character, after) + slice(lineText, before, character)))
            nextPairs.append((lineStart + after, lineStart + after))
        } else if character == lineLength, starts.count >= 2 {
            let lastStart = starts[starts.count - 1]
            let secondLast = starts[starts.count - 2]
            edit = ResolvedTextEdit(start: lineStart + secondLast, end: offset, text: UTF16Text.string(slice(lineText, lastStart, lineLength) + slice(lineText, secondLast, lastStart)))
            nextPairs.append((offset, offset))
        } else if character == 0, line > 0, lineLength > 0 {
            let prevLine = line - 1
            let prevText = document.getLineUnits(prevLine)
            let prevLength = prevText.count
            let prevEnd = document.offsetAt(Position(line: prevLine, character: prevLength))
            let prevGraphemeStart = prevLength > 0 ? findClusterBreak(prevText, prevLength, forward: false, getLineGraphemeStarts(prevText)) : prevLength
            let firstEnd = findClusterBreak(lineText, 0, forward: true, starts)
            let prevStart = prevEnd - (prevLength - prevGraphemeStart)
            let newText = UTF16Text.string(slice(lineText, 0, firstEnd)) + document.getTextSlice(prevEnd, offset) + UTF16Text.string(slice(prevText, prevGraphemeStart, prevLength))
            edit = ResolvedTextEdit(start: prevStart, end: offset + firstEnd, text: newText)
            let caret = prevStart + newText.utf16.count
            nextPairs.append((caret, caret))
        } else {
            nextPairs.append((anchor, focus))
            continue
        }
        edits.append(edit)
    }
    if edits.isEmpty {
        return AnnotatedSelectionEditResult(nextSelections: selections, change: nil, lineAnnotations: nil)
    }
    edits = edits.enumerated().sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }.map(\.element)
    for index in 1 ..< max(1, edits.count) where edits[index].start < edits[index - 1].end {
        throw DiffsError("Overlapping multi-selection edits are not supported")
    }
    let change = try document.applyResolvedEdits(edits, updateHistory: true, selectionsBefore: selections)
    return finishEdit(document, change, createSelectionsFromOffsetPairs(document, nextPairs), lineAnnotations)
}

/// Deletes to the end of each line, or the line break at a line's end
/// (`applyDeleteHardLineForwardToSelections`).
@discardableResult
public func applyDeleteHardLineForwardToSelections<A: EditorLineAnnotationPosition>(_ document: TextDocument<A>, _ selections: [EditorSelection], lineAnnotations: [A]? = nil) throws -> AnnotatedSelectionEditResult<A> {
    let deletes = selections.map { selection -> EditorSelection in
        let range = resolveDeleteHardLineForwardRange(document, selection)
        return EditorSelection(start: range.start, end: range.end, direction: .none)
    }
    return try applyTextReplaceToSelections(document, deletes, deletes.map { _ in "" }, lineAnnotations: lineAnnotations)
}

/// Deletes back to the start of each soft line
/// (`applyDeleteSoftLineBackwardToSelections`).
@discardableResult
public func applyDeleteSoftLineBackwardToSelections<A: EditorLineAnnotationPosition>(
    _ document: TextDocument<A>,
    _ selections: [EditorSelection],
    getSoftLineStart: ((Int, Int) -> Int)? = nil,
    lineAnnotations: [A]? = nil
) throws -> AnnotatedSelectionEditResult<A> {
    let deletes = selections.map { selection -> EditorSelection in
        if !isCollapsedSelection(selection) {
            return EditorSelection(start: selection.start, end: selection.end, direction: .none)
        }
        let caret = getCaretPosition(selection)
        let softLineStart = getSoftLineStart?(caret.line, caret.character) ?? 0
        if caret.character > softLineStart {
            return EditorSelection(start: Position(line: caret.line, character: softLineStart), end: caret, direction: .none)
        }
        if caret.line == 0 {
            return EditorSelection(start: caret, end: caret, direction: .none)
        }
        let prevLength = document.getLineLength(caret.line - 1)
        return EditorSelection(start: Position(line: caret.line - 1, character: prevLength), end: Position(line: caret.line, character: 0), direction: .none)
    }
    return try applyTextReplaceToSelections(document, deletes, deletes.map { _ in "" }, lineAnnotations: lineAnnotations)
}

/// Deletes the word or separator group before each caret
/// (`applyDeleteWordBackwardToSelections`).
@discardableResult
public func applyDeleteWordBackwardToSelections<A: EditorLineAnnotationPosition>(_ document: TextDocument<A>, _ selections: [EditorSelection], lineAnnotations: [A]? = nil) throws -> AnnotatedSelectionEditResult<A> {
    let deletes = selections.map { selection -> EditorSelection in
        let (start, end) = resolveDeleteWordBackwardRange(document, selection)
        return EditorSelection(start: start, end: end, direction: .none)
    }
    return try applyTextReplaceToSelections(document, deletes, deletes.map { _ in "" }, lineAnnotations: lineAnnotations)
}

/// The range Backspace or Delete removes at a caret
/// (`resolveDeleteCharacterRange`).
public func resolveDeleteCharacterRange<A>(_ document: TextDocument<A>, _ selection: EditorSelection, forward: Bool) -> (Position, Position) {
    if !isCollapsedSelection(selection) { return (selection.start, selection.end) }
    let caret = getCaretPosition(selection)
    let line = caret.line
    let lineLength = document.getLineLength(line)
    let lineCount = document.lineCount
    let character = min(caret.character, lineLength)
    if forward {
        if character < lineLength {
            return (Position(line: line, character: character), Position(line: line, character: stepCharacterByGrapheme(document, line, character, forward: true)))
        }
        if line < lineCount - 1 {
            return (Position(line: line, character: lineLength), Position(line: line + 1, character: 0))
        }
        return (caret, caret)
    }
    if character > 0 {
        return (Position(line: line, character: stepCharacterByGrapheme(document, line, character, forward: false)), Position(line: line, character: character))
    }
    if line > 0 {
        return (Position(line: line - 1, character: document.getLineLength(line - 1)), Position(line: line, character: 0))
    }
    return (caret, caret)
}

/// Deletes one grapheme (or the selected text) at each selection
/// (`applyDeleteCharacterToSelections`).
@discardableResult
public func applyDeleteCharacterToSelections<A: EditorLineAnnotationPosition>(
    _ document: TextDocument<A>,
    _ selections: [EditorSelection],
    forward: Bool,
    lineAnnotations: [A]? = nil,
    tabSize: Int = 2
) throws -> AnnotatedSelectionEditResult<A> {
    let deletes = selections.map { selection -> EditorSelection in
        var (start, end) = resolveDeleteCharacterRange(document, selection, forward: forward)
        // Only a collapsed Backspace grows into a whole soft tab.
        if !forward, isCollapsedSelection(selection) {
            let normalized = normalizeLeadingIndentForChange(document, ResolvedTextEdit(start: document.offsetAt(start), end: document.offsetAt(end), text: ""), tabSize)
            start = document.positionAt(normalized.start)
            end = document.positionAt(normalized.end)
        }
        return EditorSelection(start: start, end: end, direction: .none)
    }
    return try applyTextReplaceToSelections(document, deletes, deletes.map { _ in "" }, lineAnnotations: lineAnnotations)
}

// MARK: - Selection algebra

public func isCollapsedSelection(_ selection: EditorSelection) -> Bool {
    selection.start == selection.end
}

public func isCollapsedRange(_ range: DocumentRange) -> Bool {
    range.start == range.end
}

/// The caret (focus) of a selection (`getCaretPosition`).
public func getCaretPosition(_ selection: EditorSelection) -> Position {
    selection.direction == .backward ? selection.start : selection.end
}

/// Whether a line type accepts edits (`isLineEditable`).
public func isLineEditable(_ lineType: LineType) -> Bool {
    lineType == .context || lineType == .contextExpanded || lineType == .changeAddition
}

public func comparePosition(_ a: Position, _ b: Position) -> Int {
    a.line != b.line ? a.line - b.line : a.character - b.character
}

/// Whether two selections intersect (`selectionIntersects`).
public func selectionIntersects(_ a: DocumentRange, _ b: DocumentRange) -> Bool {
    let aCollapsed = isCollapsedRange(a)
    let bCollapsed = isCollapsedRange(b)
    if aCollapsed, bCollapsed { return comparePosition(a.start, b.start) == 0 }
    if aCollapsed { return comparePosition(b.start, a.start) <= 0 && comparePosition(a.start, b.end) <= 0 }
    if bCollapsed { return comparePosition(a.start, b.start) <= 0 && comparePosition(b.start, a.end) <= 0 }
    return comparePosition(a.start, b.end) < 0 && comparePosition(b.start, a.end) < 0
}

public func createSelectionFromAnchorAndFocusOffsets<A>(_ document: TextDocument<A>, _ anchor: Int, _ focus: Int) -> EditorSelection {
    let direction: SelectionDirection = anchor == focus ? .none : anchor < focus ? .forward : .backward
    return EditorSelection(start: document.positionAt(min(anchor, focus)), end: document.positionAt(max(anchor, focus)), direction: direction)
}

/// Maps a pre-edit offset through sorted edits with right gravity
/// (`remapOffsetThroughEdits`).
public func remapOffsetThroughEdits(_ offset: Int, _ edits: [ResolvedTextEdit]) -> Int {
    var delta = 0
    for edit in edits {
        if offset < edit.start { break }
        if offset >= edit.end {
            delta += edit.textLength - (edit.end - edit.start)
        } else {
            return edit.start + delta + edit.textLength
        }
    }
    return offset + delta
}

/// Re-anchors selections after edits (`remapSelectionsAfterEdits`).
public func remapSelectionsAfterEdits<A>(_ document: TextDocument<A>, _ selections: [EditorSelection], _ selectionOffsets: [(Int, Int)], _ edits: [ResolvedTextEdit]) -> [EditorSelection] {
    selections.enumerated().map { index, selection in
        let (start, end) = selectionOffsets[index]
        let nextStart = remapOffsetThroughEdits(start, edits)
        let nextEnd = remapOffsetThroughEdits(end, edits)
        let backward = selection.direction == .backward
        return createSelectionFromAnchorAndFocusOffsets(document, backward ? nextEnd : nextStart, backward ? nextStart : nextEnd)
    }
}

/// A selection from an anchor selection to a focus selection
/// (`createSelectionFrom`).
public func createSelectionFrom(_ anchorSelection: EditorSelection, _ focusSelection: EditorSelection) -> EditorSelection {
    let anchor = anchorSelection.direction == .backward ? anchorSelection.end : anchorSelection.start
    let startOrder = comparePosition(anchor, focusSelection.start)
    let endOrder = comparePosition(anchor, focusSelection.end)
    let focus: Position
    if startOrder <= 0 {
        focus = focusSelection.end
    } else if endOrder >= 0 {
        focus = focusSelection.start
    } else {
        focus = startOrder == 0 ? focusSelection.end : focusSelection.start
    }
    let order = comparePosition(anchor, focus)
    let direction: SelectionDirection = order == 0 ? .none : order < 0 ? .forward : .backward
    return EditorSelection(start: order <= 0 ? anchor : focus, end: order <= 0 ? focus : anchor, direction: direction)
}

/// Shift-click extension (`extendSelection`).
public func extendSelection(_ original: EditorSelection, _ target: EditorSelection) -> EditorSelection {
    let leftExtended = comparePosition(target.start, original.start) < 0
    let rightExtended = comparePosition(target.end, original.end) > 0
    if leftExtended, !rightExtended {
        return EditorSelection(start: target.start, end: original.end, direction: .backward)
    }
    if rightExtended, !leftExtended {
        return EditorSelection(start: original.start, end: target.end, direction: .forward)
    }
    if original.direction == .backward {
        return EditorSelection(start: target.start, end: original.end, direction: comparePosition(target.start, original.end) == 0 ? .none : .backward)
    }
    return EditorSelection(start: original.start, end: target.end, direction: comparePosition(original.start, target.end) == 0 ? .none : .forward)
}

public func extendSelections(_ selections: [EditorSelection], _ target: EditorSelection) -> [EditorSelection] {
    mergeOverlappingSelections(selections.map { extendSelection($0, target) })
}

/// Merges intersecting selections, keeping the latest one's direction
/// (`mergeOverlappingSelections`).
public func mergeOverlappingSelections(_ selections: [EditorSelection]) -> [EditorSelection] {
    if selections.count <= 1 { return selections }
    let ordered = selections.enumerated().map { (index: $0.offset, selection: $0.element) }.sorted { a, b in
        let s = comparePosition(a.selection.start, b.selection.start)
        if s != 0 { return s < 0 }
        let e = comparePosition(a.selection.end, b.selection.end)
        return e != 0 ? e < 0 : a.index < b.index
    }
    var merged: [(index: Int, selection: EditorSelection)] = []
    var current = ordered[0]
    for entry in ordered.dropFirst() {
        if selectionIntersects(current.selection.range, entry.selection.range) {
            let latest = entry.index > current.index ? entry : current
            let start = comparePosition(entry.selection.start, current.selection.start) < 0 ? entry.selection.start : current.selection.start
            let end = comparePosition(entry.selection.end, current.selection.end) > 0 ? entry.selection.end : current.selection.end
            var direction = latest.selection.direction
            if direction == .none, comparePosition(start, end) != 0 {
                direction = comparePosition(latest.selection.start, start) == 0 ? .backward : .forward
            }
            current = (latest.index, EditorSelection(start: start, end: end, direction: direction))
            continue
        }
        merged.append(current)
        current = entry
    }
    merged.append(current)
    return merged.sorted { $0.index < $1.index }.map(\.selection)
}

/// Merged line blocks for line commands (`getSelectedLineBlocks`).
public func getSelectedLineBlocks(_ selections: [EditorSelection]) -> [(startLine: Int, endLine: Int)] {
    let blocks = selections.map { selection -> (startLine: Int, endLine: Int) in
        var endLine = selection.end.line
        if selection.end.character == 0, comparePosition(selection.start, selection.end) != 0 { endLine -= 1 }
        return (selection.start.line, max(selection.start.line, endLine))
    }.enumerated().sorted { a, b in
        if a.element.startLine != b.element.startLine { return a.element.startLine < b.element.startLine }
        if a.element.endLine != b.element.endLine { return a.element.endLine < b.element.endLine }
        return a.offset < b.offset
    }.map(\.element)
    var merged: [(startLine: Int, endLine: Int)] = []
    for block in blocks {
        if let previous = merged.last, block.startLine <= previous.endLine + 1 {
            merged[merged.count - 1].endLine = max(previous.endLine, block.endLine)
        } else {
            merged.append(block)
        }
    }
    return merged
}

/// Moves a selection's lines by one, clamped (`shiftSelectionLines`).
public func shiftSelectionLines(_ selection: EditorSelection, direction: Int, lineCount: Int, getLineLength: (Int) -> Int) -> EditorSelection {
    func shift(_ position: Position) -> Position {
        let line = position.line + direction
        if line >= lineCount {
            let last = max(0, lineCount - 1)
            return Position(line: last, character: getLineLength(last))
        }
        if line < 0 { return Position(line: 0, character: 0) }
        return Position(line: line, character: position.character)
    }
    return EditorSelection(start: shift(selection.start), end: shift(selection.end), direction: selection.direction)
}

/// Adds the next occurrence of the selected text (Cmd+D, `findNextMatch`).
public func findNextMatch<A>(_ document: TextDocument<A>, _ selections: [EditorSelection]) -> [EditorSelection]? {
    if selections.isEmpty { return nil }
    let normalized = selections.map { isCollapsedSelection($0) ? expandCollapsedSelectionToWord(document, $0) : $0 }
    let texts = normalized.map { document.getText($0.range) }
    let needle = texts[0]
    if needle.isEmpty || texts.contains(where: { !$0.utf16.elementsEqual(needle.utf16) }) { return nil }
    let occupied = normalized.map { (start: document.offsetAt($0.start), end: document.offsetAt($0.end)) }
    guard let next = document.findNextNonOverlappingSubstring(needle, occupied: occupied) else {
        let changed = zip(normalized, selections).contains { $0 != $1 }
        return changed ? normalized : nil
    }
    return normalized + [createSelectionFromAnchorAndFocusOffsets(document, next, next + needle.utf16.count)]
}

public func getDocumentFullSelection<A>(_ document: TextDocument<A>) -> EditorSelection {
    let lastLine = document.lineCount - 1
    return EditorSelection(start: Position(line: 0, character: 0), end: Position(line: lastLine, character: document.getLineLength(lastLine)), direction: .forward)
}

public func getDocumentBoundarySelection<A>(_ document: TextDocument<A>, atEnd: Bool, trimmedEndNewLine: Bool = false) -> EditorSelection {
    var line = 0
    if atEnd {
        let lastLine = document.lineCount - 1
        let trailingBlank = trimmedEndNewLine && lastLine > 0 && document.getLineLength(lastLine) == 0
        line = trailingBlank ? lastLine - 1 : lastLine
    }
    let position = Position(line: line, character: atEnd ? document.getLineLength(line) : 0)
    return EditorSelection(start: position, end: position, direction: .forward)
}

// MARK: - Clipboard

private func resolveClipboardRegion<A>(_ document: TextDocument<A>, _ selection: EditorSelection) -> (start: Int, end: Int) {
    if isCollapsedSelection(selection) {
        let line = selection.start.line
        let start = document.offsetAt(Position(line: line, character: 0))
        let end = line < document.lineCount - 1
            ? document.offsetAt(Position(line: line + 1, character: 0))
            : document.offsetAt(Position(line: line, character: document.getLineLength(line)))
        return (start, end)
    }
    let start = document.offsetAt(selection.start)
    let end = document.offsetAt(selection.end)
    return start <= end ? (start, end) : (end, start)
}

private func resolveClipboardRegions<A>(_ document: TextDocument<A>, _ selections: [EditorSelection]) -> [(start: Int, end: Int)] {
    selections.map { resolveClipboardRegion(document, $0) }.enumerated().sorted { a, b in
        if a.element.start != b.element.start { return a.element.start < b.element.start }
        if a.element.end != b.element.end { return a.element.end < b.element.end }
        return a.offset < b.offset
    }.map(\.element)
}

/// Per-selection clipboard texts in document order
/// (`getSelectionClipboardTexts`).
public func getSelectionClipboardTexts<A>(_ document: TextDocument<A>, _ selections: [EditorSelection]) -> [String] {
    resolveClipboardRegions(document, selections).map { document.getTextSlice($0.start, $0.end) }
}

/// Copy/cut text: collapsed carets copy their whole line; overlapping
/// regions merge (`getSelectionText`).
public func getSelectionText<A>(_ document: TextDocument<A>, _ selections: [EditorSelection]) -> String {
    var result = ""
    var prevEnd = -1
    for region in resolveClipboardRegions(document, selections) {
        if region.end <= region.start { continue }
        if region.start <= prevEnd {
            if region.end > prevEnd {
                result += document.getTextSlice(prevEnd, region.end)
                prevEnd = region.end
            }
            continue
        }
        if !result.isEmpty, !endsWithLineBreak(result) {
            result += document.eol.rawValue
        }
        result += document.getTextSlice(region.start, region.end)
        prevEnd = region.end
    }
    return result
}

func endsWithLineBreak(_ text: String) -> Bool {
    guard let last = text.utf16.last else { return false }
    return last == 0x0A || last == 0x0D
}

private func resolveSelectionCutEdit<A>(_ document: TextDocument<A>, _ selection: EditorSelection) -> ResolvedTextEdit {
    if isCollapsedSelection(selection) {
        let line = selection.start.line
        let lineStart = document.offsetAt(Position(line: line, character: 0))
        let lineEnd = document.offsetAt(Position(line: line, character: document.getLineLength(line)))
        if line < document.lineCount - 1 {
            return ResolvedTextEdit(start: lineStart, end: document.offsetAt(Position(line: line + 1, character: 0)), text: "")
        }
        if line > 0 {
            let previousEnd = document.offsetAt(Position(line: line - 1, character: document.getLineLength(line - 1)))
            return ResolvedTextEdit(start: previousEnd, end: lineEnd, text: "")
        }
        return ResolvedTextEdit(start: lineStart, end: lineEnd, text: "")
    }
    let ordered = comparePosition(selection.start, selection.end) <= 0
    let start = ordered ? selection.start : selection.end
    let end = ordered ? selection.end : selection.start
    return ResolvedTextEdit(start: document.offsetAt(start), end: document.offsetAt(end), text: "")
}

/// Clipboard text, merged deletions and caret offsets for a cut
/// (`resolveSelectionCut`).
public func resolveSelectionCut<A>(_ document: TextDocument<A>, _ selections: [EditorSelection]) -> (text: String, edits: [ResolvedTextEdit], nextSelectionOffsets: [Int]) {
    let cuts = selections.enumerated().map { (index: $0.offset, edit: resolveSelectionCutEdit(document, $0.element)) }
    let orderedCuts = cuts.sorted { a, b in
        if a.edit.start != b.edit.start { return a.edit.start < b.edit.start }
        if a.edit.end != b.edit.end { return a.edit.end < b.edit.end }
        return a.index < b.index
    }
    var edits: [ResolvedTextEdit] = []
    for cut in orderedCuts where cut.edit.start < cut.edit.end {
        if let last = edits.last, cut.edit.start <= last.end {
            edits[edits.count - 1] = ResolvedTextEdit(start: last.start, end: max(last.end, cut.edit.end), text: "")
        } else {
            edits.append(cut.edit)
        }
    }
    var nextOffsets = [Int](repeating: 0, count: orderedCuts.count)
    var editIndex = 0
    var offsetDelta = 0
    for cut in orderedCuts {
        while editIndex < edits.count, cut.edit.start > edits[editIndex].end {
            offsetDelta -= edits[editIndex].end - edits[editIndex].start
            editIndex += 1
        }
        if editIndex < edits.count, cut.edit.start >= edits[editIndex].start, cut.edit.start <= edits[editIndex].end {
            nextOffsets[cut.index] = edits[editIndex].start + offsetDelta
        } else {
            nextOffsets[cut.index] = cut.edit.start + offsetDelta
        }
    }
    return (getSelectionText(document, selections), edits, nextOffsets)
}

// MARK: - Words and graphemes

/// Expands a caret to the word it touches (`expandCollapsedSelectionToWord`).
public func expandCollapsedSelectionToWord<A>(_ document: TextDocument<A>, _ selection: EditorSelection) -> EditorSelection {
    let line = selection.start.line
    let lineText = document.getLineUnits(line)
    let ch = max(0, min(selection.start.character, lineText.count))
    guard let span = expandCollapsedLineWord(lineText, ch) else { return selection }
    return EditorSelection(start: Position(line: line, character: span.start), end: Position(line: line, character: span.end), direction: .forward)
}

/// Word-like segments (ICU word boundaries, like `Intl.Segmenter` with
/// `isWordLike`).
func wordLikeSegments(_ units: [UInt16]) -> [(start: Int, end: Int)] {
    let string = UTF16Text.string(units) as NSString
    var segments: [(start: Int, end: Int)] = []
    string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byWords, .substringNotRequired]) { _, range, _, _ in
        segments.append((range.location, range.location + range.length))
    }
    return segments
}

private func expandCollapsedLineWord(_ units: [UInt16], _ character: Int) -> (start: Int, end: Int)? {
    for segment in wordLikeSegments(units) where character >= segment.start && character <= segment.end {
        return segment
    }
    return nil
}

private func resolveDeleteWordBackwardRange<A>(_ document: TextDocument<A>, _ selection: EditorSelection) -> (Position, Position) {
    if !isCollapsedSelection(selection) { return (selection.start, selection.end) }
    let caret = getCaretPosition(selection)
    let line = caret.line
    let head = caret.character
    if head == 0 {
        if line == 0 { return (caret, caret) }
        return (Position(line: line - 1, character: document.getLineLength(line - 1)), Position(line: line, character: 0))
    }
    let lineText = document.getLineUnits(line)
    let starts = getLineGraphemeStarts(lineText)
    var pos = head
    var match: Int?
    while pos > 0 {
        let prev = findClusterBreak(lineText, pos, forward: false, starts)
        let nextChar = UTF16Text.string(slice(lineText, prev, pos))
        let nextMatch: Int
        if !nextChar.unicodeScalars.contains(where: { !isJSWhitespace($0) }) {
            nextMatch = 0
        } else if nextChar.unicodeScalars.contains(where: { $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "_" }) {
            nextMatch = 1
        } else {
            nextMatch = 2
        }
        if let match, nextMatch != match { break }
        if nextMatch != 0 || pos != head { match = nextMatch }
        pos = prev
    }
    return (Position(line: line, character: pos), Position(line: line, character: head))
}

private func findClusterBreak(_ units: [UInt16], _ pos: Int, forward: Bool, _ starts: [Int]) -> Int {
    if forward {
        for start in starts where start > pos { return start }
        return units.count
    }
    for start in starts.reversed() where start < pos { return start }
    return 0
}

/// Start column of every grapheme cluster on a line (always including 0).
func getLineGraphemeStarts(_ units: [UInt16]) -> [Int] {
    var starts = [0]
    var index = 0
    for grapheme in UTF16Text.string(units) {
        if index > 0 { starts.append(index) }
        index += grapheme.utf16.count
    }
    return starts
}

/// One grapheme left or right of a column (`stepCharacterByGrapheme`).
func stepCharacterByGrapheme<A>(_ document: TextDocument<A>, _ line: Int, _ character: Int, forward: Bool) -> Int {
    let lineLength = document.getLineLength(line)
    let lineStart = document.offsetAt(Position(line: line, character: 0))
    if forward {
        if character >= lineLength { return lineLength }
        let suffix = document.getTextSlice(lineStart + character, lineStart + lineLength)
        if let first = suffix.first { return character + first.utf16.count }
        return lineLength
    }
    if character <= 0 { return 0 }
    let prefix = document.getTextSlice(lineStart, lineStart + character)
    var previousStart = 0
    var index = 0
    for grapheme in prefix {
        previousStart = index
        index += grapheme.utf16.count
    }
    return previousStart
}

private func getSelectionAnchorAndFocusOffsets<A>(_ document: TextDocument<A>, _ selection: EditorSelection) -> (Int, Int) {
    let backward = selection.direction == .backward
    return (document.offsetAt(backward ? selection.end : selection.start), document.offsetAt(getCaretPosition(selection)))
}

private func resolveDeleteHardLineForwardRange<A>(_ document: TextDocument<A>, _ selection: EditorSelection) -> DocumentRange {
    if !isCollapsedSelection(selection) { return selection.range }
    let line = selection.start.line
    let character = selection.start.character
    let lineLength = document.getLineLength(line)
    if character < lineLength {
        return DocumentRange(start: selection.start, end: Position(line: line, character: lineLength))
    }
    if line < document.lineCount - 1 {
        return DocumentRange(start: selection.start, end: Position(line: line + 1, character: 0))
    }
    return DocumentRange(start: selection.start, end: selection.start)
}

/// A lone line break copies the current line's indentation
/// (`expandSingleNewlineInsert`).
private func expandSingleNewlineInsert<A>(_ document: TextDocument<A>, _ insertText: String, _ insertStart: Int) -> String {
    guard insertText == "\n" || insertText == "\r" || insertText == "\r\n" else { return insertText }
    let line = document.positionAt(insertStart).line
    let lineText = document.getLineUnits(line)
    let indent = getLeadingSpaces(lineText)
    if indent == 0 { return insertText }
    return insertText + UTF16Text.string(lineText[0 ..< indent])
}

private func getLeadingSpaces(_ units: [UInt16]) -> Int {
    var indent = 0
    while indent < units.count, units[indent] == 0x20 || units[indent] == 0x09 { indent += 1 }
    return indent
}

private func createSelectionsFromOffsetPairs<A>(_ document: TextDocument<A>, _ pairs: [(Int, Int)]) -> [EditorSelection] {
    let positions = document.positionsAt(pairs.flatMap { [min($0.0, $0.1), max($0.0, $0.1)] })
    return pairs.enumerated().map { index, pair in
        let direction: SelectionDirection = pair.0 == pair.1 ? .none : pair.0 < pair.1 ? .forward : .backward
        return EditorSelection(start: positions[index * 2], end: positions[index * 2 + 1], direction: direction)
    }
}

/// Grows a Backspace over leading spaces into one soft tab
/// (`normalizeLeadingIndentForChange`).
private func normalizeLeadingIndentForChange<A>(_ document: TextDocument<A>, _ change: ResolvedTextEdit, _ tabSize: Int) -> ResolvedTextEdit {
    guard change.text.isEmpty, change.start == change.end - 1 else { return change }
    let caret = document.positionAt(change.end)
    if caret.character == 0 { return change }
    let lineText = document.getLineUnits(caret.line)
    let leading = slice(lineText, 0, caret.character)
    if leading.contains(where: { $0 != 0x20 && $0 != 0x09 }) { return change }
    if caret.character - 1 < lineText.count, lineText[caret.character - 1] == 0x09 { return change }
    let softTabStart = max(0, caret.character - tabSize)
    let softTab = slice(lineText, softTabStart, caret.character)
    if softTab.count == tabSize, !softTab.isEmpty, softTab.allSatisfy({ $0 == 0x20 }) {
        return ResolvedTextEdit(start: change.end - softTab.count, end: change.end, text: change.text)
    }
    return change
}

// MARK: - JS string helpers

/// ECMAScript `WhiteSpace` and `LineTerminator`.
func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000 ... 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
        return true
    default:
        return false
    }
}

private func isJSWhitespaceUnit(_ unit: UInt16) -> Bool {
    Unicode.Scalar(unit).map(isJSWhitespace) ?? false
}

/// `String.prototype.trim` over UTF-16 units.
func jsTrimmed(_ units: [UInt16]) -> ArraySlice<UInt16> {
    guard let first = units.firstIndex(where: { !isJSWhitespaceUnit($0) }), let last = units.lastIndex(where: { !isJSWhitespaceUnit($0) }) else {
        return []
    }
    return units[first ... last]
}

/// `String.prototype.trimStart` over UTF-16 units.
func jsTrimStart(_ units: [UInt16]) -> ArraySlice<UInt16> {
    guard let first = units.firstIndex(where: { !isJSWhitespaceUnit($0) }) else { return [] }
    return units[first...]
}

/// `String.prototype.indexOf` over UTF-16 units.
func indexOf(_ haystack: [UInt16], _ needle: [UInt16]) -> Int {
    if needle.isEmpty { return 0 }
    if needle.count > haystack.count { return -1 }
    for start in 0 ... (haystack.count - needle.count) where haystack[start] == needle[0] {
        if haystack[start ..< start + needle.count].elementsEqual(needle) { return start }
    }
    return -1
}
