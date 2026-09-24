// Port of `packages/diffs/src/utils/iterateOverDiff.ts`.
//
// Walks the rendered rows of a diff (split, unified or both coordinate spaces)
// honoring collapsed/expanded unchanged regions and an optional render window.

import Foundation

public struct DiffLineMetadata: Hashable, Sendable {
    public var unifiedLineIndex: Int
    public var splitLineIndex: Int
    public var lineIndex: Int
    public var lineNumber: Int
    public var noEOFCR: Bool

    public init(unifiedLineIndex: Int, splitLineIndex: Int, lineIndex: Int, lineNumber: Int, noEOFCR: Bool) {
        self.unifiedLineIndex = unifiedLineIndex
        self.splitLineIndex = splitLineIndex
        self.lineIndex = lineIndex
        self.lineNumber = lineNumber
        self.noEOFCR = noEOFCR
    }
}

public enum DiffLineEventType: String, Hashable, Sendable {
    case change
    case context
    case contextExpanded = "context-expanded"
}

public struct DiffLineCallbackProps: Sendable {
    public var hunkIndex: Int
    /// nil for the trailing expansion region.
    public var hunk: Hunk?
    /// > 0 means a separator before this line; the value is hidden lines.
    public var collapsedBefore: Int
    /// > 0 only on the final line if there is trailing collapsed content.
    public var collapsedAfter: Int
    public var type: DiffLineEventType
    /// Present for context rows, and for change rows with a deletion.
    public var deletionLine: DiffLineMetadata?
    /// Present for context rows, and for change rows with an addition.
    public var additionLine: DiffLineMetadata?
}

public enum IterationDiffStyle: String, Hashable, Sendable {
    case unified, split, both
}

private struct IterationState {
    let diffStyle: IterationDiffStyle
    let isWindowedHighlight: Bool
    let viewportStart: Int
    let viewportEnd: Int
    var splitCount: Int
    var unifiedCount: Int
    let finalHunkIndex: Int

    func shouldBreak() -> Bool {
        if !isWindowedHighlight { return false }
        let breakUnified = unifiedCount >= viewportEnd
        let breakSplit = splitCount >= viewportEnd
        switch diffStyle {
        case .unified: return breakUnified
        case .split: return breakSplit
        case .both: return breakUnified && breakSplit
        }
    }

    func shouldSkip(_ unifiedHeight: Int, _ splitHeight: Int) -> Bool {
        if !isWindowedHighlight { return false }
        let skipUnified = unifiedHeight > 0 && unifiedCount + unifiedHeight <= viewportStart
        let skipSplit = splitHeight > 0 && splitCount + splitHeight <= viewportStart
        switch diffStyle {
        case .unified: return skipUnified
        case .split: return skipSplit
        case .both: return skipUnified && skipSplit
        }
    }

    mutating func incrementCounts(_ unifiedValue: Int, _ splitValue: Int) {
        if diffStyle == .unified || diffStyle == .both { unifiedCount += unifiedValue }
        if diffStyle == .split || diffStyle == .both { splitCount += splitValue }
    }

    func isInWindow(_ unifiedHeight: Int, _ splitHeight: Int) -> Bool {
        if !isWindowedHighlight { return true }
        let unifiedInWindow = isInUnifiedWindow(unifiedHeight)
        let splitInWindow = isInSplitWindow(splitHeight)
        switch diffStyle {
        case .unified: return unifiedInWindow
        case .split: return splitInWindow
        case .both: return unifiedInWindow || splitInWindow
        }
    }

    func isInUnifiedWindow(_ height: Int) -> Bool {
        !isWindowedHighlight || (unifiedCount >= viewportStart - height && unifiedCount < viewportEnd)
    }

    func isInSplitWindow(_ height: Int) -> Bool {
        !isWindowedHighlight || (splitCount >= viewportStart - height && splitCount < viewportEnd)
    }
}

