// Port of `packages/diffs/src/utils/parseMergeConflictDiffFromFile.ts`.
//
// Parses a file containing git merge conflict markers (<<<<<<< / ======= /
// >>>>>>>) into a synthetic unified diff: "current" lines become deletions
// and "incoming" lines become additions. Lines outside conflicts (and optional
// diff3 "base" sections) become shared context. The result also carries one
// action per conflict anchoring it to the hunk structure, plus marker rows for
// the UI.

import Foundation

public struct MergeConflictMarkerLines: Hashable, Sendable, Codable {
    public var start: String
    public var base: String?
    public var separator: String
    public var end: String
}

/// `MergeConflictDiffAction`.
public struct MergeConflictDiffAction: Hashable, Sendable, Codable {
    public var conflict: MergeConflictRegion
    public var conflictIndex: Int
    public var markerLines: MergeConflictMarkerLines
    // ProcessFileConflictData
    public var hunkIndex: Int
    public var startContentIndex: Int
    public var endContentIndex: Int
    public var currentContentIndex: Int?
    public var baseContentIndex: Int?
    public var incomingContentIndex: Int?
    public var endMarkerContentIndex: Int

    public var conflictData: ProcessFileConflictData {
        ProcessFileConflictData(
            hunkIndex: hunkIndex,
            startContentIndex: startContentIndex,
            endContentIndex: endContentIndex,
            currentContentIndex: currentContentIndex,
            baseContentIndex: baseContentIndex,
            incomingContentIndex: incomingContentIndex,
            endMarkerContentIndex: endMarkerContentIndex
        )
    }
}

public struct ParseMergeConflictDiffFromFileResult: Sendable {
    public var fileDiff: FileDiffMetadata
    public var currentFile: FileContents
    public var incomingFile: FileContents
    public var actions: [MergeConflictDiffAction?]
    public var markerRows: [MergeConflictMarkerRow]
}

private enum MergeConflictStage {
    case current, base, incoming
}

private enum MergeConflictMarkerType {
    case start, base, separator, end
}

private enum ContextFlushMode {
    case beforeChange, leading, trailing
}

private final class HunkBuilder {
    var additionStart: Int
    var deletionStart: Int
    var additionCount = 0
    var deletionCount = 0
    var additionLines = 0
    var deletionLines = 0
    var additionLineIndex: Int
    var deletionLineIndex: Int
    var hunkContent: [HunkContent] = []
    var contextBufferAdditionStart: Int
    var contextBufferDeletionStart: Int
    var contextBufferCount = 0
    /// buffer offset -> conflictIndex for base-section context lines.
    var contextBufferBaseConflicts: [(offset: Int, conflictIndex: Int)]?

    init(additionStart: Int, deletionStart: Int) {
        self.additionStart = additionStart
        self.deletionStart = deletionStart
        additionLineIndex = max(additionStart - 1, 0)
        deletionLineIndex = max(deletionStart - 1, 0)
        contextBufferAdditionStart = max(additionStart - 1, 0)
        contextBufferDeletionStart = max(deletionStart - 1, 0)
    }
}

private final class ConflictFrame {
    let conflictIndex: Int
    var stage: MergeConflictStage = .current
    let startLineIndex: Int
    var baseMarkerLineIndex: Int?
    var separatorLineIndex: Int?
    var startMarker: String
    var baseMarker: String?
    var separatorMarker: String?

    init(conflictIndex: Int, startLineIndex: Int, startMarker: String) {
        self.conflictIndex = conflictIndex
        self.startLineIndex = startLineIndex
        self.startMarker = startMarker
    }
}

private final class ParseState {
    var deletionLines: [String] = []
    var additionLines: [String] = []
    var conflictStack: [ConflictFrame] = []
    var builders: [MergeConflictDiffAction?] = []
    var completed: [Bool] = []
    var actions: [MergeConflictDiffAction?] = []
    var hunks: [Hunk] = []
    var nextConflictIndex = 0
    var splitLineCount = 0
    var unifiedLineCount = 0
    var lastHunkEnd = 0
    var activeHunk: HunkBuilder?
    let maxContextLines: Int
    let maxContextLines2: Int

