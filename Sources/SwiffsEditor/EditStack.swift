// Port of `editor/editStack.ts`: undo/redo history with typing and delete
// coalescing.

import Foundation

/// One reversible document transaction (`EditHistoryEntry`).
public struct EditHistoryEntry<Annotation> {
    public var forwardEdits: [ResolvedTextEdit]
    public var inverseEdits: [ResolvedTextEdit]
    public var versionBefore: Int
    public var versionAfter: Int
    public var selectionsBefore: [EditorSelection]?
    public var selectionsAfter: [EditorSelection]?
    public var lineAnnotationsBefore: [Annotation]?
    public var lineAnnotationsAfter: [Annotation]?
    public var coalescingMode: EditHistoryCoalescingMode?
    public var undoBoundary: Bool?

    public init(
        forwardEdits: [ResolvedTextEdit],
        inverseEdits: [ResolvedTextEdit],
        versionBefore: Int,
        versionAfter: Int,
        selectionsBefore: [EditorSelection]? = nil,
        selectionsAfter: [EditorSelection]? = nil,
        lineAnnotationsBefore: [Annotation]? = nil,
        lineAnnotationsAfter: [Annotation]? = nil,
        coalescingMode: EditHistoryCoalescingMode? = nil,
        undoBoundary: Bool? = nil
    ) {
        self.forwardEdits = forwardEdits
        self.inverseEdits = inverseEdits
        self.versionBefore = versionBefore
        self.versionAfter = versionAfter
        self.selectionsBefore = selectionsBefore
        self.selectionsAfter = selectionsAfter
        self.lineAnnotationsBefore = lineAnnotationsBefore
        self.lineAnnotationsAfter = lineAnnotationsAfter
        self.coalescingMode = coalescingMode
        self.undoBoundary = undoBoundary
    }
}

/// Undo and redo history (`EditHistoryState`).
public struct EditHistoryState<Annotation> {
    public var undoStack: [EditHistoryEntry<Annotation>]
    public var redoStack: [EditHistoryEntry<Annotation>]
    public var maxEntries: Int
    public var canCoalesce: Bool
}

/// `EditStack`.
public final class EditStack<Annotation> {
    public static var defaultMaxEntries: Int { 100 }

    public private(set) var undoStack: [EditHistoryEntry<Annotation>] = []
    public private(set) var redoStack: [EditHistoryEntry<Annotation>] = []
    public let maxEntries: Int
    public private(set) var canCoalesce = false

    public init(maxEntries: Int? = nil) {
        self.maxEntries = max(1, maxEntries ?? Self.defaultMaxEntries)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public var state: EditHistoryState<Annotation> {
        EditHistoryState(undoStack: undoStack, redoStack: redoStack, maxEntries: maxEntries, canCoalesce: canCoalesce)
    }

    public static func fromState(_ state: EditHistoryState<Annotation>) -> EditStack<Annotation> {
        let stack = EditStack(maxEntries: state.maxEntries)
        stack.undoStack = state.undoStack
        stack.redoStack = state.redoStack
        stack.canCoalesce = state.canCoalesce
        return stack
    }

    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        canCoalesce = false
    }

    public func clearRedo() {
        redoStack.removeAll()
    }

    public func push(_ entry: EditHistoryEntry<Annotation>) {
        undoStack.append(entry)
        clearRedo()
        canCoalesce = true
        if undoStack.count > maxEntries {
            undoStack.removeFirst()
        }
    }

    public func setLastUndoSelectionsAfter(_ selections: [EditorSelection]) {
        guard !undoStack.isEmpty else { return }
        undoStack[undoStack.count - 1].selectionsAfter = selections
    }

    public func setLastUndoLineAnnotations(before: [Annotation], after: [Annotation]) {
        guard !undoStack.isEmpty else { return }
        undoStack[undoStack.count - 1].lineAnnotationsBefore = before
        undoStack[undoStack.count - 1].lineAnnotationsAfter = after
    }

    public func peekUndo() -> EditHistoryEntry<Annotation>? { undoStack.last }

    /// The last undo entry only while its coalescing group is open.
    public func peekUndoForCoalescing() -> EditHistoryEntry<Annotation>? {
        canCoalesce ? peekUndo() : nil
    }

    public func replaceLastUndo(_ entry: EditHistoryEntry<Annotation>) {
        if undoStack.isEmpty {
            push(entry)
            return
        }
        undoStack[undoStack.count - 1] = entry
        clearRedo()
        canCoalesce = true
    }

