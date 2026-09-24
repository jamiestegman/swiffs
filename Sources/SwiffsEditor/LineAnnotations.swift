// Port of the line mapping in `editor/lineAnnotations.ts`: keeps line
// annotations attached to their lines as the document is edited.

import Foundation
import SwiffsCore

/// An annotation positioned on a line (`LineAnnotationPosition`).
public protocol EditorLineAnnotationPosition {
    var lineNumber: Int { get set }
    /// Deletion-side annotations are never repositioned.
    var annotationSide: AnnotationSide? { get }
}

extension LineAnnotation: EditorLineAnnotationPosition {
    public var annotationSide: AnnotationSide? { nil }
}

extension DiffLineAnnotation: EditorLineAnnotationPosition {
    public var annotationSide: AnnotationSide? { side }
}

private struct LineAnnotationChange {
    var startLine: Int
    var startCharacter: Int
    var endLine: Int
    var deletesEndLine: Bool
    var insertedLineBreaks: Int
    var lineDelta: Int
}

/// Remaps annotations through a document change; nil when nothing moved
/// (`applyDocumentChangeToLineAnnotations`).
public func applyDocumentChangeToLineAnnotations<A: EditorLineAnnotationPosition>(_ change: TextDocumentChange, _ lineAnnotations: [A]) -> [A]? {
    let annotationChanges = getLineAnnotationChanges(change)
    if annotationChanges.isEmpty { return nil }
    var next: [A] = []
    var changed = false
    for annotation in lineAnnotations {
        if annotation.annotationSide == .deletions || annotation.lineNumber <= 0 {
            next.append(annotation)
            continue
        }
        var line: Int? = annotation.lineNumber - 1
        var lineCount = change.previousLineCount
        var annotationChanged = false
        for lineChange in annotationChanges {
            guard let current = line else { break }
            let nextLineCount = max(1, lineCount + lineChange.lineDelta)
            guard let nextLine = mapLineThroughLineChange(current, lineChange, nextLineCount) else {
                annotationChanged = true
                line = nil
                break
            }
            if nextLine != current || lineChangeTouchesAnnotationLine(current, lineChange) {
                annotationChanged = true
            }
            line = nextLine
            lineCount = nextLineCount
        }
        guard let line else {
            changed = true
            continue
        }
        let lineNumber = line + 1
        if annotationChanged {
            var moved = annotation
            moved.lineNumber = lineNumber
            next.append(moved)
            changed = true
            continue
        }
        next.append(annotation)
    }
    return changed ? next : nil
}

private func getLineAnnotationChanges(_ change: TextDocumentChange) -> [LineAnnotationChange] {
    if !change.changedLineChanges.isEmpty {
        return change.changedLineChanges.compactMap { lineChange in
            if lineChange.lineDelta == 0 { return nil }
            let insertedLineBreaks = max(0, lineChange.endLine - lineChange.startLine)
            let removedLineCount = max(0, insertedLineBreaks - lineChange.lineDelta)
            return LineAnnotationChange(
                startLine: lineChange.startLine,
                startCharacter: lineChange.startCharacter,
                endLine: lineChange.startLine + removedLineCount,
                deletesEndLine: lineChange.lineDelta < 0 && lineChange.endedAtDocumentEnd,
                insertedLineBreaks: insertedLineBreaks,
                lineDelta: lineChange.lineDelta
            )
        }
    }
    if change.lineDelta == 0 {
        return change.changedLineRanges.compactMap { range in
            let inserted = range.upperBound - range.lowerBound
            if inserted <= 0 { return nil }
            return LineAnnotationChange(startLine: range.lowerBound, startCharacter: 0, endLine: range.lowerBound, deletesEndLine: false, insertedLineBreaks: inserted, lineDelta: inserted)
        }
    }
    let removedLineCount = max(0, -change.lineDelta)
    let deletedToDocumentEnd = change.endedAtDocumentEnd && change.startLine + removedLineCount == change.previousLineCount - 1
    return [LineAnnotationChange(
        startLine: change.startLine,
        startCharacter: change.startCharacter,
        endLine: change.startLine + removedLineCount,
        deletesEndLine: deletedToDocumentEnd,
        insertedLineBreaks: max(0, change.lineDelta),
        lineDelta: change.lineDelta
    )]
}

private func mapLineThroughLineChange(_ line: Int, _ change: LineAnnotationChange, _ nextLineCount: Int) -> Int? {
    if line < change.startLine { return line }
    if line > change.endLine || (change.endLine > change.startLine && line == change.endLine && !change.deletesEndLine) {
        return line + change.lineDelta
    }
    if change.startLine == change.endLine {
        return change.startCharacter == 0 ? line + change.insertedLineBreaks : line
    }
    if lineChangeDeletesAnnotationLine(line, change) { return nil }
    let replacementLineOffset = min(max(0, line - change.startLine), change.insertedLineBreaks)
    return max(0, min(change.startLine + replacementLineOffset, max(0, nextLineCount - 1)))
}

private func lineChangeDeletesAnnotationLine(_ line: Int, _ change: LineAnnotationChange) -> Bool {
    if change.lineDelta >= 0 || line < change.startLine || line > change.endLine { return false }
    if line == change.startLine, change.startCharacter > 0 { return false }
    if line == change.endLine, !change.deletesEndLine { return false }
    return true
}

private func lineChangeTouchesAnnotationLine(_ line: Int, _ change: LineAnnotationChange) -> Bool {
    if change.lineDelta == 0 || line < change.startLine || line > change.endLine { return false }
    return !(change.endLine > change.startLine && line == change.endLine && !change.deletesEndLine)
}