/// Iterates over the rendered rows of a diff.
///
/// - Parameters:
///   - startingLine: Dense rendered-row index where the window starts.
///   - totalLines: Rows in the window (`Int.max` means unbounded).
///   - callback: Return `true` to stop iteration.
public func iterateOverDiff(
    diff: FileDiffMetadata,
    diffStyle: IterationDiffStyle,
    startingLine: Int = 0,
    totalLines: Int = .max,
    expandedHunks: ExpandedHunks? = nil,
    collapsedContextThreshold: Int = DiffsConstants.defaultCollapsedContextThreshold,
    callback: (DiffLineCallbackProps) -> Bool
) throws {
    let iterationStart = try getIterationStartState(
        diff: diff,
        diffStyle: diffStyle,
        startingLine: startingLine,
        expandedHunks: expandedHunks,
        collapsedContextThreshold: collapsedContextThreshold
    )
    let viewportEnd = totalLines == .max ? Int.max : startingLine &+ totalLines
    var state = IterationState(
        diffStyle: diffStyle,
        isWindowedHighlight: startingLine > 0 || totalLines < .max,
        viewportStart: startingLine,
        viewportEnd: viewportEnd,
        splitCount: iterationStart.splitCount,
        unifiedCount: iterationStart.unifiedCount,
        finalHunkIndex: diff.hunks.count - 1
    )

    func emit(_ props: DiffLineCallbackProps, silent: Bool = false) -> Bool {
        if !silent {
            switch diffStyle {
            case .unified: state.incrementCounts(1, 0)
            case .split: state.incrementCounts(0, 1)
            case .both: state.incrementCounts(1, 1)
            }
        }
        return callback(props)
    }

    // Walk context rows through the active window while keeping split and
    // unified counters aligned.
    func walkContextLines(
        _ count: Int,
        _ lineCallback: (Int) -> Bool,
        onSkippedStart: (() -> Void)? = nil,
        shouldBreak: (() -> Bool)? = nil
    ) -> Bool {
        let (startIndex, endIndex) = getContextLineIterationBounds(state, count, diffStyle)
        if startIndex > 0 {
            state.incrementCounts(startIndex, startIndex)
            onSkippedStart?()
        }
        var index = startIndex
        while index < count {
            if shouldBreak?() == true { return true }
            if index >= endIndex {
                state.incrementCounts(count - index, count - index)
                break
            }
            if state.isInWindow(0, 0) {
                if lineCallback(index) { return true }
            } else {
                state.incrementCounts(1, 1)
            }
            index += 1
        }
        return false
    }

    var hunkIndex = iterationStart.hunkIndex
    hunkIterator: while hunkIndex < diff.hunks.count {
        defer { hunkIndex += 1 }
        let hunk = diff.hunks[hunkIndex]
        if state.shouldBreak() { break }

        let deletionBoundary = getHunkSideStartBoundary(hunk.deletionStart, hunk.deletionCount)
        let additionBoundary = getHunkSideStartBoundary(hunk.additionStart, hunk.additionCount)
        let deletionStartIndex = !diff.isPartial && hunk.deletionCount == 0 ? deletionBoundary : hunk.deletionLineIndex
        let additionStartIndex = !diff.isPartial && hunk.additionCount == 0 ? additionBoundary : hunk.additionLineIndex

        let leadingRegion = getExpandedRegion(
            isPartial: diff.isPartial,
            rangeSize: hunk.collapsedBefore,
            expandedHunks: expandedHunks,
            hunkIndex: hunkIndex,
            collapsedContextThreshold: collapsedContextThreshold
        )
        let trailingRegion = hunkIndex == state.finalHunkIndex
            ? try getTrailingExpandedRegion(
                fileDiff: diff,
                hunkIndex: hunkIndex,
                expandedHunks: expandedHunks,
                collapsedContextThreshold: collapsedContextThreshold,
                errorPrefix: "iterateOverDiff"
            )
            : nil
        let expandedLineCount = leadingRegion.fromStart + leadingRegion.fromEnd

        func getTrailingCollapsedAfter(_ unifiedLineIndex: Int, _ splitLineIndex: Int) -> Int {
            guard let trailingRegion, trailingRegion.collapsedLines > 0,
                  trailingRegion.fromStart + trailingRegion.fromEnd <= 0
            else { return 0 }
            if diffStyle == .unified {
                return unifiedLineIndex == hunk.unifiedLineStart + hunk.unifiedLineCount - 1
                    ? trailingRegion.collapsedLines : 0
            }
            return splitLineIndex == hunk.splitLineStart + hunk.splitLineCount - 1
                ? trailingRegion.collapsedLines : 0
        }

        var consumedCollapsed = leadingRegion.collapsedLines == 0
        func consumePendingCollapsed() -> Int {
            if consumedCollapsed { return 0 }
            consumedCollapsed = true
            return leadingRegion.collapsedLines
        }

        // Emit for expanded lines
        if !state.shouldSkip(expandedLineCount, expandedLineCount) {
            var unifiedLineIndex = hunk.unifiedLineStart - leadingRegion.rangeSize
            var splitLineIndex = hunk.splitLineStart - leadingRegion.rangeSize
            var deletionLineIndex = deletionStartIndex - leadingRegion.rangeSize
            var additionLineIndex = additionStartIndex - leadingRegion.rangeSize
            var deletionLineNumber = deletionBoundary + 1 - leadingRegion.rangeSize
            var additionLineNumber = additionBoundary + 1 - leadingRegion.rangeSize

            if walkContextLines(leadingRegion.fromStart, { index in
                emit(DiffLineCallbackProps(
                    hunkIndex: hunkIndex,
                    hunk: hunk,
                    collapsedBefore: 0,
                    collapsedAfter: 0,
                    type: .contextExpanded,
                    deletionLine: DiffLineMetadata(
                        unifiedLineIndex: unifiedLineIndex + index,
                        splitLineIndex: splitLineIndex + index,
                        lineIndex: deletionLineIndex + index,
                        lineNumber: deletionLineNumber + index,
                        noEOFCR: false
                    ),
                    additionLine: DiffLineMetadata(
                        unifiedLineIndex: unifiedLineIndex + index,
                        splitLineIndex: splitLineIndex + index,
                        lineIndex: additionLineIndex + index,
                        lineNumber: additionLineNumber + index,
                        noEOFCR: false
                    )
                ))
            }) {
                break hunkIterator
            }

            unifiedLineIndex = hunk.unifiedLineStart - leadingRegion.fromEnd
            splitLineIndex = hunk.splitLineStart - leadingRegion.fromEnd
            deletionLineIndex = deletionStartIndex - leadingRegion.fromEnd
            additionLineIndex = additionStartIndex - leadingRegion.fromEnd
            deletionLineNumber = deletionBoundary + 1 - leadingRegion.fromEnd
            additionLineNumber = additionBoundary + 1 - leadingRegion.fromEnd
            if walkContextLines(leadingRegion.fromEnd, { index in
                emit(DiffLineCallbackProps(
                    hunkIndex: hunkIndex,
                    hunk: hunk,
                    collapsedBefore: consumePendingCollapsed(),
                    collapsedAfter: 0,
                    type: .contextExpanded,
                    deletionLine: DiffLineMetadata(
                        unifiedLineIndex: unifiedLineIndex + index,
                        splitLineIndex: splitLineIndex + index,
                        lineIndex: deletionLineIndex + index,
                        lineNumber: deletionLineNumber + index,
                        noEOFCR: false
                    ),
                    additionLine: DiffLineMetadata(
                        unifiedLineIndex: unifiedLineIndex + index,
                        splitLineIndex: splitLineIndex + index,
                        lineIndex: additionLineIndex + index,
                        lineNumber: additionLineNumber + index,
                        noEOFCR: false
                    )
                ))
            }, onSkippedStart: {
                // The collapsed separator belongs before this fromEnd slice.
                _ = consumePendingCollapsed()
            }) {
                break hunkIterator
            }
        } else {
            state.incrementCounts(expandedLineCount, expandedLineCount)
            _ = consumePendingCollapsed()
        }

        var unifiedLineIndex = hunk.unifiedLineStart
        var splitLineIndex = hunk.splitLineStart
        var deletionLineIndex = deletionStartIndex
        var additionLineIndex = additionStartIndex
        var deletionLineNumber = deletionBoundary + 1
        var additionLineNumber = additionBoundary + 1
        let lastContentIndex = hunk.hunkContent.count - 1

        for (contentIndex, content) in hunk.hunkContent.enumerated() {
            if state.shouldBreak() { break hunkIterator }
            let isLastContent = contentIndex == lastContentIndex

            switch content {
            case .context(let context):
                if !state.shouldSkip(context.lines, context.lines) {
                    if walkContextLines(context.lines, { index in
                        let isLastLine = isLastContent && index == context.lines - 1
                        let unifiedRowIndex = unifiedLineIndex + index
                        let splitRowIndex = splitLineIndex + index
                        return emit(DiffLineCallbackProps(
                            hunkIndex: hunkIndex,
                            hunk: hunk,
                            collapsedBefore: consumePendingCollapsed(),
                            collapsedAfter: getTrailingCollapsedAfter(unifiedRowIndex, splitRowIndex),
                            type: .context,
                            deletionLine: DiffLineMetadata(
                                unifiedLineIndex: unifiedRowIndex,
                                splitLineIndex: splitRowIndex,
                                lineIndex: deletionLineIndex + index,
                                lineNumber: deletionLineNumber + index,
                                noEOFCR: isLastLine && hunk.noEOFCRDeletions
                            ),
                            additionLine: DiffLineMetadata(
                                unifiedLineIndex: unifiedRowIndex,
                                splitLineIndex: splitRowIndex,
                                lineIndex: additionLineIndex + index,
                                lineNumber: additionLineNumber + index,
                                noEOFCR: isLastLine && hunk.noEOFCRAdditions
                            )
                        ))
                    }, onSkippedStart: {
                        // When windowing starts inside context content, the
                        // leading separator was above the visible range.
                        _ = consumePendingCollapsed()
                    }) {
                        break hunkIterator
                    }
                } else {
                    state.incrementCounts(context.lines, context.lines)
                    _ = consumePendingCollapsed()
                }
                unifiedLineIndex += context.lines
                splitLineIndex += context.lines
                deletionLineIndex += context.lines
                additionLineIndex += context.lines
                deletionLineNumber += context.lines
                additionLineNumber += context.lines

            case .change(let change):
                let splitCount = max(change.deletions, change.additions)
                let unifiedCount = change.deletions + change.additions
                if !state.shouldSkip(unifiedCount, splitCount) {
                    let iterationRanges = getChangeIterationRanges(state, change, diffStyle)
                    if (iterationRanges.first?.0 ?? 0) > 0 {
                        // Change rows can be windowed from the middle of the
                        // block too.
                        _ = consumePendingCollapsed()
                    }
                    for (rangeStart, rangeEnd) in iterationRanges {
                        var index = rangeStart
                        while index < rangeEnd {
                            let unifiedRowIndex = unifiedLineIndex + index
                            let splitRowIndex = diffStyle == .unified
                                ? splitLineIndex + (index < change.deletions ? index : index - change.deletions)
                                : splitLineIndex + index
                            let collapsedAfter = getTrailingCollapsedAfter(unifiedRowIndex, splitRowIndex)
                            let props = try getChangeLineData(
                                hunkIndex: hunkIndex,
                                hunk: hunk,
                                collapsedBefore: consumePendingCollapsed(),
                                collapsedAfter: collapsedAfter,
                                diffStyle: diffStyle,
                                index: index,
                                unifiedLineIndex: unifiedLineIndex,
                                splitLineIndex: splitLineIndex,
                                additionLineIndex: additionLineIndex,
                                deletionLineIndex: deletionLineIndex,
                                additionLineNumber: additionLineNumber,
                                deletionLineNumber: deletionLineNumber,
                                content: change,
                                isLastContent: isLastContent,
                                unifiedCount: unifiedCount,
                                splitCount: splitCount
                            )
                            if emit(props, silent: true) {
                                break hunkIterator
                            }
                            index += 1
                        }
                    }
                }
                _ = consumePendingCollapsed()
                state.incrementCounts(unifiedCount, splitCount)
                unifiedLineIndex += unifiedCount
                splitLineIndex += splitCount
                deletionLineIndex += change.deletions
                additionLineIndex += change.additions
                deletionLineNumber += change.deletions
                additionLineNumber += change.additions
            }
        }

        if let trailingRegion {
            let collapsedLines = trailingRegion.collapsedLines
            let len = trailingRegion.fromStart + trailingRegion.fromEnd
            let hunksCount = diff.hunks.count
            if walkContextLines(len, { index in
                let isLastLine = index == len - 1
                return emit(DiffLineCallbackProps(
                    hunkIndex: hunksCount,
                    hunk: nil,
                    collapsedBefore: 0,
                    collapsedAfter: isLastLine ? collapsedLines : 0,
                    type: .contextExpanded,
                    deletionLine: DiffLineMetadata(
                        unifiedLineIndex: unifiedLineIndex + index,
                        splitLineIndex: splitLineIndex + index,
                        lineIndex: deletionLineIndex + index,
                        lineNumber: deletionLineNumber + index,
                        noEOFCR: false
                    ),
                    additionLine: DiffLineMetadata(
                        unifiedLineIndex: unifiedLineIndex + index,
                        splitLineIndex: splitLineIndex + index,
                        lineIndex: additionLineIndex + index,
                        lineNumber: additionLineNumber + index,
                        noEOFCR: false
                    )
                ))
            }, shouldBreak: { state.shouldBreak() }) {
                break hunkIterator
            }
        }
    }
}

