// State helpers for unresolved (merge conflict) files: the injected marker and
// action rows of `UnresolvedFileHunksRenderer` and the post-resolution
// bookkeeping of `UnresolvedFile` (`rebuildFileAndActions`).

import Foundation

/// How conflict action rows render (`mergeConflictActionsType`).
public enum MergeConflictActionsType: Hashable, Sendable {
    /// No action rows.
    case none
    /// The built-in "Accept current change | Accept incoming change | Accept
    /// both" buttons.
    case `default`
    /// An empty action row that hosts a custom view.
    case custom
}

/// `areMergeConflictActionsEqual`: compares everything except the marker
/// line text.
public func areMergeConflictActionsEqual(_ a: MergeConflictDiffAction, _ b: MergeConflictDiffAction) -> Bool {
    a.hunkIndex == b.hunkIndex
        && a.startContentIndex == b.startContentIndex
        && a.endContentIndex == b.endContentIndex
        && a.currentContentIndex == b.currentContentIndex
        && a.baseContentIndex == b.baseContentIndex
        && a.incomingContentIndex == b.incomingContentIndex
        && a.endMarkerContentIndex == b.endMarkerContentIndex
        && a.conflictIndex == b.conflictIndex
        && a.conflict == b.conflict
}

/// `getMergeConflictActionSlotName`.
public func getMergeConflictActionSlotName(hunkIndex: Int, lineIndex: Int, conflictIndex: Int) -> String {
    "merge-conflict-action-\(hunkIndex)-\(lineIndex)-\(conflictIndex)"
}

/// Supplies the merge conflict marker and action rows to `buildDiffRows`
/// (`UnresolvedFileHunksRenderer.syncInjectedRows` and
/// `getUnifiedInjectedRowsForLine`). Unresolved files always render unified.
public struct MergeConflictInjectedRows: InjectedRowsProvider, Sendable {
    private enum Row: Sendable {
        case actions(conflictIndex: Int)
        case marker(MergeConflictMarkerRow)
    }

    private struct Key: Hashable {
        var hunkIndex: Int
        var lineIndex: Int
    }

    private var rows: [Key: [Row]] = [:]

    /// - Parameter actions: Pass an empty array to hide the action rows
    ///   (`mergeConflictActionsType: 'none'`).
    public init(actions: [MergeConflictDiffAction?], markerRows: [MergeConflictMarkerRow], fileDiff: FileDiffMetadata) {
        for action in actions {
            guard let action, let anchor = getMergeConflictActionAnchor(action, fileDiff: fileDiff) else { continue }
            rows[Key(hunkIndex: anchor.hunkIndex, lineIndex: anchor.lineIndex), default: []]
                .append(.actions(conflictIndex: action.conflictIndex))
        }
        for row in markerRows {
            rows[Key(hunkIndex: row.hunkIndex, lineIndex: row.lineIndex), default: []].append(.marker(row))
        }
    }

    public var isEmpty: Bool { rows.isEmpty }

    public func unifiedRows(for context: RenderedLineContext) -> (before: [InjectedCell], after: [InjectedCell])? {
        guard let rows = rows[Key(hunkIndex: context.hunkIndex, lineIndex: context.lineIndex)], !rows.isEmpty else {
            return nil
        }
        var before: [InjectedCell] = []
        var after: [InjectedCell] = []
        for row in rows {
            switch row {
            case .actions(let conflictIndex):
                before.append(InjectedCell(kind: .mergeConflictActions(conflictIndex: conflictIndex), conflictIndex: conflictIndex))
            case .marker(let marker):
                let text = trimTrailingLineEnding(marker.lineText)
                let cell = InjectedCell(kind: .mergeConflictMarker(marker.type, text: text), conflictIndex: marker.conflictIndex)
                if marker.type == .markerEnd {
                    after.append(cell)
                } else {
                    before.append(cell)
                }
            }
        }
        return (before, after)
    }

    public func splitRows(for context: RenderedLineContext) -> (before: [(InjectedCell?, InjectedCell?)], after: [(InjectedCell?, InjectedCell?)])? {
        nil
    }
}

/// `line.replace(/(?:\r\n|\n|\r)$/, '')`
func trimTrailingLineEnding(_ line: String) -> String {
    var scalars = line.unicodeScalars
    guard let last = scalars.last else { return line }
    if last == "\n" {
        scalars.removeLast()
        if scalars.last == "\r" { scalars.removeLast() }
    } else if last == "\r" {
        scalars.removeLast()
    }
    return String(scalars)
}

/// The state of an unresolved file after resolving one conflict
/// (`ResolveConflictReturn`).
public struct UnresolvedFileState: Sendable {
    /// The unresolved file text with the resolved conflict replaced.
    public var file: FileContents
    public var fileDiff: FileDiffMetadata
    public var actions: [MergeConflictDiffAction?]
    public var markerRows: [MergeConflictMarkerRow]

    public init(file: FileContents, fileDiff: FileDiffMetadata, actions: [MergeConflictDiffAction?], markerRows: [MergeConflictMarkerRow]) {
        self.file = file
        self.fileDiff = fileDiff
        self.actions = actions
        self.markerRows = markerRows
    }
}