    init(maxContextLines: Int) {
        self.maxContextLines = maxContextLines
        // Saturates so `Int.max` behaves like JS `Infinity`.
        let (doubled, overflow) = maxContextLines.multipliedReportingOverflow(by: 2)
        maxContextLines2 = overflow ? Int.max : doubled
    }
}

public func getMergeConflictActionAnchor(_ action: MergeConflictDiffAction, fileDiff: FileDiffMetadata) -> (hunkIndex: Int, lineIndex: Int)? {
    guard action.hunkIndex >= 0, action.hunkIndex < fileDiff.hunks.count else { return nil }
    return (action.hunkIndex, getUnifiedLineStartForContent(fileDiff.hunks[action.hunkIndex], action.startContentIndex))
}

/// Parses a file with conflict markers into a diff (`current` → deletions,
/// `incoming` → additions).
public func parseMergeConflictDiffFromFile(_ file: FileContents, maxContextLines requested: Int = 6) throws -> ParseMergeConflictDiffFromFileResult {
    // Never allow maxContextLines to drop below 1 or else things break.
    let s = ParseState(maxContextLines: max(requested, 1))

    // Phase 1: Line-by-line scan.
    let lines = splitWithNewlines(file.contents)
    if !file.contents.isEmpty {
        for (index, line) in lines.enumerated() {
            try processLine(s, String(line), index)
        }
    }

    // Phase 2: Post-loop cleanup.
    if !s.conflictStack.isEmpty {
        throw DiffsError("parseMergeConflictDiffFromFile: unfinished merge conflict marker stack")
    }
    if let hunk = s.activeHunk, !hunk.hunkContent.isEmpty {
        try flushBufferedContext(s, hunk, .trailing)
        finalizeActiveHunk(s)
    }
    for conflictIndex in 0 ..< s.builders.count where !s.completed[conflictIndex] {
        throw DiffsError("parseMergeConflictDiffFromFile: failed to build merge conflict action \(conflictIndex)")
    }

    // Phase 3: Result assembly.
    if let lastHunk = s.hunks.last, !s.additionLines.isEmpty, !s.deletionLines.isEmpty {
        let collapsedAfter = max(s.additionLines.count - getHunkSideEndBoundary(lastHunk.additionStart, lastHunk.additionCount), 0)
        s.splitLineCount += collapsedAfter
        s.unifiedLineCount += collapsedAfter
    }

    let currentContents = s.deletionLines.joined()
    let incomingContents = s.additionLines.joined()
    var currentFile = file
    currentFile.contents = currentContents
    currentFile.cacheKey = file.cacheKey.map { "\($0):merge-conflict-current" }
    var incomingFile = file
    incomingFile.contents = incomingContents
    incomingFile.cacheKey = file.cacheKey.map { "\($0):merge-conflict-incoming" }

    var type: ChangeType = .change
    if incomingContents.isEmpty {
        type = .deleted
    } else if currentContents.isEmpty {
        type = .new
    }

    let fileDiff = FileDiffMetadata(
        name: file.name,
        prevName: nil,
        type: type,
        hunks: s.hunks,
        splitLineCount: s.splitLineCount,
        unifiedLineCount: s.unifiedLineCount,
        isPartial: false,
        deletionLines: s.deletionLines,
        additionLines: s.additionLines,
        cacheKey: file.cacheKey.map { "\($0):merge-conflict-diff" }
    )
    return ParseMergeConflictDiffFromFileResult(
        fileDiff: fileDiff,
        currentFile: currentFile,
        incomingFile: incomingFile,
        actions: s.actions,
        markerRows: buildMergeConflictMarkerRows(fileDiff: fileDiff, actions: s.actions)
    )
}

