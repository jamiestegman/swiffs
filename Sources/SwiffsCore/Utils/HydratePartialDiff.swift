// Port of `hydratePartialDiff.ts`: turns a partial (patch) diff into a full
// one using the loaded old/new files, so collapsed context can expand.

import Foundation

/// Files loaded for a partial diff (`FileDiffLoadedFiles`); `oldFile` is nil
/// for a pure rename.
public struct DiffLoadedFiles: Hashable, Sendable {
    public var oldFile: FileContents?
    public var newFile: FileContents

    public init(oldFile: FileContents?, newFile: FileContents) {
        self.oldFile = oldFile
        self.newFile = newFile
    }
}

/// Whether a diff can be hydrated from loaded files (`canHydrateDiff`).
public func canHydrateDiff(_ fileDiff: FileDiffMetadata) -> Bool {
    fileDiff.isPartial && (fileDiff.type == .change || fileDiff.type == .renameChanged || fileDiff.type == .renamePure)
}

/// Hydrates a partial diff with full file lines (`hydratePartialDiff`).
public func hydratePartialDiff(_ fileDiff: FileDiffMetadata, files: DiffLoadedFiles) throws -> FileDiffMetadata {
    guard fileDiff.isPartial else { throw DiffsError("hydratePartialDiff: fileDiff must be partial") }
    var diff = fileDiff
    switch diff.type {
    case .change, .renameChanged:
        guard let oldFile = files.oldFile else {
            throw DiffsError("hydratePartialDiff: \(diff.type.rawValue) diff for \(diff.name) requires oldFile")
        }
        let deletionLines = splitFileContents(oldFile.contents)
        let additionLines = splitFileContents(files.newFile.contents)
        let hydrated = hydrateHunks(diff.hunks, totalAdditionLines: additionLines.count)
        diff.hunks = hydrated.hunks
        diff.splitLineCount = hydrated.splitLineCount
        diff.unifiedLineCount = hydrated.unifiedLineCount
        diff.isPartial = false
        diff.deletionLines = deletionLines
        diff.additionLines = additionLines
        diff.cacheKey = hydratedCacheKey(fileDiff, oldFile, files.newFile)
        return diff
    case .renamePure:
        if files.oldFile != nil {
            throw DiffsError("hydratePartialDiff: \(diff.type.rawValue) diff for \(diff.name) requires oldFile to be null")
        }
        let lines = splitFileContents(files.newFile.contents)
        diff.isPartial = false
        diff.deletionLines = lines
        diff.additionLines = lines
        diff.cacheKey = hydratedCacheKey(fileDiff, nil, files.newFile)
        return diff
    default:
        throw DiffsError("hydratePartialDiff: \(diff.type.rawValue) diffs cannot be hydrated from loaded files")
    }
}

private func hydrateHunks(_ hunks: [Hunk], totalAdditionLines: Int) -> (hunks: [Hunk], splitLineCount: Int, unifiedLineCount: Int) {
    var splitLineCount = 0
    var unifiedLineCount = 0
    var lastHunkAdditionEnd = 0
    var hydrated: [Hunk] = []
    for hunk in hunks {
        let additionLineIndex = max(hunk.additionStart - 1, 0)
        let deletionLineIndex = max(hunk.deletionStart - 1, 0)
        var contentAddition = additionLineIndex
        var contentDeletion = deletionLineIndex
        var additions = 0
        var deletions = 0
        var split = 0
        var unified = 0
        var content: [HunkContent] = []
        for item in hunk.hunkContent {
            var updated = item
            updated.additionLineIndex = contentAddition
            updated.deletionLineIndex = contentDeletion
            content.append(updated)
            switch item {
            case .context(let context):
                contentAddition += context.lines
                contentDeletion += context.lines
                split += context.lines
                unified += context.lines
            case .change(let change):
                contentAddition += change.additions
                contentDeletion += change.deletions
                additions += change.additions
                deletions += change.deletions
                split += max(change.additions, change.deletions)
                unified += change.additions + change.deletions
            }
        }
        let collapsedBefore = max(getHunkSideStartBoundary(hunk.additionStart, hunk.additionCount) - lastHunkAdditionEnd, 0)
        var next = hunk
        next.collapsedBefore = collapsedBefore
        next.additionLineIndex = additionLineIndex
        next.deletionLineIndex = deletionLineIndex
        next.additionLines = additions
        next.deletionLines = deletions
        next.hunkContent = content
        next.splitLineStart = splitLineCount + collapsedBefore
        next.unifiedLineStart = unifiedLineCount + collapsedBefore
        next.splitLineCount = split
        next.unifiedLineCount = unified
        hydrated.append(next)
        splitLineCount += collapsedBefore + split
        unifiedLineCount += collapsedBefore + unified
        lastHunkAdditionEnd = getHunkSideEndBoundary(hunk.additionStart, hunk.additionCount)
    }
    if let last = hydrated.last {
        let collapsedAfter = max(totalAdditionLines - getHunkSideEndBoundary(last.additionStart, last.additionCount), 0)
        splitLineCount += collapsedAfter
        unifiedLineCount += collapsedAfter
    }
    return (hydrated, splitLineCount, unifiedLineCount)
}

private func hydratedCacheKey(_ fileDiff: FileDiffMetadata, _ oldFile: FileContents?, _ newFile: FileContents?) -> String? {
    if let cacheKey = fileDiff.cacheKey { return "\(cacheKey):hydrated" }
    if let oldFile, let newFile {
        guard let oldKey = oldFile.cacheKey, let newKey = newFile.cacheKey else { return nil }
        return composeCacheKey("hydrated-files", oldKey, newKey)
    }
    return oldFile?.cacheKey ?? newFile?.cacheKey
}