    public func popUndoToRedo() -> EditHistoryEntry<Annotation>? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(entry)
        canCoalesce = false
        return entry
    }

    public func popRedoToUndo() -> EditHistoryEntry<Annotation>? {
        guard let entry = redoStack.popLast() else { return nil }
        undoStack.append(entry)
        canCoalesce = false
        return entry
    }
}

/// Builds an entry with inverse edits read from the document before the
/// edits apply (`createEditStackEntry`).
func createEditStackEntry<Annotation>(
    _ document: TextDocument<Annotation>,
    _ resolvedEdits: [ResolvedTextEdit],
    versionBefore: Int,
    versionAfter: Int,
    selectionsBefore: [EditorSelection]? = nil,
    selectionsAfter: [EditorSelection]? = nil
) -> EditHistoryEntry<Annotation> {
    let forwardEdits = resolvedEdits.enumerated().sorted { a, b in
        a.element.start != b.element.start ? a.element.start < b.element.start : a.offset < b.offset
    }.map(\.element)
    var coalescingMode: EditHistoryCoalescingMode?
    if let selectionsBefore, selectionsBefore.count == forwardEdits.count {
        var caretOffsets: [Int] = []
        for selection in selectionsBefore {
            if selection.start != selection.end { break }
            caretOffsets.append(document.offsetAt(selection.start))
        }
        if caretOffsets.count == forwardEdits.count {
            caretOffsets.sort()
            var isBackspace = true
            var isDelete = true
            for (i, edit) in forwardEdits.enumerated() {
                if edit.textLength > 0 || edit.start == edit.end {
                    isBackspace = false
                    isDelete = false
                    break
                }
                isBackspace = isBackspace && caretOffsets[i] == edit.end
                isDelete = isDelete && caretOffsets[i] == edit.start
            }
            coalescingMode = isBackspace ? .backspace : isDelete ? .delete : nil
        }
    }
    var inverseEdits: [ResolvedTextEdit] = []
    var offsetDelta = 0
    for edit in forwardEdits {
        let replacedText = document.getTextSlice(edit.start, edit.end)
        let startAfterEdit = edit.start + offsetDelta
        inverseEdits.append(ResolvedTextEdit(start: startAfterEdit, end: startAfterEdit + edit.textLength, text: replacedText))
        offsetDelta += edit.textLength - (edit.end - edit.start)
    }
    return EditHistoryEntry(
        forwardEdits: forwardEdits,
        inverseEdits: inverseEdits,
        versionBefore: versionBefore,
        versionAfter: versionAfter,
        selectionsBefore: selectionsBefore,
        selectionsAfter: selectionsAfter,
        coalescingMode: coalescingMode
    )
}

private func containsLineFeed(_ text: String) -> Bool {
    text.utf16.contains(0x0A)
}

/// Whether `next` continues `previous` as typing, backspacing or forward
/// deleting (`shouldCoalesceEditStackEntry`).
func shouldCoalesceEditStackEntry<Annotation>(_ previous: EditHistoryEntry<Annotation>?, _ next: EditHistoryEntry<Annotation>) -> Bool {
    guard let previous,
          previous.undoBoundary != true,
          next.undoBoundary != true,
          !previous.forwardEdits.isEmpty,
          previous.forwardEdits.count == previous.inverseEdits.count,
          previous.forwardEdits.count == next.forwardEdits.count,
          next.forwardEdits.count == next.inverseEdits.count
    else { return false }
    var mode: EditHistoryCoalescingMode?
    for i in previous.forwardEdits.indices {
        let previousForward = previous.forwardEdits[i]
        let previousInverse = previous.inverseEdits[i]
        let nextForward = next.forwardEdits[i]
        let nextInverse = next.inverseEdits[i]
        let mappedNextStart = mapOffsetAfterForwardBatchToBefore(nextForward.start, previous.forwardEdits)
        let previousWasInsert = previousForward.start <= previousForward.end
            && previousForward.textLength > 0
            && !containsLineFeed(previousForward.text)
            && !containsLineFeed(previousInverse.text)
        let nextIsInsert = nextForward.start == nextForward.end
            && nextForward.textLength > 0
            && !containsLineFeed(nextForward.text)
            && nextInverse.textLength == 0
        if previousWasInsert, nextIsInsert {
            // Merge only when the next insert starts where the previous
            // inserted text ends (in after-edit offsets).
            if nextForward.start != previousInverse.end { return false }
            if mode == nil { mode = .insert }
            if mode != .insert
                || (previous.coalescingMode != nil && previous.coalescingMode != .insert)
                || (next.coalescingMode != nil && next.coalescingMode != .insert)
            {
                return false
            }
            continue
        }
        let previousWasDelete = previousForward.textLength == 0 && previousForward.end > previousForward.start && previousInverse.textLength > 0
        let nextIsDelete = nextForward.textLength == 0 && nextForward.end > nextForward.start && nextInverse.textLength > 0
        if previousWasDelete, nextIsDelete {
            let nextMode: EditHistoryCoalescingMode
            if mappedNextStart == previousForward.end {
                nextMode = .delete
            } else if mappedNextStart + (nextForward.end - nextForward.start) != previousForward.start {
                return false
            } else {
                nextMode = .backspace
            }
            if mode == nil { mode = nextMode }
            if mode != nextMode
                || (previous.coalescingMode != nil && previous.coalescingMode != nextMode)
                || (next.coalescingMode != nil && next.coalescingMode != nextMode)
            {
                return false
            }
            continue
        }
        return false
    }
    return mode != nil
}