private struct HunkPrefixCounts {
    var splitCount: Int
    var unifiedCount: Int
}

// Seek the iterator to the hunk that contains `startingLine`.
private func getIterationStartState(
    diff: FileDiffMetadata,
    diffStyle: IterationDiffStyle,
    startingLine: Int,
    expandedHunks: ExpandedHunks?,
    collapsedContextThreshold: Int
) throws -> (hunkIndex: Int, splitCount: Int, unifiedCount: Int) {
    if startingLine <= 0 || diffStyle == .both {
        return (0, 0, 0)
    }
    let prefixCounts = try getHunkPrefixCounts(
        diff: diff,
        expandedHunks: expandedHunks,
        collapsedContextThreshold: collapsedContextThreshold
    )
    var low = 0
    var high = diff.hunks.count - 1
    var result = diff.hunks.count
    while low <= high {
        let mid = (low + high) >> 1
        let counts = prefixCounts[mid + 1]
        let selectedCount = diffStyle == .unified ? counts.unifiedCount : counts.splitCount
        if selectedCount > startingLine {
            result = mid
            high = mid - 1
        } else {
            low = mid + 1
        }
    }
    let counts = prefixCounts[min(result, diff.hunks.count)]
    return (result, counts.splitCount, counts.unifiedCount)
}

