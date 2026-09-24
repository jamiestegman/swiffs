// Port of `packages/diffs/src/utils/virtualDiffLayout.ts` and
// `computeVirtualFileMetrics.ts`.

import Foundation

public struct DiffsError: Error, Hashable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Expansion state for collapsed unchanged regions: every region expanded
/// (`true` upstream) or per-hunk partial expansions.
public enum ExpandedHunks: Hashable, Sendable {
    case all
    case regions([Int: HunkExpansionRegion])

    func region(for hunkIndex: Int) -> HunkExpansionRegion? {
        if case .regions(let map) = self { return map[hunkIndex] }
        return nil
    }

    var isAll: Bool {
        if case .all = self { return true }
        return false
    }
}

public struct ExpandedRegionResult: Hashable, Sendable {
    public var fromStart: Int
    public var fromEnd: Int
    public var rangeSize: Int
    public var collapsedLines: Int
    public var renderAll: Bool
}

/// One-based new-file line range covered by a hunk, as `[start, end)`.
public func getHunkAdditionLineRange(_ hunk: Hunk) -> (start: Int, end: Int) {
    (
        getHunkSideStartBoundary(hunk.additionStart, hunk.additionCount) + 1,
        getHunkSideEndBoundary(hunk.additionStart, hunk.additionCount) + 1
    )
}

public struct HunkSeparatorLayout: Hashable, Sendable {
    public var height: Double
    public var gapBefore: Double
    public var gapAfter: Double
    public var totalHeight: Double
}

/// Converts a collapsed unchanged range into the slices that should render
/// near the start and end of that range for the active hunk expansion state.
public func getExpandedRegion(
    isPartial: Bool,
    rangeSize: Int,
    expandedHunks: ExpandedHunks?,
    hunkIndex: Int,
    collapsedContextThreshold: Int
) -> ExpandedRegionResult {
    let normalizedRangeSize = max(rangeSize, 0)
    if normalizedRangeSize == 0 || isPartial {
        return ExpandedRegionResult(
            fromStart: 0, fromEnd: 0, rangeSize: normalizedRangeSize,
            collapsedLines: normalizedRangeSize, renderAll: false
        )
    }
    if expandedHunks?.isAll == true || normalizedRangeSize <= collapsedContextThreshold {
        return ExpandedRegionResult(
            fromStart: normalizedRangeSize, fromEnd: 0, rangeSize: normalizedRangeSize,
            collapsedLines: 0, renderAll: true
        )
    }
    let region = expandedHunks?.region(for: hunkIndex)
    let fromStart = min(max(region?.fromStart ?? 0, 0), normalizedRangeSize)
    let fromEnd = min(max(region?.fromEnd ?? 0, 0), normalizedRangeSize)
    let expandedCount = fromStart + fromEnd
    let renderAll = expandedCount >= normalizedRangeSize
    return ExpandedRegionResult(
        fromStart: renderAll ? normalizedRangeSize : fromStart,
        fromEnd: renderAll ? 0 : fromEnd,
        rangeSize: normalizedRangeSize,
        collapsedLines: max(normalizedRangeSize - expandedCount, 0),
        renderAll: renderAll
    )
}

private func trailingRemaining(_ fileDiff: FileDiffMetadata) -> (addition: Int, deletion: Int)? {
    guard let lastHunk = fileDiff.hunks.last,
          !fileDiff.isPartial,
          !fileDiff.additionLines.isEmpty,
          !fileDiff.deletionLines.isEmpty
    else { return nil }
    return (
        fileDiff.additionLines.count - getHunkSideEndBoundary(lastHunk.additionStart, lastHunk.additionCount),
        fileDiff.deletionLines.count - getHunkSideEndBoundary(lastHunk.deletionStart, lastHunk.deletionCount)
    )
}

public func hasTrailingContext(_ fileDiff: FileDiffMetadata) -> Bool {
    guard let remaining = trailingRemaining(fileDiff) else { return false }
    return remaining.addition > 0 || remaining.deletion > 0
}

/// Returns true when trailing-context line counts disagree between sides.
public func hasTrailingContextMismatch(_ fileDiff: FileDiffMetadata) -> Bool {
    guard let remaining = trailingRemaining(fileDiff) else { return false }
    if remaining.addition <= 0, remaining.deletion <= 0 { return false }
    return remaining.addition != remaining.deletion
}

/// Measures the unchanged tail after the final hunk. Both sides must have the
/// same remaining length because trailing context represents paired lines.
public func getTrailingContextRangeSize(fileDiff: FileDiffMetadata, errorPrefix: String) throws -> Int {
    guard let remaining = trailingRemaining(fileDiff) else { return 0 }
    if remaining.addition <= 0, remaining.deletion <= 0 { return 0 }
    if remaining.addition != remaining.deletion {
        throw DiffsError(
            "\(errorPrefix): trailing context mismatch (additions=\(remaining.addition), deletions=\(remaining.deletion)) for \(fileDiff.name)"
        )
    }
    return min(remaining.addition, remaining.deletion)
}

