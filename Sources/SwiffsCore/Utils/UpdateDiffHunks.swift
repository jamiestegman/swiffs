// Port of `updateDiffHunks.ts`: keeps hunk metadata in sync while the
// addition side of a diff is edited.

import Foundation

/// Rebuilds all hunk metadata (and both line arrays) from the current
/// deletion/addition lines (`recomputeDiffHunks`).
public func recomputeDiffHunks(_ diff: inout FileDiffMetadata, options: CreatePatchOptions = CreatePatchOptions()) {
    let recomputed = try? parseDiffFromFile(
        oldFile: FileContents(name: diff.prevName ?? diff.name, contents: diff.deletionLines.joined()),
        newFile: FileContents(name: diff.name, contents: diff.additionLines.joined(), lang: diff.lang),
        options: options
    )
    guard let recomputed else { return }
    applyRecomputed(&diff, recomputed, additionLines: recomputed.additionLines)
}

private func applyRecomputed(_ diff: inout FileDiffMetadata, _ recomputed: FileDiffMetadata, additionLines: [String]) {
    diff.hunks = recomputed.hunks
    diff.splitLineCount = recomputed.splitLineCount
    diff.unifiedLineCount = recomputed.unifiedLineCount
    diff.additionLines = additionLines
    diff.deletionLines = recomputed.deletionLines
    diff.type = recomputed.type
}

/// Placeholder addition contents that diff as one top-aligned change row per
/// line (`buildTopAlignedAdditionSentinel`).
private func buildTopAlignedAdditionSentinel(_ lineCount: Int, _ deletionContents: String) -> String {
    let count = max(lineCount, 1)
    var sentinel = (0 ..< count).map { String(repeating: " ", count: $0 + 1) + "\n" }.joined()
    if isExactlyEqual(sentinel, deletionContents) {
        sentinel = (0 ..< count).map { "\u{0000}" + String(repeating: " ", count: $0) + "\n" }.joined()
    }
    return sentinel
}

private func isExactlyEqual(_ a: String, _ b: String) -> Bool {
    a.utf16.elementsEqual(b.utf16)
}

/// `line.trim().length > 0` for every line fails.
private func hasOnlyBlankAdditionContents(_ additionLines: [String]) -> Bool {
    for line in additionLines where !jsTrim(line).isEmpty {
        return false
    }
    return true
}

/// `String.prototype.trim` (ECMAScript whitespace and line terminators).
func jsTrim(_ value: String) -> Substring {
    func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000 ... 0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }
    let scalars = value.unicodeScalars
    guard let first = scalars.firstIndex(where: { !isJSWhitespace($0) }),
          let last = scalars.lastIndex(where: { !isJSWhitespace($0) })
    else { return "" }
    return Substring(scalars[first ... last])
}

/// After delete-all the editable side is blank and shorter than the deletion
/// side (`shouldTopAlignAdditionRecompute`).
public func shouldTopAlignAdditionRecompute(_ diff: FileDiffMetadata, additionLines: [String]) -> Bool {
    !additionLines.isEmpty
        && additionLines.count < diff.deletionLines.count
        && hasOnlyBlankAdditionContents(additionLines)
}

/// Rebuilds hunks while keeping the editable addition rows top-aligned in
/// split view; `additionLines` stays the source of truth
/// (`recomputeTopAlignedAdditionDiff`).
public func recomputeTopAlignedAdditionDiff(_ diff: inout FileDiffMetadata, additionLines: [String], options: CreatePatchOptions = CreatePatchOptions()) {
    let deletionContents = diff.deletionLines.joined()
    let sentinel = buildTopAlignedAdditionSentinel(additionLines.count, deletionContents)
    let recomputed = try? parseDiffFromFile(
        oldFile: FileContents(name: diff.prevName ?? diff.name, contents: deletionContents),
        newFile: FileContents(name: diff.name, contents: sentinel, lang: diff.lang),
        options: options
    )
    guard let recomputed else { return }
    applyRecomputed(&diff, recomputed, additionLines: additionLines)
}

/// Rebuilds hunks when the editable side has no text
/// (`recomputeEmptyDocumentDiff`).
public func recomputeEmptyDocumentDiff(_ diff: inout FileDiffMetadata, options: CreatePatchOptions = CreatePatchOptions()) {
    recomputeTopAlignedAdditionDiff(&diff, additionLines: [""], options: options)
}