// Build cumulative rendered-row counts at every hunk boundary for the current
// expansion state.
private func getHunkPrefixCounts(
    diff: FileDiffMetadata,
    expandedHunks: ExpandedHunks?,
    collapsedContextThreshold: Int
) throws -> [HunkPrefixCounts] {
    var splitCount = 0
    var unifiedCount = 0
    let finalHunkIndex = diff.hunks.count - 1
    var prefixCounts = [HunkPrefixCounts(splitCount: 0, unifiedCount: 0)]
    prefixCounts.reserveCapacity(diff.hunks.count + 1)
    for (index, hunk) in diff.hunks.enumerated() {
        let leadingRegion = getExpandedRegion(
            isPartial: diff.isPartial,
            rangeSize: hunk.collapsedBefore,
            expandedHunks: expandedHunks,
            hunkIndex: index,
            collapsedContextThreshold: collapsedContextThreshold
        )
        let leadingCount = leadingRegion.fromStart + leadingRegion.fromEnd
        splitCount += leadingCount + hunk.splitLineCount
        unifiedCount += leadingCount + hunk.unifiedLineCount
        if index == finalHunkIndex, let trailingRegion = try getTrailingExpandedRegion(
            fileDiff: diff,
            hunkIndex: index,
            expandedHunks: expandedHunks,
            collapsedContextThreshold: collapsedContextThreshold,
            errorPrefix: "iterateOverDiff"
        ) {
            let trailingCount = trailingRegion.fromStart + trailingRegion.fromEnd
            splitCount += trailingCount
            unifiedCount += trailingCount
        }
        prefixCounts.append(HunkPrefixCounts(splitCount: splitCount, unifiedCount: unifiedCount))
    }
    return prefixCounts
}