public func getTrailingExpandedRegion(
    fileDiff: FileDiffMetadata,
    hunkIndex: Int,
    expandedHunks: ExpandedHunks?,
    collapsedContextThreshold: Int,
    errorPrefix: String
) throws -> ExpandedRegionResult? {
    if hunkIndex != fileDiff.hunks.count - 1 { return nil }
    let trailingRangeSize = try getTrailingContextRangeSize(fileDiff: fileDiff, errorPrefix: errorPrefix)
    if trailingRangeSize <= 0 { return nil }
    if expandedHunks?.isAll == true || trailingRangeSize <= collapsedContextThreshold {
        return ExpandedRegionResult(
            fromStart: trailingRangeSize, fromEnd: 0, rangeSize: trailingRangeSize,
            collapsedLines: 0, renderAll: true
        )
    }
    // The final trailing separator only exposes upward partial expansion.
    // Treat it as a bottom-only pseudo-hunk and ignore unsupported downward
    // expansion.
    let region = expandedHunks?.region(for: fileDiff.hunks.count)
    let fromStart = min(max(region?.fromStart ?? 0, 0), trailingRangeSize)
    return ExpandedRegionResult(
        fromStart: fromStart, fromEnd: 0, rangeSize: trailingRangeSize,
        collapsedLines: trailingRangeSize - fromStart,
        renderAll: fromStart >= trailingRangeSize
    )
}

/// Whether a one-based new-file line currently has (or will have on scroll) a
/// rendered row under the given expansion state.
public func isAdditionLineRenderable(
    fileDiff: FileDiffMetadata,
    lineNumber: Int,
    expandedHunks: ExpandedHunks?,
    collapsedContextThreshold: Int
) throws -> Bool {
    if expandedHunks?.isAll == true || fileDiff.isPartial { return true }
    for (hunkIndex, hunk) in fileDiff.hunks.enumerated() {
        let (hunkStart, hunkEnd) = getHunkAdditionLineRange(hunk)
        if lineNumber < hunkStart {
            let region = getExpandedRegion(
                isPartial: fileDiff.isPartial,
                rangeSize: hunk.collapsedBefore,
                expandedHunks: expandedHunks,
                hunkIndex: hunkIndex,
                collapsedContextThreshold: collapsedContextThreshold
            )
            let gapStart = hunkStart - region.rangeSize
            return region.renderAll
                || lineNumber < gapStart + region.fromStart
                || lineNumber >= hunkStart - region.fromEnd
        }
        if lineNumber < hunkEnd { return true }
    }
    guard let trailingRegion = try getTrailingExpandedRegion(
        fileDiff: fileDiff,
        hunkIndex: fileDiff.hunks.count - 1,
        expandedHunks: expandedHunks,
        collapsedContextThreshold: collapsedContextThreshold,
        errorPrefix: "isAdditionLineRenderable"
    ), !trailingRegion.renderAll else { return true }
    let trailingStart = getHunkAdditionLineRange(fileDiff.hunks[fileDiff.hunks.count - 1]).end
    return lineNumber < trailingStart + trailingRegion.fromStart
        || lineNumber >= trailingStart + trailingRegion.rangeSize
}

public enum VerticalDirection: String, Hashable, Sendable {
    case up, down
}