private func processLine(_ s: ParseState, _ line: String, _ index: Int) throws {
    guard let frame = s.conflictStack.last else {
        // Outside any conflict: only start markers can transition state.
        if line.utf8.first == UInt8(ascii: "<"), getMergeConflictMarkerType(line) == .start {
            handleStartMarker(s, line, index)
            return
        }
        emitContextLine(s, line)
        return
    }
    switch getMergeConflictMarkerType(line) {
    case .start?:
        handleStartMarker(s, line, index)
        return
    case .base?:
        frame.stage = .base
        frame.baseMarkerLineIndex = index
        frame.baseMarker = line
        return
    case .separator?:
        frame.stage = .incoming
        frame.separatorLineIndex = index
        frame.separatorMarker = line
        return
    case .end?:
        let completed = s.conflictStack.removeLast()
        try finalizeConflict(s, completed, index, line)
        return
    case nil:
        break
    }
    switch frame.stage {
    case .current: try emitChangeLine(s, isAddition: false, line, frame.conflictIndex, .current)
    case .base: emitContextLine(s, line, baseConflictIndex: frame.conflictIndex)
    case .incoming: try emitChangeLine(s, isAddition: true, line, frame.conflictIndex, .incoming)
    }
}

private func ensureActiveHunk(_ s: ParseState) -> HunkBuilder {
    if let hunk = s.activeHunk { return hunk }
    let hunk = HunkBuilder(additionStart: s.additionLines.count + 1, deletionStart: s.deletionLines.count + 1)
    s.activeHunk = hunk
    return hunk
}

private func assignConflictContent(_ s: ParseState, _ conflictIndex: Int, _ role: MergeConflictStage, _ contentIndex: Int) throws {
    guard conflictIndex < s.builders.count, var action = s.builders[conflictIndex] else {
        throw DiffsError("parseMergeConflictDiffFromFile: failed to locate conflict action \(conflictIndex)")
    }
    let hunkIndex = s.hunks.count
    if action.hunkIndex < 0 {
        action.hunkIndex = hunkIndex
    } else if action.hunkIndex != hunkIndex {
        throw DiffsError("parseMergeConflictDiffFromFile: conflict \(conflictIndex) spans multiple hunks and cannot be anchored")
    }
    if action.startContentIndex < 0 {
        action.startContentIndex = contentIndex
    }
    action.endContentIndex = contentIndex
    action.endMarkerContentIndex = contentIndex
    switch role {
    case .current:
        if action.currentContentIndex == nil { action.currentContentIndex = contentIndex }
    case .base:
        if action.baseContentIndex == nil { action.baseContentIndex = contentIndex }
    case .incoming:
        action.incomingContentIndex = contentIndex
    }
    s.builders[conflictIndex] = action
}

private func appendChangeLine(_ hunk: HunkBuilder, isAddition: Bool, _ additionLineIndex: Int, _ deletionLineIndex: Int) -> Int {
    if case .change(var last)? = hunk.hunkContent.last {
        if isAddition { last.additions += 1 } else { last.deletions += 1 }
        hunk.hunkContent[hunk.hunkContent.count - 1] = .change(last)
        return hunk.hunkContent.count - 1
    }
    hunk.hunkContent.append(.change(ChangeContent(
        deletions: isAddition ? 0 : 1,
        deletionLineIndex: deletionLineIndex,
        additions: isAddition ? 1 : 0,
        additionLineIndex: additionLineIndex
    )))
    return hunk.hunkContent.count - 1
}

private func flushBufferedContext(_ s: ParseState, _ hunk: HunkBuilder, _ mode: ContextFlushMode) throws {
    var count = hunk.contextBufferCount
    var addStart = hunk.contextBufferAdditionStart
    var delStart = hunk.contextBufferDeletionStart

    if mode == .leading, count > s.maxContextLines {
        let difference = count - s.maxContextLines
        addStart += difference
        delStart += difference
        count = s.maxContextLines
        hunk.additionStart += difference
        hunk.deletionStart += difference
        hunk.additionLineIndex += difference
        hunk.deletionLineIndex += difference
    }
    if mode == .trailing, count > s.maxContextLines {
        count = s.maxContextLines
    }
    if count == 0 {
        hunk.contextBufferCount = 0
        hunk.contextBufferBaseConflicts = nil
        return
    }

    let contentIndex: Int
    if case .context(var last)? = hunk.hunkContent.last {
        last.lines += count
        hunk.hunkContent[hunk.hunkContent.count - 1] = .context(last)
        contentIndex = hunk.hunkContent.count - 1
    } else {
        hunk.hunkContent.append(.context(ContextContent(lines: count, additionLineIndex: addStart, deletionLineIndex: delStart)))
        contentIndex = hunk.hunkContent.count - 1
    }
    hunk.additionCount += count
    hunk.deletionCount += count

    if let baseConflicts = hunk.contextBufferBaseConflicts {
        let bufferStartOffset = addStart - hunk.contextBufferAdditionStart
        for (offset, conflictIndex) in baseConflicts where offset >= bufferStartOffset && offset < bufferStartOffset + count {
            try assignConflictContent(s, conflictIndex, .base, contentIndex)
        }
    }
    hunk.contextBufferCount = 0
    hunk.contextBufferBaseConflicts = nil
}