// Clip a run of context rows to a single bounded hull around the active
// rendered window.
private func getContextLineIterationBounds(
    _ state: IterationState,
    _ count: Int,
    _ diffStyle: IterationDiffStyle
) -> (Int, Int) {
    if !state.isWindowedHighlight || count <= 0 {
        return (0, count)
    }
    var ranges: [(Int, Int)] = []
    func pushRange(_ currentCount: Int) {
        let start = max(0, state.viewportStart - currentCount)
        let end = min(count, state.viewportEnd == .max ? .max : state.viewportEnd - currentCount)
        if end > start { ranges.append((start, end)) }
    }
    if diffStyle != .split { pushRange(state.unifiedCount) }
    if diffStyle != .unified { pushRange(state.splitCount) }
    guard var (start, end) = ranges.first else { return (0, 0) }
    for range in ranges.dropFirst() {
        start = min(start, range.0)
        end = max(end, range.1)
    }
    return (start, end)
}

// Clip a change block to the rows that can be visible in the active
// coordinate space.
private func getChangeIterationRanges(
    _ state: IterationState,
    _ content: ChangeContent,
    _ diffStyle: IterationDiffStyle
) -> [(Int, Int)] {
    if !state.isWindowedHighlight {
        return [(0, diffStyle == .unified ? content.deletions + content.additions : max(content.deletions, content.additions))]
    }
    let useUnified = diffStyle != .split
    let useSplit = diffStyle != .unified
    let iterationSpaceIsSplit = diffStyle != .unified
    var iterationRanges: [(Int, Int)] = []

    func getVisibleRange(_ start: Int, _ count: Int) -> (Int, Int)? {
        let end = start + count
        if end <= state.viewportStart || start >= state.viewportEnd { return nil }
        let visibleStart = max(0, state.viewportStart - start)
        let visibleEnd = min(count, state.viewportEnd == .max ? .max : state.viewportEnd - start)
        return visibleEnd > visibleStart ? (visibleStart, visibleEnd) : nil
    }
    func pushRange(_ range: (Int, Int)?, additions: Bool) {
        guard let range else { return }
        let mapped = (!iterationSpaceIsSplit && additions)
            ? (range.0 + content.deletions, range.1 + content.deletions)
            : range
        if mapped.1 > mapped.0 { iterationRanges.append(mapped) }
    }

    if useUnified {
        pushRange(getVisibleRange(state.unifiedCount, content.deletions), additions: false)
        pushRange(getVisibleRange(state.unifiedCount + content.deletions, content.additions), additions: true)
    }
    if useSplit {
        pushRange(getVisibleRange(state.splitCount, content.deletions), additions: false)
        pushRange(getVisibleRange(state.splitCount, content.additions), additions: true)
    }
    if iterationRanges.isEmpty { return iterationRanges }

    // Stable sort by start (matches Array.prototype.sort's stability).
    iterationRanges = iterationRanges.enumerated()
        .sorted { $0.element.0 != $1.element.0 ? $0.element.0 < $1.element.0 : $0.offset < $1.offset }
        .map(\.element)
    var merged: [(Int, Int)] = [iterationRanges[0]]
    for (start, end) in iterationRanges.dropFirst() {
        if start <= merged[merged.count - 1].1 {
            merged[merged.count - 1].1 = max(merged[merged.count - 1].1, end)
        } else {
            merged.append((start, end))
        }
    }
    return merged
}

