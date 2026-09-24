// Ports of `resolveRegion.ts`, `resolveConflict.ts`,
// `diffAcceptRejectHunk.ts`, `normalizeDiffResolution.ts` and
// `getMergeConflictLineTypes.ts`.

import Foundation

public enum RegionResolution: String, Hashable, Sendable {
    case deletions, additions, both
}

/// `normalizeDiffResolution`: `accept`/`incoming` keep additions,
/// `reject`/`current` keep deletions, `both` keeps both.
public func normalizeDiffResolution(_ type: DiffAcceptRejectHunkType) -> RegionResolution {
    switch type {
    case .accept: return .additions
    case .reject: return .deletions
    case .both: return .both
    }
}

public func normalizeDiffResolution(_ type: MergeConflictResolution) -> RegionResolution {
    switch type {
    case .incoming: return .additions
    case .current: return .deletions
    case .both: return .both
    }
}

private struct CursorState {
    var nextAdditionLineIndex = 0
    var nextDeletionLineIndex = 0
    var nextAdditionStart = 1
    var nextDeletionStart = 1
    var splitLineCount = 0
    var unifiedLineCount = 0
}

/// Resolves a content range of one hunk to one side (or both) and returns the
/// rewritten diff (`resolveRegion`).
public func resolveRegion(
    _ diff: FileDiffMetadata,
    hunkIndex: Int,
    startContentIndex: Int,
    endContentIndex: Int,
    resolution: RegionResolution,
    indexesToDelete: Set<Int> = []
) throws -> FileDiffMetadata {
    guard hunkIndex >= 0, hunkIndex < diff.hunks.count else {
        throw DiffsError("resolveRegion: Invalid hunk index: \(hunkIndex)")
    }
    let currentHunk = diff.hunks[hunkIndex]
    if startContentIndex < 0 || endContentIndex >= currentHunk.hunkContent.count || startContentIndex > endContentIndex {
        throw DiffsError("resolveRegion: Invalid content range, \(startContentIndex), \(endContentIndex)")
    }
    let hunks = diff.hunks
    let additionLines = diff.additionLines
    let deletionLines = diff.deletionLines
    var resolved = diff
    resolved.hunks = []
    resolved.deletionLines = []
    resolved.additionLines = []
    resolved.splitLineCount = 0
    resolved.unifiedLineCount = 0
    resolved.cacheKey = diff.cacheKey.map { "\($0):\(resolution.rawValue.prefix(1))-\(hunkIndex):\(startContentIndex)-\(endContentIndex)" }

    var cursor = CursorState()
    let updatesEOFState = hunkIndex == hunks.count - 1 && endContentIndex == currentHunk.hunkContent.count - 1
    let shouldProcessCollapsedContext = !diff.isPartial

    func pushCollapsedContextLines(_ deletionLineIndex: Int, _ additionLineIndex: Int, _ lineCount: Int) throws {
        for index in 0 ..< max(0, lineCount) {
            let d = deletionLineIndex + index
            let a = additionLineIndex + index
            guard d >= 0, d < deletionLines.count, a >= 0, a < additionLines.count else {
                throw DiffsError("pushCollapsedContextLines: missing collapsed context line")
            }
            resolved.deletionLines.append(deletionLines[d])
            resolved.additionLines.append(additionLines[a])
        }
    }

    func line(_ lines: [String], _ index: Int, _ message: String) throws -> String {
        guard index >= 0, index < lines.count else { throw DiffsError(message) }
        return lines[index]
    }

    func pushContentLines(_ content: HunkContent) throws {
        switch content {
        case .context(let context):
            for i in 0 ..< context.lines {
                let value = try line(additionLines, context.additionLineIndex + i, "pushContentLinesToDiff: Context line does not exist")
                resolved.deletionLines.append(value)
                resolved.additionLines.append(value)
            }
        case .change(let change):
            for i in 0 ..< max(change.deletions, change.additions) {
                if i < change.deletions {
                    resolved.deletionLines.append(try line(deletionLines, change.deletionLineIndex + i, "pushContentLinesToDiff: Deletion line does not exist"))
                }
                if i < change.additions {
                    resolved.additionLines.append(try line(additionLines, change.additionLineIndex + i, "pushContentLinesToDiff: Addition line does not exist"))
                }
            }
        }
    }

    func pushResolvedLines(_ change: ChangeContent) throws {
        if resolution == .deletions || resolution == .both {
            for i in 0 ..< change.deletions {
                let value = try line(deletionLines, change.deletionLineIndex + i, "pushResolveLinesToDiff: Deletion line does not exist")
                resolved.deletionLines.append(value)
                resolved.additionLines.append(value)
            }
        }
        if resolution == .additions || resolution == .both {
            for i in 0 ..< change.additions {
                let value = try line(additionLines, change.additionLineIndex + i, "pushResolveLinesToDiff: Addition line does not exist")
                resolved.deletionLines.append(value)
                resolved.additionLines.append(value)
            }
        }
    }

    func advance(_ content: HunkContent, _ hunk: inout Hunk) {
        switch content {
        case .context(let context):
            cursor.nextAdditionLineIndex += context.lines
            cursor.nextDeletionLineIndex += context.lines
            cursor.nextAdditionStart += context.lines
            cursor.nextDeletionStart += context.lines
            cursor.splitLineCount += context.lines
            cursor.unifiedLineCount += context.lines
            hunk.additionCount += context.lines
            hunk.deletionCount += context.lines
            hunk.splitLineCount += context.lines
            hunk.unifiedLineCount += context.lines
        case .change(let change):
            cursor.nextAdditionLineIndex += change.additions
            cursor.nextDeletionLineIndex += change.deletions
            cursor.nextAdditionStart += change.additions
            cursor.nextDeletionStart += change.deletions
            cursor.splitLineCount += max(change.deletions, change.additions)
            cursor.unifiedLineCount += change.deletions + change.additions
            hunk.deletionCount += change.deletions
            hunk.deletionLines += change.deletions
            hunk.additionCount += change.additions
            hunk.additionLines += change.additions
            hunk.splitLineCount += max(change.deletions, change.additions)
            hunk.unifiedLineCount += change.deletions + change.additions
        }
    }

    for (index, hunk) in hunks.enumerated() {
        // Collapsed context before the hunk.
        let lineCount = hunk.collapsedBefore
        if lineCount > 0 {
            if shouldProcessCollapsedContext {
                try pushCollapsedContextLines(
                    getHunkSideStartBoundary(hunk.deletionStart, hunk.deletionCount) - hunk.collapsedBefore,
                    getHunkSideStartBoundary(hunk.additionStart, hunk.additionCount) - hunk.collapsedBefore,
                    lineCount
                )
                cursor.nextAdditionLineIndex += lineCount
                cursor.nextDeletionLineIndex += lineCount
            }
            cursor.nextAdditionStart += lineCount
            cursor.nextDeletionStart += lineCount
            cursor.splitLineCount += lineCount
            cursor.unifiedLineCount += lineCount
        }

        var newHunk = hunk
        newHunk.hunkContent = []
        newHunk.additionStart = cursor.nextAdditionStart
        newHunk.deletionStart = cursor.nextDeletionStart
        newHunk.additionLineIndex = cursor.nextAdditionLineIndex
        newHunk.deletionLineIndex = cursor.nextDeletionLineIndex
        newHunk.additionCount = 0
        newHunk.deletionCount = 0
        newHunk.deletionLines = 0
        newHunk.additionLines = 0
        newHunk.splitLineStart = cursor.splitLineCount
        newHunk.unifiedLineStart = cursor.unifiedLineCount
        newHunk.splitLineCount = 0
        newHunk.unifiedLineCount = 0

        for (contentIndex, content) in hunk.hunkContent.enumerated() {
            if index != hunkIndex || contentIndex < startContentIndex || contentIndex > endContentIndex {
                try pushContentLines(content)
                var newContent = content
                newContent.additionLineIndex = cursor.nextAdditionLineIndex
                newContent.deletionLineIndex = cursor.nextDeletionLineIndex
                newHunk.hunkContent.append(newContent)
                advance(newContent, &newHunk)
            } else if indexesToDelete.contains(contentIndex) {
                // Replace with an empty context node.
                newHunk.hunkContent.append(.context(ContextContent(
                    lines: 0,
                    additionLineIndex: cursor.nextAdditionLineIndex,
                    deletionLineIndex: cursor.nextDeletionLineIndex
                )))
            } else if case .context(let context) = content {
                try pushContentLines(content)
                let newContent = HunkContent.context(ContextContent(
                    lines: context.lines,
                    additionLineIndex: cursor.nextAdditionLineIndex,
                    deletionLineIndex: cursor.nextDeletionLineIndex
                ))
                newHunk.hunkContent.append(newContent)
                advance(newContent, &newHunk)
            } else if case .change(let change) = content {
                try pushResolvedLines(change)
                let lines: Int
                switch resolution {
                case .deletions: lines = change.deletions
                case .additions: lines = change.additions
                case .both: lines = change.deletions + change.additions
                }
                let newContent = HunkContent.context(ContextContent(
                    lines: lines,
                    additionLineIndex: cursor.nextAdditionLineIndex,
                    deletionLineIndex: cursor.nextDeletionLineIndex
                ))
                newHunk.hunkContent.append(newContent)
                advance(newContent, &newHunk)
            }
        }

        if index == hunkIndex, updatesEOFState {
            let noEOFCR = resolution == .deletions ? hunk.noEOFCRDeletions : hunk.noEOFCRAdditions
            newHunk.noEOFCRAdditions = noEOFCR
            newHunk.noEOFCRDeletions = noEOFCR
        }
        if newHunk.additionCount == 0 {
            newHunk.additionStart -= 1
            if !diff.isPartial { newHunk.additionLineIndex -= 1 }
        }
        if newHunk.deletionCount == 0 {
            newHunk.deletionStart -= 1
            if !diff.isPartial { newHunk.deletionLineIndex -= 1 }
        }
        resolved.hunks.append(newHunk)
    }

    if let finalHunk = hunks.last, !diff.isPartial {
        let finalDeletionEnd = getHunkSideEndBoundary(finalHunk.deletionStart, finalHunk.deletionCount)
        let finalAdditionEnd = getHunkSideEndBoundary(finalHunk.additionStart, finalHunk.additionCount)
        let trailingContext = min(deletionLines.count - finalDeletionEnd, additionLines.count - finalAdditionEnd)
        try pushCollapsedContextLines(finalDeletionEnd, finalAdditionEnd, trailingContext)
        cursor.splitLineCount += max(0, trailingContext)
        cursor.unifiedLineCount += max(0, trailingContext)
    }
    resolved.splitLineCount = cursor.splitLineCount
    resolved.unifiedLineCount = cursor.unifiedLineCount
    return resolved
}