/// Merges two coalescible entries (`coalesceEditStackEntries`).
func coalesceEditStackEntries<Annotation>(_ previous: EditHistoryEntry<Annotation>, _ next: EditHistoryEntry<Annotation>) -> EditHistoryEntry<Annotation> {
    var forwardEdits: [ResolvedTextEdit] = []
    var replacedTexts: [String] = []
    var coalescingMode: EditHistoryCoalescingMode?
    for i in previous.forwardEdits.indices {
        let previousForward = previous.forwardEdits[i]
        let previousInverse = previous.inverseEdits[i]
        let nextForward = next.forwardEdits[i]
        let nextInverse = next.inverseEdits[i]
        let mappedNextStart = mapOffsetAfterForwardBatchToBefore(nextForward.start, previous.forwardEdits)
        if previousForward.textLength > 0 {
            if coalescingMode == nil { coalescingMode = .insert }
            forwardEdits.append(ResolvedTextEdit(start: previousForward.start, end: previousForward.end, text: previousForward.text + nextForward.text))
            replacedTexts.append(previousInverse.text)
            continue
        }
        if mappedNextStart == previousForward.end {
            if coalescingMode == nil { coalescingMode = .delete }
            forwardEdits.append(ResolvedTextEdit(start: previousForward.start, end: mappedNextStart + (nextForward.end - nextForward.start), text: ""))
            replacedTexts.append(previousInverse.text + nextInverse.text)
            continue
        }
        if coalescingMode == nil { coalescingMode = .backspace }
        forwardEdits.append(ResolvedTextEdit(start: min(previousForward.start, mappedNextStart), end: previousForward.end, text: ""))
        replacedTexts.append(nextInverse.text + previousInverse.text)
    }
    return EditHistoryEntry(
        forwardEdits: forwardEdits,
        inverseEdits: buildInverseEditsFromReplacedTexts(forwardEdits, replacedTexts),
        versionBefore: previous.versionBefore,
        versionAfter: next.versionAfter,
        selectionsBefore: previous.selectionsBefore,
        selectionsAfter: next.selectionsAfter,
        lineAnnotationsBefore: previous.lineAnnotationsBefore,
        lineAnnotationsAfter: next.lineAnnotationsAfter,
        coalescingMode: coalescingMode
    )
}

private func buildInverseEditsFromReplacedTexts(_ forwardEdits: [ResolvedTextEdit], _ replacedTexts: [String]) -> [ResolvedTextEdit] {
    var inverseEdits: [ResolvedTextEdit] = []
    var offsetDelta = 0
    for (i, edit) in forwardEdits.enumerated() {
        let startAfterEdit = edit.start + offsetDelta
        inverseEdits.append(ResolvedTextEdit(start: startAfterEdit, end: startAfterEdit + edit.textLength, text: replacedTexts[i]))
        offsetDelta += edit.textLength - (edit.end - edit.start)
    }
    return inverseEdits
}

private func mapOffsetAfterForwardBatchToBefore(_ offsetAfter: Int, _ forwardEdits: [ResolvedTextEdit]) -> Int {
    var offset = offsetAfter
    for edit in forwardEdits {
        let oldLength = edit.end - edit.start
        let newLength = edit.textLength
        let delta = newLength - oldLength
        if offset < edit.start { continue }
        if offset >= edit.start + newLength {
            offset -= delta
            continue
        }
        offset = edit.start + min(offset - edit.start, oldLength)
    }
    return offset
}