// Build the callback payload for one change row.
private func getChangeLineData(
    hunkIndex: Int,
    hunk: Hunk,
    collapsedBefore: Int,
    collapsedAfter: Int,
    diffStyle: IterationDiffStyle,
    index: Int,
    unifiedLineIndex: Int,
    splitLineIndex: Int,
    additionLineIndex: Int,
    deletionLineIndex: Int,
    additionLineNumber: Int,
    deletionLineNumber: Int,
    content: ChangeContent,
    isLastContent: Bool,
    unifiedCount: Int,
    splitCount: Int
) throws -> DiffLineCallbackProps {
    let isUnified = diffStyle == .unified
    let hasDeletion = index < content.deletions
    let hasAddition = isUnified ? index >= content.deletions : index < content.additions

    let unifiedDeletionLineIndex = unifiedLineIndex + index
    let unifiedAdditionLineIndex = isUnified ? unifiedLineIndex + index : unifiedLineIndex + content.deletions + index
    let resolvedSplitLineIndex = isUnified
        ? splitLineIndex + (index < content.deletions ? index : index - content.deletions)
        : splitLineIndex + index

    let noEOFCRDeletion = isUnified
        ? isLastContent && index == content.deletions - 1 && hunk.noEOFCRDeletions
        : isLastContent && index == splitCount - 1 && hunk.noEOFCRDeletions
    let noEOFCRAddition = isUnified
        ? isLastContent && index == unifiedCount - 1 && hunk.noEOFCRAdditions
        : isLastContent && index == splitCount - 1 && hunk.noEOFCRAdditions

    let deletionLine = hasDeletion
        ? DiffLineMetadata(
            unifiedLineIndex: unifiedDeletionLineIndex,
            splitLineIndex: resolvedSplitLineIndex,
            lineIndex: deletionLineIndex + index,
            lineNumber: deletionLineNumber + index,
            noEOFCR: noEOFCRDeletion
        )
        : nil
    let additionOffset = isUnified ? index - content.deletions : index
    let additionLine = hasAddition
        ? DiffLineMetadata(
            unifiedLineIndex: unifiedAdditionLineIndex,
            splitLineIndex: resolvedSplitLineIndex,
            lineIndex: additionLineIndex + additionOffset,
            lineNumber: additionLineNumber + additionOffset,
            noEOFCR: noEOFCRAddition
        )
        : nil
    if deletionLine == nil, additionLine == nil {
        throw DiffsError("iterateOverDiff: missing change line data")
    }
    return DiffLineCallbackProps(
        hunkIndex: hunkIndex,
        hunk: hunk,
        collapsedBefore: collapsedBefore,
        collapsedAfter: collapsedAfter,
        type: .change,
        deletionLine: deletionLine,
        additionLine: additionLine
    )
}