/// Rebuilds hunks after an edit, top-aligning sparse addition sides when
/// needed (`recomputeDiffHunksForEdit`).
public func recomputeDiffHunksForEdit(_ diff: inout FileDiffMetadata, options: CreatePatchOptions = CreatePatchOptions()) {
    if diff.additionLines.isEmpty {
        recomputeEmptyDocumentDiff(&diff, options: options)
        return
    }
    if shouldTopAlignAdditionRecompute(diff, additionLines: diff.additionLines) {
        recomputeTopAlignedAdditionDiff(&diff, additionLines: diff.additionLines, options: options)
        return
    }
    let additionLines = diff.additionLines
    recomputeDiffHunks(&diff, options: options)
    preserveTrailingEditorBlankLine(&diff, additionLines: additionLines)
}

/// Re-adds the editor's phantom trailing empty line as an addition row when
/// the last change block can absorb it (`preserveTrailingEditorBlankLine`).
public func preserveTrailingEditorBlankLine(_ diff: inout FileDiffMetadata, additionLines: [String]) {
    guard additionLines.count > 1, additionLines.last == "" else { return }
    let extraLineCount = additionLines.count - diff.additionLines.count
    guard extraLineCount > 0 else { return }
    let extraAdditionLineIndex = diff.additionLines.count
    guard let lastHunkIndex = diff.hunks.indices.last else { return }
    let lastHunk = diff.hunks[lastHunkIndex]
    guard getHunkSideEndBoundary(lastHunk.additionStart, lastHunk.additionCount) == extraAdditionLineIndex else { return }
    for (contentIndex, content) in lastHunk.hunkContent.enumerated() {
        guard case .change(var change) = content,
              change.additions < change.deletions,
              change.additionLineIndex + change.additions == extraAdditionLineIndex
        else { continue }
        diff.additionLines = additionLines
        change.additions += extraLineCount
        diff.hunks[lastHunkIndex].hunkContent[contentIndex] = .change(change)
        diff.hunks[lastHunkIndex].additionCount += extraLineCount
        diff.hunks[lastHunkIndex].additionLines += extraLineCount
        recomputeDiffRenderLineCounts(&diff)
        return
    }
}

/// Updates hunk metadata after addition lines change, re-parsing only the
/// affected hunks when possible (`updateDiffHunks`).
public func updateDiffHunks<S: Sequence>(
    _ diff: inout FileDiffMetadata,
    changedAdditionLineIndexes: S,
    options: CreatePatchOptions = CreatePatchOptions()
) where S.Element == Int {
    if diff.isPartial || diff.deletionLines.count != diff.additionLines.count {
        recomputeDiffHunks(&diff, options: options)
        return
    }
    let changedLines = Array(changedAdditionLineIndexes)
    if changedLines.isEmpty { return }
    for line in changedLines {
        guard line >= 0, line < diff.additionLines.count, line < diff.deletionLines.count else {
            recomputeDiffHunks(&diff, options: options)
            return
        }
        // Restoring a line to the old side can merge/split hunks across
        // context windows.
        if isExactlyEqual(cleanLastNewline(diff.additionLines[line]), cleanLastNewline(diff.deletionLines[line])) {
            recomputeDiffHunks(&diff, options: options)
            return
        }
    }

    guard let affected = getAffectedHunkIndexes(diff, changedLines), !affected.isEmpty else {
        recomputeDiffHunks(&diff, options: options)
        return
    }
    for hunkIndex in affected {
        if !reparseHunkRegion(&diff, hunkIndex: hunkIndex, options: options) {
            recomputeDiffHunks(&diff, options: options)
            return
        }
    }
    recomputeDiffRenderLineCounts(&diff)
    if hasTrailingContextMismatch(diff) {
        recomputeDiffHunks(&diff, options: options)
    }
}

/// Hunk indexes in insertion order (JS `Set` iteration order); nil when a
/// line is outside every hunk.
private func getAffectedHunkIndexes(_ diff: FileDiffMetadata, _ lines: [Int]) -> [Int]? {
    var indexes: [Int] = []
    for line in lines {
        guard let hunkIndex = diff.hunks.firstIndex(where: { line >= $0.additionLineIndex && line < $0.additionLineIndex + $0.additionCount }) else {
            return nil
        }
        if !indexes.contains(hunkIndex) { indexes.append(hunkIndex) }
    }
    return indexes
}

private func jsSlice(_ lines: [String], _ start: Int, _ end: Int) -> ArraySlice<String> {
    let count = lines.count
    let lower = start < 0 ? max(count + start, 0) : min(start, count)
    let upper = end < 0 ? max(count + end, 0) : min(end, count)
    return lower < upper ? lines[lower ..< upper] : []
}