private func formatHunkRange(_ start: Int, _ count: Int) -> String {
    count == 1 ? "\(start)" : "\(start),\(count)"
}

private func finalizeActiveHunk(_ s: ParseState) {
    guard let hunk = s.activeHunk else { return }
    s.activeHunk = nil
    if hunk.hunkContent.isEmpty { return }

    var hunkSplitLineCount = 0
    var hunkUnifiedLineCount = 0
    for content in hunk.hunkContent {
        switch content {
        case .context(let context):
            hunkSplitLineCount += context.lines
            hunkUnifiedLineCount += context.lines
        case .change(let change):
            hunkSplitLineCount += max(change.additions, change.deletions)
            hunkUnifiedLineCount += change.additions + change.deletions
        }
    }
    // A side that finished with zero lines shifts down to the unified `N,0`
    // convention.
    let additionStart = hunk.additionCount == 0 ? hunk.additionStart - 1 : hunk.additionStart
    let deletionStart = hunk.deletionCount == 0 ? hunk.deletionStart - 1 : hunk.deletionStart
    let collapsedBefore = max(getHunkSideStartBoundary(additionStart, hunk.additionCount) - s.lastHunkEnd, 0)
    s.hunks.append(Hunk(
        collapsedBefore: collapsedBefore,
        additionStart: additionStart,
        additionCount: hunk.additionCount,
        additionLines: hunk.additionLines,
        additionLineIndex: hunk.additionLineIndex,
        deletionStart: deletionStart,
        deletionCount: hunk.deletionCount,
        deletionLines: hunk.deletionLines,
        deletionLineIndex: hunk.deletionLineIndex,
        hunkContent: hunk.hunkContent,
        hunkContext: nil,
        hunkSpecs: "@@ -\(formatHunkRange(deletionStart, hunk.deletionCount)) +\(formatHunkRange(additionStart, hunk.additionCount)) @@\n",
        splitLineStart: s.splitLineCount + collapsedBefore,
        splitLineCount: hunkSplitLineCount,
        unifiedLineStart: s.unifiedLineCount + collapsedBefore,
        unifiedLineCount: hunkUnifiedLineCount,
        noEOFCRDeletions: false,
        noEOFCRAdditions: false
    ))
    s.splitLineCount += collapsedBefore + hunkSplitLineCount
    s.unifiedLineCount += collapsedBefore + hunkUnifiedLineCount
    s.lastHunkEnd = getHunkSideEndBoundary(additionStart, hunk.additionCount)
}

private func splitHunkWithBufferedContext(_ s: ParseState) throws {
    guard let hunk = s.activeHunk else { return }
    let count = hunk.contextBufferCount
    let omittedContextLineCount = count - s.maxContextLines2
    let nextAddStart = hunk.contextBufferAdditionStart + count - s.maxContextLines
    let nextDelStart = hunk.contextBufferDeletionStart + count - s.maxContextLines

    var nextBaseConflicts: [(offset: Int, conflictIndex: Int)]?
    if let baseConflicts = hunk.contextBufferBaseConflicts {
        let tailOffset = count - s.maxContextLines
        for (offset, conflictIndex) in baseConflicts where offset >= tailOffset {
            if nextBaseConflicts == nil { nextBaseConflicts = [] }
            nextBaseConflicts!.append((offset - tailOffset, conflictIndex))
        }
    }

    try flushBufferedContext(s, hunk, .trailing)
    let emittedAdditionCount = hunk.additionCount
    let emittedDeletionCount = hunk.deletionCount
    finalizeActiveHunk(s)

    let next = HunkBuilder(
        additionStart: hunk.additionStart + emittedAdditionCount + omittedContextLineCount,
        deletionStart: hunk.deletionStart + emittedDeletionCount + omittedContextLineCount
    )
    next.contextBufferAdditionStart = nextAddStart
    next.contextBufferDeletionStart = nextDelStart
    next.contextBufferCount = s.maxContextLines
    next.contextBufferBaseConflicts = nextBaseConflicts
    s.activeHunk = next
}

