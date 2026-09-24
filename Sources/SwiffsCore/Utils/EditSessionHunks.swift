// Port of `editSessionHunks.ts`: while an editor is attached to a diff, each
// hunk is a persistent region identified by its old-side range. Structural
// passes rebuild those regions from one canonical old/current diff; a
// reverted region stays as context until the session-exit recompute.

import Foundation

/// The old/current divergence (`DivergenceCore`).
public struct DivergenceCore: Hashable, Sendable {
    public var start: Int
    public var deletionEnd: Int
    public var additionEnd: Int
}

/// Maps rebuilt regions to previous hunk spans (`SessionRegionChange`).
public struct SessionRegionChange: Hashable, Sendable {
    public struct Span: Hashable, Sendable {
        public var firstIndex: Int
        public var lastIndex: Int
    }

    public var regions: [Span?]
}

private struct RegionPlan {
    var deletionStart: Int
    var deletionEnd: Int
    var blocks: [ChangeContent]
    var previousSpan: SessionRegionChange.Span?
}

private func exactEqual(_ a: String, _ b: String) -> Bool {
    a.utf16.elementsEqual(b.utf16)
}

/// Drops the editor's phantom trailing empty line (`normalizeEditorLines`).
public func normalizeEditorLines(_ lines: [String]) -> [String] {
    if lines.count > 1, lines.last == "" { return Array(lines.dropLast()) }
    return lines
}

/// The complete old/current divergence core (`findDivergenceCore`).
public func findDivergenceCore(_ deletionLines: [String], _ additionLines: [String]) -> DivergenceCore? {
    let maxStart = min(deletionLines.count, additionLines.count)
    var start = 0
    while start < maxStart, exactEqual(deletionLines[start], additionLines[start]) { start += 1 }
    var deletionEnd = deletionLines.count
    var additionEnd = additionLines.count
    while deletionEnd > start, additionEnd > start, exactEqual(deletionLines[deletionEnd - 1], additionLines[additionEnd - 1]) {
        deletionEnd -= 1
        additionEnd -= 1
    }
    if start == deletionEnd, start == additionEnd { return nil }
    return DivergenceCore(start: start, deletionEnd: deletionEnd, additionEnd: additionEnd)
}

/// Rebuilds session regions from old/current lines (`rebuildSessionHunks`).
@discardableResult
public func rebuildSessionHunks(
    _ diff: inout FileDiffMetadata,
    options: CreatePatchOptions = CreatePatchOptions(),
    getPreviousAdditionLine: ((Int) -> String?)? = nil
) throws -> SessionRegionChange? {
    let previousHunks = diff.hunks
    let editorAdditionLines = diff.additionLines
    let canonicalAdditionLines = normalizeEditorLines(editorAdditionLines)
    var canonicalDiff = diff
    canonicalDiff.additionLines = canonicalAdditionLines
    let blocks = try parseSessionChangeBlocks(canonicalDiff, options, getPreviousAdditionLine)
    let plans = buildRegionPlans(previousHunks, blocks, diff.deletionLines.count)
    let nextHunks = try buildRegionHunks(canonicalDiff, plans)
    diff.additionLines = canonicalAdditionLines
    diff.hunks = nextHunks
    diff.editSessionDirty = true
    finalizeSessionHunks(&diff)
    preserveTrailingEditorBlankLine(&diff, additionLines: editorAdditionLines)
    if !hasRegionOrSplitLayoutChanged(previousHunks, diff.hunks) { return nil }
    return SessionRegionChange(regions: plans.map(\.previousSpan))
}