/// The nearest renderable new-file line at or beyond `lineNumber` in the
/// given direction (one-based), or nil when every line that way is hidden
/// inside collapsed regions.
public func getNearestRenderableAdditionLine(
    fileDiff: FileDiffMetadata,
    lineNumber: Int,
    direction: VerticalDirection,
    expandedHunks: ExpandedHunks?,
    collapsedContextThreshold: Int
) throws -> Int? {
    if expandedHunks?.isAll == true || fileDiff.isPartial { return lineNumber }
    var ranges: [(start: Int, end: Int)] = []
    var modeledEnd = 1
    for (hunkIndex, hunk) in fileDiff.hunks.enumerated() {
        let (hunkStart, hunkEnd) = getHunkAdditionLineRange(hunk)
        let region = getExpandedRegion(
            isPartial: fileDiff.isPartial,
            rangeSize: hunk.collapsedBefore,
            expandedHunks: expandedHunks,
            hunkIndex: hunkIndex,
            collapsedContextThreshold: collapsedContextThreshold
        )
        let gapStart = hunkStart - region.rangeSize
        if region.renderAll {
            ranges.append((gapStart, hunkStart))
        } else {
            if region.fromStart > 0 { ranges.append((gapStart, gapStart + region.fromStart)) }
            if region.fromEnd > 0 { ranges.append((hunkStart - region.fromEnd, hunkStart)) }
        }
        ranges.append((hunkStart, hunkEnd))
        modeledEnd = hunkEnd
    }
    if let trailingRegion = try getTrailingExpandedRegion(
        fileDiff: fileDiff,
        hunkIndex: fileDiff.hunks.count - 1,
        expandedHunks: expandedHunks,
        collapsedContextThreshold: collapsedContextThreshold,
        errorPrefix: "getNearestRenderableAdditionLine"
    ) {
        let trailingStart = modeledEnd
        modeledEnd = trailingStart + trailingRegion.rangeSize
        if trailingRegion.renderAll {
            ranges.append((trailingStart, modeledEnd))
        } else if trailingRegion.fromStart > 0 {
            ranges.append((trailingStart, trailingStart + trailingRegion.fromStart))
        }
    }
    if lineNumber >= modeledEnd { return lineNumber }
    if direction == .down {
        for range in ranges where range.end > lineNumber {
            return max(range.start, lineNumber)
        }
        return nil
    }
    for range in ranges.reversed() where range.start <= lineNumber {
        return min(range.end - 1, lineNumber)
    }
    return nil
}

// MARK: - Separators

public func getDefaultHunkSeparatorHeight(_ type: HunkSeparators) -> Double {
    switch type {
    case .simple: return 4
    case .metadata, .lineInfo, .lineInfoBasic, .custom: return 32
    }
}

public func getHunkSeparatorHeight(type: HunkSeparators, metrics: VirtualFileMetrics) -> Double {
    metrics.hunkSeparatorHeight ?? getDefaultHunkSeparatorHeight(type)
}

public func getHunkSeparatorGap(type: HunkSeparators, metrics: VirtualFileMetrics) -> Double {
    switch type {
    case .simple, .metadata, .lineInfoBasic: return 0
    case .lineInfo, .custom: return metrics.spacing
    }
}

public func hasLeadingHunkSeparator(type: HunkSeparators, hunkIndex: Int, hunkSpecs: String?) -> Bool {
    switch type {
    case .simple: return hunkIndex > 0
    case .metadata: return hunkSpecs != nil
    case .lineInfo, .lineInfoBasic, .custom: return true
    }
}

public func hasTrailingHunkSeparator(_ type: HunkSeparators) -> Bool {
    type != .simple && type != .metadata
}

/// Mirrors the renderer spacing rules for the separator shown before a hunk.
public func getLeadingHunkSeparatorLayout(
    type: HunkSeparators,
    metrics: VirtualFileMetrics,
    hunkIndex: Int,
    hunkSpecs: String?
) -> HunkSeparatorLayout? {
    guard hasLeadingHunkSeparator(type: type, hunkIndex: hunkIndex, hunkSpecs: hunkSpecs) else { return nil }
    let height = getHunkSeparatorHeight(type: type, metrics: metrics)
    let gap = getHunkSeparatorGap(type: type, metrics: metrics)
    let gapBefore = hunkIndex > 0 ? gap : 0
    return HunkSeparatorLayout(height: height, gapBefore: gapBefore, gapAfter: gap, totalHeight: gapBefore + height + gap)
}

/// Mirrors the renderer spacing rules for the separator shown after the last
/// hunk when trailing unchanged context is collapsed.
public func getTrailingHunkSeparatorLayout(type: HunkSeparators, metrics: VirtualFileMetrics) -> HunkSeparatorLayout? {
    guard hasTrailingHunkSeparator(type) else { return nil }
    let height = getHunkSeparatorHeight(type: type, metrics: metrics)
    let gapBefore = getHunkSeparatorGap(type: type, metrics: metrics)
    return HunkSeparatorLayout(height: height, gapBefore: gapBefore, gapAfter: 0, totalHeight: gapBefore + height)
}

// MARK: - Virtual file metrics

public func getVirtualFileHeaderRegion(_ metrics: VirtualFileMetrics, disableFileHeader: Bool) -> Double {
    let paddingTop = getVirtualFilePaddingTop(metrics, disableFileHeader: disableFileHeader)
    return disableFileHeader ? paddingTop : metrics.diffHeaderHeight + paddingTop
}

public func getVirtualFilePaddingTop(_ metrics: VirtualFileMetrics, disableFileHeader: Bool) -> Double {
    metrics.paddingTop ?? (disableFileHeader ? metrics.spacing : 0)
}

public func getVirtualFilePaddingBottom(_ metrics: VirtualFileMetrics) -> Double {
    metrics.paddingBottom ?? metrics.spacing
}