private func emitContextLine(_ s: ParseState, _ line: String, baseConflictIndex: Int = -1) {
    let hunk = ensureActiveHunk(s)
    if hunk.contextBufferCount == 0 {
        hunk.contextBufferAdditionStart = s.additionLines.count
        hunk.contextBufferDeletionStart = s.deletionLines.count
    }
    s.additionLines.append(line)
    s.deletionLines.append(line)
    if baseConflictIndex >= 0 {
        if hunk.contextBufferBaseConflicts == nil { hunk.contextBufferBaseConflicts = [] }
        // Mirrors `Map.set`: a later value for the same offset replaces it.
        if let existing = hunk.contextBufferBaseConflicts!.firstIndex(where: { $0.offset == hunk.contextBufferCount }) {
            hunk.contextBufferBaseConflicts![existing].conflictIndex = baseConflictIndex
        } else {
            hunk.contextBufferBaseConflicts!.append((hunk.contextBufferCount, baseConflictIndex))
        }
    }
    hunk.contextBufferCount += 1
}

private func emitChangeLine(_ s: ParseState, isAddition: Bool, _ line: String, _ conflictIndex: Int, _ role: MergeConflictStage) throws {
    var hunk = ensureActiveHunk(s)
    if !hunk.hunkContent.isEmpty, hunk.contextBufferCount > s.maxContextLines2 {
        try splitHunkWithBufferedContext(s)
        hunk = s.activeHunk!
    }
    try flushBufferedContext(s, hunk, hunk.hunkContent.isEmpty ? .leading : .beforeChange)

    let additionLineIndex = s.additionLines.count
    let deletionLineIndex = s.deletionLines.count
    if isAddition {
        s.additionLines.append(line)
    } else {
        s.deletionLines.append(line)
    }
    let contentIndex = appendChangeLine(hunk, isAddition: isAddition, additionLineIndex, deletionLineIndex)
    if isAddition {
        hunk.additionCount += 1
        hunk.additionLines += 1
    } else {
        hunk.deletionCount += 1
        hunk.deletionLines += 1
    }
    try assignConflictContent(s, conflictIndex, role, contentIndex)
}

private func finalizeConflict(_ s: ParseState, _ frame: ConflictFrame, _ endLineIndex: Int, _ endMarkerLine: String) throws {
    guard let separatorLineIndex = frame.separatorLineIndex, let separatorMarker = frame.separatorMarker else {
        throw DiffsError("parseMergeConflictDiffFromFile: conflict \(frame.conflictIndex) is missing a separator marker")
    }
    guard frame.conflictIndex < s.builders.count, var action = s.builders[frame.conflictIndex] else {
        throw DiffsError("parseMergeConflictDiffFromFile: failed to finalize conflict \(frame.conflictIndex)")
    }
    action.markerLines.separator = separatorMarker
    action.markerLines.end = endMarkerLine
    if let base = frame.baseMarker {
        action.markerLines.base = base
    }
    action.conflict = MergeConflictRegion(
        conflictIndex: frame.conflictIndex,
        startLineIndex: frame.startLineIndex,
        startLineNumber: frame.startLineIndex + 1,
        separatorLineIndex: separatorLineIndex,
        separatorLineNumber: separatorLineIndex + 1,
        endLineIndex: endLineIndex,
        endLineNumber: endLineIndex + 1,
        baseMarkerLineIndex: frame.baseMarkerLineIndex,
        baseMarkerLineNumber: frame.baseMarkerLineIndex.map { $0 + 1 }
    )
    // If one side of the conflict was empty, use the other side as a fallback
    // so the action always has a valid anchor.
    let fallback = action.currentContentIndex ?? action.incomingContentIndex
    if action.currentContentIndex == nil { action.currentContentIndex = fallback }
    if action.incomingContentIndex == nil { action.incomingContentIndex = fallback }
    if action.startContentIndex < 0, let fallback { action.startContentIndex = fallback }
    if action.endContentIndex < 0, let fallback { action.endContentIndex = fallback }
    if action.endMarkerContentIndex < 0, let fallback { action.endMarkerContentIndex = fallback }
    if action.hunkIndex < 0 || action.startContentIndex < 0 || action.endContentIndex < 0 || action.endMarkerContentIndex < 0 {
        throw DiffsError("parseMergeConflictDiffFromFile: failed to anchor merge conflict \(frame.conflictIndex)")
    }
    while s.actions.count <= action.conflictIndex { s.actions.append(nil) }
    s.actions[action.conflictIndex] = action
    s.builders[frame.conflictIndex] = action
    s.completed[frame.conflictIndex] = true
}