/// Content-only fast path for same-line-count edits inside one region
/// (`applySessionChangedLines`).
@discardableResult
public func applySessionChangedLines<S: Sequence>(
    _ diff: inout FileDiffMetadata,
    changedAdditionLineIndexes: S,
    options: CreatePatchOptions = CreatePatchOptions(),
    previousAdditionLines: [Int: String]? = nil
) throws -> SessionRegionChange? where S.Element == Int {
    let changed = Set(changedAdditionLineIndexes)
    let lines = changed.filter { $0 >= 0 && $0 < diff.additionLines.count }.sorted()
    if lines.isEmpty { return nil }
    let currentLines = diff.additionLines
    let getPreviousAdditionLine: (Int) -> String? = { index in
        changed.contains(index) ? previousAdditionLines?[index] : (index >= 0 && index < currentLines.count ? currentLines[index] : nil)
    }
    let hunks = diff.hunks
    var regionIndex: Int?
    var hunkIndex = 0
    for line in lines {
        while hunkIndex < hunks.count {
            let hunk = hunks[hunkIndex]
            if line < hunkAdditionStart(hunk) + hunk.additionCount { break }
            hunkIndex += 1
        }
        let start = hunkIndex < hunks.count ? hunkAdditionStart(hunks[hunkIndex]) : nil
        if start == nil || line < start! || (regionIndex != nil && regionIndex != hunkIndex) {
            return try rebuildSessionHunks(&diff, options: options, getPreviousAdditionLine: getPreviousAdditionLine)
        }
        regionIndex = hunkIndex
    }
    guard let regionIndex else { return nil }
    if canRetainCanonicalBlocks(diff, lines, regionIndex, previousAdditionLines, options) {
        diff.editSessionDirty = true
        return nil
    }
    return try rebuildSessionHunks(&diff, options: options, getPreviousAdditionLine: getPreviousAdditionLine)
}

/// Balanced change blocks stay canonical when every edited line was and
/// remains unmatched on the old side (`canRetainCanonicalBlocks`).
private func canRetainCanonicalBlocks(_ diff: FileDiffMetadata, _ changedLines: [Int], _ regionIndex: Int, _ previousAdditionLines: [Int: String]?, _ options: CreatePatchOptions) -> Bool {
    guard let previousAdditionLines, !options.ignoreWhitespace, !options.stripTrailingCr else { return false }
    let deletionLineSet = Set(diff.deletionLines.map { Array($0.utf16) })
    let hunk = diff.hunks[regionIndex]
    if hunk.hunkContent.contains(where: isPureChange) { return false }
    for line in changedLines {
        guard let previousLine = previousAdditionLines[line], line < diff.additionLines.count else { return false }
        let additionLine = diff.additionLines[line]
        if deletionLineSet.contains(Array(previousLine.utf16)) || deletionLineSet.contains(Array(additionLine.utf16)) { return false }
        let inside = hunk.hunkContent.contains { content in
            guard case .change(let change) = content else { return false }
            return change.additions == change.deletions && line >= change.additionLineIndex && line < change.additionLineIndex + change.additions
        }
        if !inside { return false }
    }
    return true
}

private func isPureChange(_ content: HunkContent) -> Bool {
    guard case .change(let change) = content else { return false }
    return change.additions == 0 || change.deletions == 0
}

/// Keeps expansion at the surviving outer edges of rebuilt gaps
/// (`remapExpandedHunksForRegionChange`).
public func remapExpandedHunksForRegionChange(_ expandedHunks: [Int: HunkExpansionRegion], _ change: SessionRegionChange) -> [Int: HunkExpansionRegion] {
    var remapped: [Int: HunkExpansionRegion] = [:]
    let regions = change.regions
    for key in 0 ... regions.count {
        let previous = key > 0 ? regions[key - 1] : nil
        let next = key < regions.count ? regions[key] : nil
        let fromStartSource = key == 0 ? expandedHunks[0] : previous.flatMap { expandedHunks[$0.lastIndex + 1] }
        let fromEndSource = next.flatMap { expandedHunks[$0.firstIndex] }
        let fromStart = fromStartSource?.fromStart ?? 0
        let fromEnd = fromEndSource?.fromEnd ?? 0
        if fromStart > 0 || fromEnd > 0 {
            remapped[key] = HunkExpansionRegion(fromStart: fromStart, fromEnd: fromEnd)
        }
    }
    return remapped
}

/// An expanded gap-edge slice in old-side coordinates, `[start, end)`.
public typealias ExpansionAnchorRange = (start: Int, end: Int)