/// Resolves an unresolved merge conflict (`resolveConflict`).
public func resolveConflict(_ diff: FileDiffMetadata, conflict: ProcessFileConflictData, type: MergeConflictResolution) throws -> FileDiffMetadata {
    var indexesToDelete: Set<Int> = []
    if let base = conflict.baseContentIndex { indexesToDelete.insert(base) }
    if conflict.endMarkerContentIndex != conflict.endContentIndex { indexesToDelete.insert(conflict.endMarkerContentIndex) }
    return try resolveRegion(
        diff,
        hunkIndex: conflict.hunkIndex,
        startContentIndex: conflict.startContentIndex,
        endContentIndex: conflict.endContentIndex,
        resolution: normalizeDiffResolution(type),
        indexesToDelete: indexesToDelete
    )
}

/// Accepts or rejects a whole hunk, or one change block within it
/// (`diffAcceptRejectHunk`).
public func diffAcceptRejectHunk(_ diff: FileDiffMetadata, hunkIndex: Int, type: DiffAcceptRejectHunkType, changeIndex: Int? = nil) throws -> FileDiffMetadata {
    guard hunkIndex >= 0, hunkIndex < diff.hunks.count else {
        throw DiffsError("diffAcceptRejectHunk: Invalid hunk index")
    }
    let hunk = diff.hunks[hunkIndex]
    let start = changeIndex ?? 0
    let end = changeIndex ?? max(0, hunk.hunkContent.count - 1)
    return try resolveRegion(diff, hunkIndex: hunkIndex, startContentIndex: start, endContentIndex: end, resolution: normalizeDiffResolution(type))
}

