// Port of `packages/diffs/src/utils/parseDiffFromFile.ts`.

import Foundation

private let missingFileName = "/dev/null"

/// Parses a diff from two file contents objects.
///
/// If both `oldFile` and `newFile` have a `cacheKey`, the resulting diff gets
/// a collision-safe key derived from both values.
public func parseDiffFromFile(
    oldFile: FileContents?,
    newFile: FileContents?,
    options: CreatePatchOptions = CreatePatchOptions(),
    throwOnError: Bool = false
) throws -> FileDiffMetadata {
    if oldFile == nil, newFile == nil {
        throw PatchParseError("parseDiffFromFile: You must pass oldFile, newFile, or both")
    }
    let resolvedOldFile = oldFile ?? FileContents(name: missingFileName, contents: "")
    let resolvedNewFile = newFile ?? FileContents(name: missingFileName, contents: "")
    guard let patch = createTwoFilesPatch(
        oldFileName: resolvedOldFile.name,
        newFileName: resolvedNewFile.name,
        oldString: resolvedOldFile.contents,
        newString: resolvedNewFile.contents,
        oldHeader: resolvedOldFile.header,
        newHeader: resolvedNewFile.header,
        options: options
    ) else {
        throw PatchParseError("parseDiffFromFile: diff computation was aborted")
    }

    var cacheKey: String?
    if let oldCacheKey = oldFile?.cacheKey, let newCacheKey = newFile?.cacheKey {
        cacheKey = composeCacheKey("diff", oldCacheKey, newCacheKey)
    }
    guard var fileData = try processFile(
        patch,
        options: ProcessFileOptions(
            cacheKey: cacheKey,
            oldFile: resolvedOldFile,
            newFile: resolvedNewFile,
            throwOnError: throwOnError
        )
    ) else {
        throw PatchParseError(
            "parseDiffFrom: FileInvalid diff -- probably need to fix something -- if the files are the same maybe?"
        )
    }
    if oldFile == nil {
        fileData.type = .new
        fileData.prevName = nil
    } else if newFile == nil {
        fileData.type = .deleted
        fileData.prevName = nil
    }
    // If we've been provided an override for language in the newFile, pass it
    // through to FileDiffMetadata.
    if let language = newFile?.lang ?? (newFile == nil ? oldFile?.lang : nil) {
        fileData.lang = language
    }
    return fileData
}

/// Convenience overload taking two non-optional files.
public func parseDiffFromFile(
    _ oldFile: FileContents,
    _ newFile: FileContents,
    options: CreatePatchOptions = CreatePatchOptions()
) throws -> FileDiffMetadata {
    try parseDiffFromFile(oldFile: oldFile, newFile: newFile, options: options)
}