/// Snapshots expanded gap edges before the exit recompute
/// (`captureExpansionAnchors`).
public func captureExpansionAnchors(_ diff: FileDiffMetadata, _ expandedHunks: [Int: HunkExpansionRegion], collapsedContextThreshold: Int) throws -> [ExpansionAnchorRange] {
    var anchors: [ExpansionAnchorRange] = []
    if diff.isPartial { return anchors }
    for (hunkIndex, hunk) in diff.hunks.enumerated() {
        let region = getExpandedRegion(isPartial: diff.isPartial, rangeSize: hunk.collapsedBefore, expandedHunks: .regions(expandedHunks), hunkIndex: hunkIndex, collapsedContextThreshold: collapsedContextThreshold)
        if region.rangeSize <= collapsedContextThreshold { continue }
        let gapEnd = hunkDeletionStart(hunk)
        let gapStart = gapEnd - region.rangeSize
        if region.fromStart > 0 { anchors.append((gapStart, gapStart + region.fromStart)) }
        if region.fromEnd > 0 { anchors.append((gapEnd - region.fromEnd, gapEnd)) }
    }
    if let trailing = try getTrailingExpandedRegion(fileDiff: diff, hunkIndex: diff.hunks.count - 1, expandedHunks: .regions(expandedHunks), collapsedContextThreshold: collapsedContextThreshold, errorPrefix: "captureExpansionAnchors"),
       trailing.fromStart > 0, trailing.rangeSize > collapsedContextThreshold, let last = diff.hunks.last
    {
        let gapStart = hunkDeletionStart(last) + last.deletionCount
        anchors.append((gapStart, gapStart + trailing.fromStart))
    }
    return anchors
}

/// Rebuilds gap expansion from anchors (`rebuildExpansionFromAnchors`).
public func rebuildExpansionFromAnchors(_ diff: FileDiffMetadata, _ anchors: [ExpansionAnchorRange]) -> [Int: HunkExpansionRegion] {
    var rebuilt: [Int: HunkExpansionRegion] = [:]
    if anchors.isEmpty { return rebuilt }
    func applyGap(_ key: Int, _ gapStart: Int, _ gapEnd: Int) {
        if gapEnd <= gapStart { return }
        var fromStart = 0
        var fromEnd = 0
        for anchor in anchors {
            if anchor.end <= gapStart || anchor.start >= gapEnd { continue }
            if anchor.start <= gapStart { fromStart = max(fromStart, min(anchor.end, gapEnd) - gapStart) }
            if anchor.end >= gapEnd { fromEnd = max(fromEnd, gapEnd - max(anchor.start, gapStart)) }
        }
        if fromStart > 0 || fromEnd > 0 {
            rebuilt[key] = HunkExpansionRegion(fromStart: fromStart, fromEnd: fromEnd)
        }
    }
    for (hunkIndex, hunk) in diff.hunks.enumerated() {
        let gapEnd = hunkDeletionStart(hunk)
        applyGap(hunkIndex, gapEnd - max(hunk.collapsedBefore, 0), gapEnd)
    }
    if let last = diff.hunks.last, !diff.isPartial, !diff.deletionLines.isEmpty {
        applyGap(diff.hunks.count, hunkDeletionStart(last) + last.deletionCount, diff.deletionLines.count)
    }
    return rebuilt
}

/// Recomputes session hunks in full at session end and clears
/// `editSessionDirty`; true when a recompute ran (`finishEditSessionForDiff`).
@discardableResult
public func finishEditSessionForDiff(_ diff: inout FileDiffMetadata, options: CreatePatchOptions = CreatePatchOptions()) -> Bool {
    guard diff.editSessionDirty == true else { return false }
    diff.editSessionDirty = nil
    // The empty editor row only hosts a caret; it is not file content.
    if diff.additionLines.count <= 1, diff.additionLines.joined().isEmpty {
        recomputeDiffHunks(&diff, options: options)
    } else {
        recomputeDiffHunksForEdit(&diff, options: options)
    }
    return true
}