private func handleStartMarker(_ s: ParseState, _ line: String, _ lineIndex: Int) {
    let conflictIndex = s.nextConflictIndex
    s.nextConflictIndex += 1
    s.conflictStack.append(ConflictFrame(conflictIndex: conflictIndex, startLineIndex: lineIndex, startMarker: line))
    let action = MergeConflictDiffAction(
        conflict: MergeConflictRegion(
            conflictIndex: conflictIndex,
            startLineIndex: lineIndex,
            startLineNumber: lineIndex + 1,
            separatorLineIndex: lineIndex,
            separatorLineNumber: lineIndex + 1,
            endLineIndex: lineIndex,
            endLineNumber: lineIndex + 1
        ),
        conflictIndex: conflictIndex,
        markerLines: MergeConflictMarkerLines(start: line, base: nil, separator: "", end: ""),
        hunkIndex: -1,
        startContentIndex: -1,
        endContentIndex: -1,
        endMarkerContentIndex: -1
    )
    while s.builders.count <= conflictIndex {
        s.builders.append(nil)
        s.completed.append(false)
    }
    s.builders[conflictIndex] = action
    s.completed[conflictIndex] = false
}

/// Detects conflict markers: 7+ repeated `<`, `|`, `=` or `>` characters.
/// The separator must be exactly `=======...` with no trailing text; other
/// markers allow a whitespace + label.
private func getMergeConflictMarkerType(_ line: String) -> MergeConflictMarkerType? {
    let units = Array(line.utf16)
    if units.count < 7 { return nil }
    let markerCode = units[0]
    guard markerCode == 60 || markerCode == 62 || markerCode == 61 || markerCode == 124 else { return nil }
    var lineEnd = units.count
    if lineEnd > 0, units[lineEnd - 1] == 10 { lineEnd -= 1 }
    if lineEnd > 0, units[lineEnd - 1] == 13 { lineEnd -= 1 }
    if lineEnd < 7 { return nil }
    var markerLength = 1
    while markerLength < lineEnd, units[markerLength] == markerCode {
        markerLength += 1
    }
    if markerLength < 7 { return nil }
    if markerCode == 61 {
        return markerLength == lineEnd ? .separator : nil
    }
    if markerLength != lineEnd {
        let next = units[markerLength]
        let isWhitespace = next == 9 || next == 10 || next == 11 || next == 12 || next == 13 || next == 32
        if !isWhitespace { return nil }
    }
    switch markerCode {
    case 60: return .start
    case 62: return .end
    default: return .base
    }
}

