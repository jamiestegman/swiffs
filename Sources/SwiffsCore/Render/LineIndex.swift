// Port of `FileDiff.getLineIndexForDiff`: maps a line number on one side of
// a diff to its `[unifiedIndex, splitIndex]` rendered row indexes.

import Foundation

public func getLineIndexForDiff(_ fileDiff: FileDiffMetadata, lineNumber: Int, side: AnnotationSide = .additions) -> (unified: Int, split: Int)? {
    var targetUnifiedIndex: Int?
    var targetSplitIndex: Int?
    let lastHunkIndex = fileDiff.hunks.count - 1
    hunkIterator: for (hunkIndex, hunk) in fileDiff.hunks.enumerated() {
        let hunkStart = side == .deletions ? hunk.deletionStart : hunk.additionStart
        let hunkCount = side == .deletions ? hunk.deletionCount : hunk.additionCount
        var currentLineNumber = getHunkSideStartBoundary(hunkStart, hunkCount) + 1
        var splitIndex = hunk.splitLineStart
        var unifiedIndex = hunk.unifiedLineStart

        // If we've selected a line between or before a hunk, grab its index
        if lineNumber < currentLineNumber {
            let difference = currentLineNumber - lineNumber
            targetUnifiedIndex = max(unifiedIndex - difference, 0)
            targetSplitIndex = max(splitIndex - difference, 0)
            break hunkIterator
        }

        if lineNumber >= currentLineNumber + hunkCount {
            if hunkIndex == lastHunkIndex {
                let difference = lineNumber - (currentLineNumber + hunkCount)
                targetUnifiedIndex = unifiedIndex + hunk.unifiedLineCount + difference
                targetSplitIndex = splitIndex + hunk.splitLineCount + difference
                break hunkIterator
            }
            continue
        }

        for content in hunk.hunkContent {
            switch content {
            case .context(let context):
                if lineNumber < currentLineNumber + context.lines {
                    let difference = lineNumber - currentLineNumber
                    targetSplitIndex = splitIndex + difference
                    targetUnifiedIndex = unifiedIndex + difference
                    break hunkIterator
                }
                currentLineNumber += context.lines
                splitIndex += context.lines
                unifiedIndex += context.lines
            case .change(let change):
                let sideCount = side == .deletions ? change.deletions : change.additions
                if lineNumber < currentLineNumber + sideCount {
                    let indexDifference = lineNumber - currentLineNumber
                    targetUnifiedIndex = unifiedIndex + (side == .additions ? change.deletions : 0) + indexDifference
                    targetSplitIndex = splitIndex + indexDifference
                    break hunkIterator
                }
                currentLineNumber += sideCount
                splitIndex += max(change.deletions, change.additions)
                unifiedIndex += change.deletions + change.additions
            }
        }
        break hunkIterator
    }
    guard let targetUnifiedIndex, let targetSplitIndex else { return nil }
    return (targetUnifiedIndex, targetSplitIndex)
}