/// Parses old/current once, slides new or edited blank changes up, and
/// extracts change blocks (`parseSessionChangeBlocks`).
private func parseSessionChangeBlocks(_ diff: FileDiffMetadata, _ options: CreatePatchOptions, _ getPreviousAdditionLine: ((Int) -> String?)?) throws -> [ChangeContent] {
    if findDivergenceCore(diff.deletionLines, diff.additionLines) == nil { return [] }
    var parsed = try parseDiffFromFile(
        oldFile: FileContents(name: diff.prevName ?? diff.name, contents: diff.deletionLines.joined()),
        newFile: FileContents(name: diff.name, contents: diff.additionLines.joined(), lang: diff.lang),
        options: options
    )
    var previousBlocks: [Int: ChangeContent]?
    let parsedAdditionLines = parsed.additionLines
    let resolveSlide: (ChangeContent, Int) -> Int = { block, maxSlide in
        if previousBlocks == nil { previousBlocks = collectPureChangeBlocks(diff.hunks) }
        for offset in stride(from: 0, through: maxSlide, by: 1) {
            guard let previous = previousBlocks?[block.deletionLineIndex - offset],
                  previous.additions == block.additions, previous.deletions == block.deletions
            else { continue }
            if block.additions > 0, let getPreviousAdditionLine {
                for line in 0 ..< block.additions {
                    let index = block.additionLineIndex + line
                    let current = index >= 0 && index < parsedAdditionLines.count ? parsedAdditionLines[index] : nil
                    let before = getPreviousAdditionLine(previous.additionLineIndex + line)
                    // JS `!==`: two missing values are equal.
                    let same: Bool
                    if let before, let current {
                        same = exactEqual(before, current)
                    } else {
                        same = before == nil && current == nil
                    }
                    if !same { return maxSlide }
                }
            }
            return offset
        }
        return maxSlide
    }
    var blocks: [ChangeContent] = []
    var coveredAdditions = 0
    var coveredDeletions = 0
    for index in parsed.hunks.indices {
        slideBlankBoundaryBlocksUp(&parsed.hunks[index], additionLines: parsed.additionLines, deletionLines: parsed.deletionLines, resolveSlide: resolveSlide)
        let hunk = parsed.hunks[index]
        let contextLines = hunk.additionCount > 0 ? hunk.additionLineIndex - coveredAdditions : hunk.deletionLineIndex - coveredDeletions
        coveredAdditions += contextLines
        coveredDeletions += contextLines
        for content in hunk.hunkContent {
            switch content {
            case .context(let context):
                coveredAdditions += context.lines
                coveredDeletions += context.lines
            case .change(var block):
                if block.additions == 0 { block.additionLineIndex = coveredAdditions }
                if block.deletions == 0 { block.deletionLineIndex = coveredDeletions }
                blocks.append(block)
                coveredAdditions += block.additions
                coveredDeletions += block.deletions
            }
        }
    }
    return blocks
}

/// Pure insert/delete blocks keyed by old-side index.
private func collectPureChangeBlocks(_ hunks: [Hunk]) -> [Int: ChangeContent] {
    var blocks: [Int: ChangeContent] = [:]
    for hunk in hunks {
        for content in hunk.hunkContent {
            if case .change(let change) = content, change.additions == 0 || change.deletions == 0 {
                blocks[change.deletionLineIndex] = change
            }
        }
    }
    return blocks
}

