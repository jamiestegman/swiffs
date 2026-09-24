// Port of `packages/diffs/src/utils/computeEstimatedDiffHeights.ts`.

import Foundation

public struct EstimatedDiffHeights: Hashable, Sendable {
    public var splitHeight: Double
    public var unifiedHeight: Double
}

/// Computes both split and unified baseline heights from hunk-level metadata
/// so callers can avoid replaying the detailed rendered-line iterator.
public func computeEstimatedDiffHeights(
    fileDiff: FileDiffMetadata,
    metrics: VirtualFileMetrics,
    disableFileHeader: Bool,
    hunkSeparators: HunkSeparators,
    expandUnchanged: Bool,
    expandedHunks configuredExpandedHunks: ExpandedHunks?,
    collapsedContextThreshold: Int,
    canHydratePartialDiff: Bool
) throws -> EstimatedDiffHeights {
    var splitHeight = getVirtualFileHeaderRegion(metrics, disableFileHeader: disableFileHeader)
    var unifiedHeight = splitHeight
    let expandedHunks: ExpandedHunks? = expandUnchanged ? .all : configuredExpandedHunks
    let finalHunkIndex = fileDiff.hunks.count - 1

    for (hunkIndex, hunk) in fileDiff.hunks.enumerated() {
        let leadingRegion = getExpandedRegion(
            isPartial: fileDiff.isPartial,
            rangeSize: hunk.collapsedBefore,
            expandedHunks: expandedHunks,
            hunkIndex: hunkIndex,
            collapsedContextThreshold: collapsedContextThreshold
        )
        let leadingExpandedHeight = Double(leadingRegion.fromStart + leadingRegion.fromEnd) * metrics.lineHeight
        splitHeight += leadingExpandedHeight
        unifiedHeight += leadingExpandedHeight

        if leadingRegion.collapsedLines > 0 {
            let separatorHeight = getLeadingHunkSeparatorLayout(
                type: hunkSeparators, metrics: metrics, hunkIndex: hunkIndex, hunkSpecs: hunk.hunkSpecs
            )?.totalHeight ?? 0
            splitHeight += separatorHeight
            unifiedHeight += separatorHeight
        }

        splitHeight += Double(hunk.splitLineCount) * metrics.lineHeight
        unifiedHeight += Double(hunk.unifiedLineCount) * metrics.lineHeight

        let metadataLineCounts = getNoNewlineMetadataLineCounts(hunk)
        splitHeight += Double(metadataLineCounts.split) * metrics.lineHeight
        unifiedHeight += Double(metadataLineCounts.unified) * metrics.lineHeight

        let trailingRegion = hunkIndex == finalHunkIndex
            ? try getTrailingExpandedRegion(
                fileDiff: fileDiff,
                hunkIndex: hunkIndex,
                expandedHunks: expandedHunks,
                collapsedContextThreshold: collapsedContextThreshold,
                errorPrefix: "computeEstimatedDiffHeights"
            )
            : nil
        if let trailingRegion {
            let trailingExpandedHeight = Double(trailingRegion.fromStart + trailingRegion.fromEnd) * metrics.lineHeight
            splitHeight += trailingExpandedHeight
            unifiedHeight += trailingExpandedHeight
            if trailingRegion.collapsedLines > 0 {
                let separatorHeight = getTrailingHunkSeparatorLayout(type: hunkSeparators, metrics: metrics)?.totalHeight ?? 0
                splitHeight += separatorHeight
                unifiedHeight += separatorHeight
            }
        } else if hunkIndex == finalHunkIndex, fileDiff.isPartial, canHydratePartialDiff {
            let separatorHeight = getTrailingHunkSeparatorLayout(type: hunkSeparators, metrics: metrics)?.totalHeight ?? 0
            splitHeight += separatorHeight
            unifiedHeight += separatorHeight
        }
    }

    if !fileDiff.hunks.isEmpty {
        let paddingBottom = getVirtualFilePaddingBottom(metrics)
        splitHeight += paddingBottom
        unifiedHeight += paddingBottom
    }
    return EstimatedDiffHeights(splitHeight: splitHeight, unifiedHeight: unifiedHeight)
}

func getNoNewlineMetadataLineCounts(_ hunk: Hunk) -> (split: Int, unified: Int) {
    if !hunk.noEOFCRAdditions, !hunk.noEOFCRDeletions { return (0, 0) }
    guard let lastContent = hunk.hunkContent.last else { return (0, 0) }
    switch lastContent {
    case .context(let context):
        let metadataRows = context.lines > 0 ? 1 : 0
        return (metadataRows, metadataRows)
    case .change(let content):
        let unified = (content.deletions > 0 && hunk.noEOFCRDeletions ? 1 : 0)
            + (content.additions > 0 && hunk.noEOFCRAdditions ? 1 : 0)
        let split = (content.deletions > 0 && hunk.noEOFCRDeletions) || (content.additions > 0 && hunk.noEOFCRAdditions) ? 1 : 0
        return (split, unified)
    }
}