public func diffAcceptRejectHunk(_ diff: FileDiffMetadata, hunkIndex: Int, config: DiffAcceptRejectHunkConfig) throws -> FileDiffMetadata {
    try diffAcceptRejectHunk(diff, hunkIndex: hunkIndex, type: config.type, changeIndex: config.changeIndex)
}

// MARK: - Merge conflict line types

public enum MergeConflictLineType: String, Hashable, Sendable {
    case none
    case markerStart = "marker-start"
    case markerBase = "marker-base"
    case markerSeparator = "marker-separator"
    case markerEnd = "marker-end"
    case current
    case base
    case incoming
}

public struct MergeConflictParseResult: Hashable, Sendable {
    public var lineTypes: [MergeConflictLineType]
    public var regions: [MergeConflictRegion]
}

private let startMarkerRegex = try! NSRegularExpression(pattern: #"^<{7,}(?:\s.*)?\z"#)
private let baseMarkerRegex = try! NSRegularExpression(pattern: #"^\|{7,}(?:\s.*)?\z"#)
private let separatorMarkerRegex = try! NSRegularExpression(pattern: #"^={7,}\z"#)
private let endMarkerRegex = try! NSRegularExpression(pattern: #"^>{7,}(?:\s.*)?\z"#)

private func test(_ regex: NSRegularExpression, _ value: String) -> Bool {
    regex.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
}

public func getMergeConflictLineTypes(_ lines: [String]) -> [MergeConflictLineType] {
    getMergeConflictParseResult(lines).lineTypes
}

public func getMergeConflictActionLineNumber(_ conflict: MergeConflictRegion) -> Int {
    max(1, conflict.startLineNumber - 1)
}

/// Classifies each line of a file with conflict markers.
public func getMergeConflictParseResult(_ lines: [String]) -> MergeConflictParseResult {
    struct Frame {
        var stage: MergeConflictLineType
        var startLineIndex: Int
        var baseMarkerLineIndex: Int?
        var separatorLineIndex: Int?
    }
    var lineTypes: [MergeConflictLineType] = []
    lineTypes.reserveCapacity(lines.count)
    var stack: [Frame] = []
    var regions: [MergeConflictRegion] = []
    for (index, rawLine) in lines.enumerated() {
        // `line.replace(/(?:\r\n|\n|\r)$/, '')`
        var line = rawLine
        if line.hasSuffix("\r\n") || line.hasSuffix("\n") || line.hasSuffix("\r") {
            line = String(line.unicodeScalars.dropLast(line.hasSuffix("\r\n") ? 2 : 1))
        }
        if test(startMarkerRegex, line) {
            stack.append(Frame(stage: .current, startLineIndex: index))
            lineTypes.append(.markerStart)
            continue
        }
        guard !stack.isEmpty else {
            lineTypes.append(.none)
            continue
        }
        if test(baseMarkerRegex, line) {
            stack[stack.count - 1].stage = .base
            stack[stack.count - 1].baseMarkerLineIndex = index
            lineTypes.append(.markerBase)
            continue
        }
        if test(separatorMarkerRegex, line) {
            stack[stack.count - 1].stage = .incoming
            stack[stack.count - 1].separatorLineIndex = index
            lineTypes.append(.markerSeparator)
            continue
        }
        if test(endMarkerRegex, line) {
            let completed = stack.removeLast()
            lineTypes.append(.markerEnd)
            if let separatorLineIndex = completed.separatorLineIndex {
                regions.append(MergeConflictRegion(
                    conflictIndex: regions.count,
                    startLineIndex: completed.startLineIndex,
                    startLineNumber: completed.startLineIndex + 1,
                    separatorLineIndex: separatorLineIndex,
                    separatorLineNumber: separatorLineIndex + 1,
                    endLineIndex: index,
                    endLineNumber: index + 1,
                    baseMarkerLineIndex: completed.baseMarkerLineIndex,
                    baseMarkerLineNumber: completed.baseMarkerLineIndex.map { $0 + 1 }
                ))
            }
            continue
        }
        lineTypes.append(stack[stack.count - 1].stage)
    }
    return MergeConflictParseResult(lineTypes: lineTypes, regions: regions)
}