/// Co-walks canonical blocks and previous regions (`buildRegionPlans`).
private func buildRegionPlans(_ previousHunks: [Hunk], _ blocks: [ChangeContent], _ deletionLineCount: Int) -> [RegionPlan] {
    let previousPlans = previousHunks.enumerated().map { index, hunk -> RegionPlan in
        let start = hunkDeletionStart(hunk)
        return RegionPlan(deletionStart: start, deletionEnd: start + hunk.deletionCount, blocks: [], previousSpan: .init(firstIndex: index, lastIndex: index))
    }
    var plans: [RegionPlan] = []
    var previousIndex = 0
    for block in blocks {
        let blockStart = block.deletionLineIndex
        let blockEnd = blockStart + block.deletions
        while previousIndex < previousPlans.count, previousPlans[previousIndex].deletionEnd < blockStart {
            plans.append(previousPlans[previousIndex])
            previousIndex += 1
        }
        var plan: RegionPlan?
        if let last = plans.last, blockStart <= last.deletionEnd, blockEnd >= last.deletionStart {
            plan = plans.removeLast()
        }
        while previousIndex < previousPlans.count, previousPlans[previousIndex].deletionStart <= blockEnd {
            plan = mergeRegionPlans(plan, previousPlans[previousIndex])
            previousIndex += 1
        }
        if plan == nil {
            var deletionStart = blockStart
            var deletionEnd = blockEnd
            if block.deletions == 0 || block.additions == 0, deletionLineCount > block.deletions {
                let previousEnd = plans.last?.deletionEnd ?? 0
                let nextStart = previousIndex < previousPlans.count ? previousPlans[previousIndex].deletionStart : deletionLineCount
                if blockStart > previousEnd {
                    deletionStart -= 1
                } else if blockEnd < nextStart {
                    deletionEnd += 1
                }
            }
            plan = RegionPlan(deletionStart: deletionStart, deletionEnd: deletionEnd, blocks: [], previousSpan: nil)
        }
        plan!.deletionStart = min(plan!.deletionStart, blockStart)
        plan!.deletionEnd = max(plan!.deletionEnd, blockEnd)
        plan!.blocks.append(block)
        plans.append(plan!)
    }
    while previousIndex < previousPlans.count {
        plans.append(previousPlans[previousIndex])
        previousIndex += 1
    }
    return plans
}

private func mergeRegionPlans(_ target: RegionPlan?, _ source: RegionPlan) -> RegionPlan {
    guard var target else { return source }
    target.deletionStart = min(target.deletionStart, source.deletionStart)
    target.deletionEnd = max(target.deletionEnd, source.deletionEnd)
    target.blocks.append(contentsOf: source.blocks)
    if let span = source.previousSpan {
        var merged = target.previousSpan ?? span
        merged.firstIndex = min(merged.firstIndex, span.firstIndex)
        merged.lastIndex = max(merged.lastIndex, span.lastIndex)
        target.previousSpan = merged
    }
    return target
}

/// One paired-context walk builds every region's hunk (`buildRegionHunks`).
private func buildRegionHunks(_ diff: FileDiffMetadata, _ plans: [RegionPlan]) throws -> [Hunk] {
    var hunks: [Hunk] = []
    var deletionCursor = 0
    var additionCursor = 0
    for plan in plans {
        let contextBefore = plan.deletionStart - deletionCursor
        if contextBefore < 0 { throw DiffsError("buildRegionHunks: overlapping old-side regions") }
        deletionCursor += contextBefore
        additionCursor += contextBefore
        let additionStart = additionCursor
        var hunkContent: [HunkContent] = []
        for block in plan.blocks {
            let deletionContext = block.deletionLineIndex - deletionCursor
            let additionContext = block.additionLineIndex - additionCursor
            if deletionContext < 0 || deletionContext != additionContext {
                throw DiffsError("buildRegionHunks: canonical block context mismatch")
            }
            pushContext(&hunkContent, deletionContext, additionCursor, deletionCursor)
            deletionCursor += deletionContext
            additionCursor += additionContext
            hunkContent.append(.change(block))
            deletionCursor += block.deletions
            additionCursor += block.additions
        }
        let trailingContext = plan.deletionEnd - deletionCursor
        if trailingContext < 0 { throw DiffsError("buildRegionHunks: block exceeds its old-side region") }
        pushContext(&hunkContent, trailingContext, additionCursor, deletionCursor)
        deletionCursor += trailingContext
        additionCursor += trailingContext
        hunks.append(createRegionHunk(additionStart: additionStart, additionEnd: additionCursor, deletionStart: plan.deletionStart, deletionEnd: plan.deletionEnd, hunkContent))
    }
    if diff.deletionLines.count - deletionCursor != diff.additionLines.count - additionCursor {
        throw DiffsError("buildRegionHunks: trailing context mismatch")
    }
    return hunks
}