private func reparseHunkRegion(_ diff: inout FileDiffMetadata, hunkIndex: Int, options: CreatePatchOptions) -> Bool {
    guard hunkIndex < diff.hunks.count else { return false }
    let hunk = diff.hunks[hunkIndex]
    let deletionSlice = jsSlice(diff.deletionLines, hunk.deletionLineIndex, hunk.deletionLineIndex + hunk.deletionCount)
    let additionSlice = jsSlice(diff.additionLines, hunk.additionLineIndex, hunk.additionLineIndex + hunk.additionCount)
    var regionOptions = options
    regionOptions.context = 0
    guard let reparsed = try? parseDiffFromFile(
        oldFile: FileContents(name: diff.prevName ?? diff.name, contents: deletionSlice.joined()),
        newFile: FileContents(name: diff.name, contents: additionSlice.joined(), lang: diff.lang),
        options: regionOptions
    ), reparsed.hunks.count == 1 else { return false }
    applyReparsedHunk(&diff.hunks[hunkIndex], reparsed.hunks[0])
    syncHunkNoEOFCRFromFullFile(&diff, hunkIndex: hunkIndex)
    return true
}

/// Only the last hunk can lack a trailing newline
/// (`syncHunkNoEOFCRFromFullFile`).
public func syncHunkNoEOFCRFromFullFile(_ diff: inout FileDiffMetadata, hunkIndex: Int) {
    guard hunkIndex >= 0, hunkIndex < diff.hunks.count else { return }
    guard hunkIndex == diff.hunks.count - 1 else {
        diff.hunks[hunkIndex].noEOFCRAdditions = false
        diff.hunks[hunkIndex].noEOFCRDeletions = false
        return
    }
    func lacksNewline(_ line: String?) -> Bool {
        guard let line, !line.isEmpty else { return false }
        return !line.hasSuffix("\n") && line.unicodeScalars.last != "\n"
    }
    diff.hunks[hunkIndex].noEOFCRAdditions = lacksNewline(diff.additionLines.last)
    diff.hunks[hunkIndex].noEOFCRDeletions = lacksNewline(diff.deletionLines.last)
}

private func applyReparsedHunk(_ target: inout Hunk, _ parsed: Hunk) {
    let additionOffset = target.additionLineIndex
    let deletionOffset = target.deletionLineIndex
    target.hunkContent = parsed.hunkContent.map { offsetHunkContent($0, additionOffset: additionOffset, deletionOffset: deletionOffset) }
    target.additionLineIndex = additionOffset + parsed.additionLineIndex
    target.additionStart += parsed.additionLineIndex
    target.additionCount = parsed.additionCount
    target.additionLines = parsed.additionLines
    if parsed.deletionLineIndex >= 0 {
        target.deletionLineIndex = deletionOffset + parsed.deletionLineIndex
        target.deletionStart += parsed.deletionLineIndex
    }
    target.deletionCount = parsed.deletionCount
    target.deletionLines = parsed.deletionLines
    target.noEOFCRAdditions = parsed.noEOFCRAdditions
    target.noEOFCRDeletions = parsed.noEOFCRDeletions
    recomputeHunkRenderLineCounts(&target)
}

public func offsetHunkContent(_ content: HunkContent, additionOffset: Int, deletionOffset: Int) -> HunkContent {
    var content = content
    content.additionLineIndex += additionOffset
    content.deletionLineIndex += deletionOffset
    return content
}

public func recomputeHunkRenderLineCounts(_ hunk: inout Hunk) {
    var split = 0
    var unified = 0
    for content in hunk.hunkContent {
        switch content {
        case .context(let context):
            split += context.lines
            unified += context.lines
        case .change(let change):
            split += max(change.additions, change.deletions)
            unified += change.additions + change.deletions
        }
    }
    hunk.splitLineCount = split
    hunk.unifiedLineCount = unified
}

public func recomputeDiffRenderLineCounts(_ diff: inout FileDiffMetadata) {
    var splitTotal = 0
    var unifiedTotal = 0
    var lastHunkAdditionEnd = 0
    for index in diff.hunks.indices {
        var hunk = diff.hunks[index]
        hunk.collapsedBefore = max(getHunkSideStartBoundary(hunk.additionStart, hunk.additionCount) - lastHunkAdditionEnd, 0)
        hunk.splitLineStart = splitTotal + hunk.collapsedBefore
        hunk.unifiedLineStart = unifiedTotal + hunk.collapsedBefore
        recomputeHunkRenderLineCounts(&hunk)
        splitTotal += hunk.collapsedBefore + hunk.splitLineCount
        unifiedTotal += hunk.collapsedBefore + hunk.unifiedLineCount
        lastHunkAdditionEnd = getHunkSideEndBoundary(hunk.additionStart, hunk.additionCount)
        diff.hunks[index] = hunk
    }
    if let last = diff.hunks.last {
        let collapsedAfter = max(diff.additionLines.count - getHunkSideEndBoundary(last.additionStart, last.additionCount), 0)
        splitTotal += collapsedAfter
        unifiedTotal += collapsedAfter
    }
    diff.splitLineCount = splitTotal
    diff.unifiedLineCount = unifiedTotal
}