/// Builds the marker rows the UI injects into the diff (`buildMergeConflictMarkerRows`).
public func buildMergeConflictMarkerRows(fileDiff: FileDiffMetadata, actions: [MergeConflictDiffAction?]) -> [MergeConflictMarkerRow] {
    var markerRows: [MergeConflictMarkerRow] = []
    var lineStartCache: [Int: [Int]] = [:]

    func starts(_ hunkIndex: Int) -> [Int]? {
        guard hunkIndex >= 0, hunkIndex < fileDiff.hunks.count else { return nil }
        if let cached = lineStartCache[hunkIndex] { return cached }
        let hunk = fileDiff.hunks[hunkIndex]
        var result = [hunk.unifiedLineStart]
        var lineIndex = hunk.unifiedLineStart
        for content in hunk.hunkContent {
            switch content {
            case .context(let context): lineIndex += context.lines
            case .change(let change): lineIndex += change.deletions + change.additions
            }
            result.append(lineIndex)
        }
        lineStartCache[hunkIndex] = result
        return result
    }

    func lineStart(_ hunkIndex: Int, _ contentIndex: Int) -> Int {
        guard let starts = starts(hunkIndex) else { return 0 }
        let index = max(contentIndex, 0)
        return index < starts.count ? starts[index] : fileDiff.hunks[hunkIndex].unifiedLineStart
    }

    func lineEnd(_ hunkIndex: Int, _ contentIndex: Int) -> Int {
        let start = lineStart(hunkIndex, contentIndex)
        let endExclusive = lineStart(hunkIndex, contentIndex + 1)
        return max(start, endExclusive - 1)
    }

    func row(_ action: MergeConflictDiffAction, _ type: MergeConflictMarkerRowType, _ contentIndex: Int, _ text: String, _ lineIndex: Int) -> MergeConflictMarkerRow {
        MergeConflictMarkerRow(type: type, hunkIndex: action.hunkIndex, contentIndex: contentIndex, conflictIndex: action.conflictIndex, lineText: text, lineIndex: lineIndex)
    }

    for case let action? in actions {
        guard action.hunkIndex >= 0, action.hunkIndex < fileDiff.hunks.count else { continue }
        let hunk = fileDiff.hunks[action.hunkIndex]
        let actionLineIndex = lineStart(action.hunkIndex, action.startContentIndex)
        markerRows.append(row(action, .markerStart, action.startContentIndex, action.markerLines.start, actionLineIndex))

        if let baseContentIndex = action.baseContentIndex {
            guard let currentIndex = action.currentContentIndex, let incomingIndex = action.incomingContentIndex,
                  let baseMarkerLine = action.markerLines.base,
                  currentIndex < hunk.hunkContent.count, baseContentIndex < hunk.hunkContent.count, incomingIndex < hunk.hunkContent.count,
                  case .change(let currentChange) = hunk.hunkContent[currentIndex],
                  case .context = hunk.hunkContent[baseContentIndex],
                  case .change = hunk.hunkContent[incomingIndex]
            else { continue }
            let currentStart = lineStart(action.hunkIndex, currentIndex)
            let incomingStart = lineStart(action.hunkIndex, incomingIndex)
            markerRows.append(row(action, .markerBase, baseContentIndex, baseMarkerLine, currentStart + currentChange.deletions))
            markerRows.append(row(action, .markerSeparator, baseContentIndex, action.markerLines.separator, incomingStart))
            markerRows.append(row(action, .markerEnd, action.endMarkerContentIndex, action.markerLines.end, lineEnd(action.hunkIndex, action.endMarkerContentIndex)))
            continue
        }

        guard let currentIndex = action.currentContentIndex, currentIndex < hunk.hunkContent.count,
              case .change(let content) = hunk.hunkContent[currentIndex]
        else { continue }
        let contentStart = lineStart(action.hunkIndex, currentIndex)
        let separatorLineIndex = content.deletions > 0 ? contentStart + content.deletions : actionLineIndex
        markerRows.append(row(action, .markerSeparator, currentIndex, action.markerLines.separator, separatorLineIndex))
        markerRows.append(row(action, .markerEnd, action.endMarkerContentIndex, action.markerLines.end, lineEnd(action.hunkIndex, action.endMarkerContentIndex)))
    }
    return markerRows
}

func getUnifiedLineStartForContent(_ hunk: Hunk, _ contentIndex: Int) -> Int {
    var lineIndex = hunk.unifiedLineStart
    for index in 0 ..< min(contentIndex, hunk.hunkContent.count) {
        switch hunk.hunkContent[index] {
        case .context(let context): lineIndex += context.lines
        case .change(let change): lineIndex += change.deletions + change.additions
        }
    }
    return lineIndex
}