private func createRegionHunk(additionStart: Int, additionEnd: Int, deletionStart: Int, deletionEnd: Int, _ hunkContent: [HunkContent]) -> Hunk {
    let additionCount = additionEnd - additionStart
    let deletionCount = deletionEnd - deletionStart
    var additionLines = 0
    var deletionLines = 0
    for content in hunkContent {
        if case .change(let change) = content {
            additionLines += change.additions
            deletionLines += change.deletions
        }
    }
    var hunk = Hunk(
        collapsedBefore: 0,
        additionStart: unifiedStart(additionStart, additionCount),
        additionCount: additionCount,
        additionLines: additionLines,
        additionLineIndex: unifiedLineIndex(additionStart, additionCount),
        deletionStart: unifiedStart(deletionStart, deletionCount),
        deletionCount: deletionCount,
        deletionLines: deletionLines,
        deletionLineIndex: unifiedLineIndex(deletionStart, deletionCount),
        hunkContent: hunkContent,
        hunkContext: nil,
        hunkSpecs: "@@ -\(unifiedStart(deletionStart, deletionCount)),\(deletionCount) +\(unifiedStart(additionStart, additionCount)),\(additionCount) @@",
        splitLineStart: 0,
        splitLineCount: 0,
        unifiedLineStart: 0,
        unifiedLineCount: 0,
        noEOFCRDeletions: false,
        noEOFCRAdditions: false
    )
    recomputeHunkRenderLineCounts(&hunk)
    return hunk
}

private func pushContext(_ content: inout [HunkContent], _ lines: Int, _ additionLineIndex: Int, _ deletionLineIndex: Int) {
    if lines > 0 {
        content.append(.context(ContextContent(lines: lines, additionLineIndex: additionLineIndex, deletionLineIndex: deletionLineIndex)))
    }
}

private func hasRegionOrSplitLayoutChanged(_ previous: [Hunk], _ next: [Hunk]) -> Bool {
    if previous.count != next.count { return true }
    for (a, b) in zip(previous, next) {
        if hunkDeletionStart(a) != hunkDeletionStart(b) || a.deletionCount != b.deletionCount
            || hunkAdditionStart(a) != hunkAdditionStart(b) || a.additionCount != b.additionCount
            || a.splitLineCount != b.splitLineCount || splitRowMapping(a) != splitRowMapping(b)
        {
            return true
        }
    }
    return false
}

private struct SplitRow: Equatable {
    var deletion: Int?
    var addition: Int?
}

private func splitRowMapping(_ hunk: Hunk) -> [SplitRow] {
    var rows: [SplitRow] = []
    for content in hunk.hunkContent {
        switch content {
        case .context(let context):
            for offset in 0 ..< max(0, context.lines) {
                rows.append(SplitRow(deletion: context.deletionLineIndex + offset, addition: context.additionLineIndex + offset))
            }
        case .change(let change):
            for offset in 0 ..< max(change.deletions, change.additions) {
                rows.append(SplitRow(
                    deletion: offset < change.deletions ? change.deletionLineIndex + offset : nil,
                    addition: offset < change.additions ? change.additionLineIndex + offset : nil
                ))
            }
        }
    }
    return rows
}

private func hunkAdditionStart(_ hunk: Hunk) -> Int {
    getHunkSideStartBoundary(hunk.additionStart, hunk.additionCount)
}

private func hunkDeletionStart(_ hunk: Hunk) -> Int {
    getHunkSideStartBoundary(hunk.deletionStart, hunk.deletionCount)
}

private func unifiedStart(_ lineIndex: Int, _ count: Int) -> Int {
    count == 0 ? lineIndex : lineIndex + 1
}

private func unifiedLineIndex(_ lineIndex: Int, _ count: Int) -> Int {
    count == 0 ? lineIndex - 1 : lineIndex
}

private func finalizeSessionHunks(_ diff: inout FileDiffMetadata) {
    recomputeDiffRenderLineCounts(&diff)
    for index in diff.hunks.indices {
        syncHunkNoEOFCRFromFullFile(&diff, hunkIndex: index)
    }
}