/// Resolves conflict `conflictIndex` and rebuilds the unresolved file,
/// remaining actions and marker rows (`UnresolvedFile.resolveConflict`).
/// Returns nil when the action no longer exists.
public func resolveUnresolvedConflict(
    fileDiff: FileDiffMetadata,
    actions: [MergeConflictDiffAction?],
    conflictIndex: Int,
    resolution: MergeConflictResolution,
    previousFile: FileContents?
) throws -> UnresolvedFileState? {
    guard conflictIndex >= 0, conflictIndex < actions.count, let action = actions[conflictIndex] else { return nil }
    if action.conflictIndex != conflictIndex {
        throw DiffsError("UnresolvedFile.resolveConflict: conflictIndex and conflictAction don't match")
    }
    let newFileDiff = try resolveConflict(fileDiff, conflict: action.conflictData, type: resolution)
    let newActions = updateConflictActionsAfterResolution(actions, resolvedConflictIndex: conflictIndex, resolvedAction: action, resolution: resolution)
    let markerRows = buildMergeConflictMarkerRows(fileDiff: newFileDiff, actions: newActions)
    let file = rebuildUnresolvedFile(
        fileDiff: newFileDiff,
        resolvedAction: action,
        resolvedConflictIndex: conflictIndex,
        previousFile: previousFile,
        resolution: resolution
    )
    return UnresolvedFileState(file: file, fileDiff: newFileDiff, actions: newActions, markerRows: markerRows)
}

private func rebuildUnresolvedFile(
    fileDiff: FileDiffMetadata,
    resolvedAction: MergeConflictDiffAction,
    resolvedConflictIndex: Int,
    previousFile: FileContents?,
    resolution: MergeConflictResolution
) -> FileContents {
    let lines = splitFileContents(previousFile?.contents ?? "")
    let conflict = resolvedAction.conflict
    let replacement = getResolvedConflictReplacementLines(lines, conflict: conflict, resolution: resolution)
    var contents = ""
    for line in jsSlice(lines, 0, conflict.startLineIndex) { contents += line }
    for line in replacement { contents += line }
    for line in jsSlice(lines, conflict.endLineIndex + 1, lines.count) { contents += line }
    return FileContents(
        name: previousFile?.name ?? fileDiff.name,
        contents: contents,
        cacheKey: previousFile?.cacheKey.map { "\($0):mc-\(resolvedConflictIndex)-\(resolution.rawValue)" }
    )
}

/// `Array.prototype.slice` with clamped bounds.
private func jsSlice(_ lines: [String], _ start: Int, _ end: Int) -> ArraySlice<String> {
    let lower = min(max(start, 0), lines.count)
    let upper = min(max(end, lower), lines.count)
    return lines[lower ..< upper]
}

private func getResolvedConflictReplacementLines(_ lines: [String], conflict: MergeConflictRegion, resolution: MergeConflictResolution) -> [String] {
    let current = Array(jsSlice(lines, conflict.startLineIndex + 1, conflict.baseMarkerLineIndex ?? conflict.separatorLineIndex))
    let incoming = Array(jsSlice(lines, conflict.separatorLineIndex + 1, conflict.endLineIndex))
    switch resolution {
    case .current: return current
    case .incoming: return incoming
    case .both: return current + incoming
    }
}

private func updateConflictActionsAfterResolution(
    _ previousActions: [MergeConflictDiffAction?],
    resolvedConflictIndex: Int,
    resolvedAction: MergeConflictDiffAction,
    resolution: MergeConflictResolution
) -> [MergeConflictDiffAction?] {
    let lineDelta = getResolvedConflictLineDelta(resolvedAction.conflict, resolution: resolution)
    return previousActions.enumerated().map { index, action in
        guard index != resolvedConflictIndex, var action else { return nil }
        if action.conflict.startLineIndex > resolvedAction.conflict.endLineIndex {
            action.conflict = shiftMergeConflictRegion(action.conflict, lineDelta)
        }
        return action
    }
}

private func getResolvedConflictLineDelta(_ conflict: MergeConflictRegion, resolution: MergeConflictResolution) -> Int {
    let currentLineCount = (conflict.baseMarkerLineIndex ?? conflict.separatorLineIndex) - conflict.startLineIndex - 1
    let incomingLineCount = conflict.endLineIndex - conflict.separatorLineIndex - 1
    let replacementLineCount: Int
    switch resolution {
    case .current: replacementLineCount = currentLineCount
    case .incoming: replacementLineCount = incomingLineCount
    case .both: replacementLineCount = currentLineCount + incomingLineCount
    }
    let conflictLineCount = conflict.endLineIndex - conflict.startLineIndex + 1
    return replacementLineCount - conflictLineCount
}

private func shiftMergeConflictRegion(_ conflict: MergeConflictRegion, _ delta: Int) -> MergeConflictRegion {
    var shifted = conflict
    shifted.startLineIndex += delta
    shifted.startLineNumber += delta
    shifted.separatorLineIndex += delta
    shifted.separatorLineNumber += delta
    shifted.endLineIndex += delta
    shifted.endLineNumber += delta
    shifted.baseMarkerLineIndex = conflict.baseMarkerLineIndex.map { $0 + delta }
    shifted.baseMarkerLineNumber = conflict.baseMarkerLineNumber.map { $0 + delta }
    return shifted
}
