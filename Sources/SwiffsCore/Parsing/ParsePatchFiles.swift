// Port of `packages/diffs/src/utils/parsePatchFiles.ts`.

import Foundation

public struct PatchParseError: Error, Hashable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Receives recoverable parser diagnostics (the upstream implementation logs
/// these with `console.error`). Defaults to discarding them.
public enum SwiffsDiagnostics {
    public nonisolated(unsafe) static var handler: (@Sendable (String) -> Void)? = nil

    static func error(_ message: @autoclosure () -> String) {
        handler?(message())
    }
}

// Keep quotes and transport prefixes until decoding, while allowing spaces in
// unquoted paths and escaped quotes inside quoted paths.
private let gitDiffHeaderFilenames = try! NSRegularExpression(
    pattern: #"^diff --git ("a/(?:[^"\\]|\\.)*"|a/.+?) ("b/(?:[^"\\]|\\.)*"|b/.+?)$"#
)
private let filenameHeaderRegex = try! NSRegularExpression(
    pattern: #"^(---|\+\+\+)\s+([^\t\r\n]+)"#
)
private let indexLineMetadata = try! NSRegularExpression(
    pattern: #"^index ([0-9a-f]+)\.\.([0-9a-f]+)(?: (\d+))?$"#,
    options: [.caseInsensitive]
)

extension NSRegularExpression {
    /// Returns the capture groups of the first match (group 0 is the full
    /// match); unmatched groups are nil.
    func firstMatchGroups(in string: String) -> [String?]? {
        let ns = string as NSString
        guard let match = firstMatch(in: string, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return (0 ..< match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }
}

struct ParsedHunkHeader {
    var additionCount: Int
    var additionStart: Int
    var deletionCount: Int
    var deletionStart: Int
    var hunkContext: String?
}

public struct ProcessFileOptions: Sendable {
    public var cacheKey: String?
    public var isGitDiff: Bool?
    public var oldFile: FileContents?
    public var newFile: FileContents?
    public var throwOnError: Bool

    public init(
        cacheKey: String? = nil,
        isGitDiff: Bool? = nil,
        oldFile: FileContents? = nil,
        newFile: FileContents? = nil,
        throwOnError: Bool = false
    ) {
        self.cacheKey = cacheKey
        self.isGitDiff = isGitDiff
        self.oldFile = oldFile
        self.newFile = newFile
        self.throwOnError = throwOnError
    }
}

/// Parses a single patch (one commit) into a `ParsedPatch`.
public func processPatch(_ data: String, cacheKeyPrefix: String? = nil, throwOnError: Bool = false) throws -> ParsedPatch {
    try _processPatch(data[...], cacheKeyPrefix: cacheKeyPrefix, throwOnError: throwOnError, patchIndex: nil)
}

private func _processPatch(
    _ data: Substring,
    cacheKeyPrefix: String?,
    throwOnError: Bool,
    patchIndex: Int?
) throws -> ParsedPatch {
    let isGitDiff = isGitDiffPatch(data)
    let rawFiles = isGitDiff ? splitGitDiffFiles(data) : splitUnifiedDiffFiles(data)
    var patchMetadata: String?
    var files: [FileDiffMetadata] = []
    for fileOrPatchMetadata in rawFiles {
        let isFileBlob = isGitDiff
            ? containsLineStarting(fileOrPatchMetadata, with: "diff --git")
            : startsWithUnifiedDiffFileHeader(fileOrPatchMetadata)
        if !isFileBlob {
            // Most likely the introductory metadata from the patch, or the
            // diff format is malformed.
            if patchMetadata == nil {
                patchMetadata = String(fileOrPatchMetadata)
            } else if throwOnError {
                throw PatchParseError("parsePatchContent: unknown file blob")
            } else {
                SwiffsDiagnostics.error("parsePatchContent: unknown file blob: \(fileOrPatchMetadata)")
            }
            continue
        }
        var cacheKey: String?
        if let cacheKeyPrefix {
            if let patchIndex {
                cacheKey = composeCacheKey("patch-file", cacheKeyPrefix, String(patchIndex), String(files.count))
            } else {
                cacheKey = composeCacheKey("patch-file", cacheKeyPrefix, String(files.count))
            }
        }
        if let currentFile = try _processFile(
            fileOrPatchMetadata,
            ProcessFileOptions(cacheKey: cacheKey, isGitDiff: isGitDiff, throwOnError: throwOnError)
        ) {
            files.append(currentFile)
        }
    }
    return ParsedPatch(patchMetadata: patchMetadata, files: files)
}

/// Parses the diff for a single file.
public func processFile(_ fileDiffString: String, options: ProcessFileOptions = ProcessFileOptions()) throws -> FileDiffMetadata? {
    try _processFile(fileDiffString[...], options)
}

private func _processFile(_ fileDiffString: Substring, _ options: ProcessFileOptions) throws -> FileDiffMetadata? {
    let throwOnError = options.throwOnError
    let isGitDiff = options.isGitDiff ?? containsLineStarting(fileDiffString, with: "diff --git")
    let oldFile = options.oldFile
    let newFile = options.newFile
    var lastHunkEnd = 0
    let hunks = splitAtLinePrefix(fileDiffString, "@@ ")
    var currentFile: FileDiffMetadata?
    let isPartial = oldFile == nil || newFile == nil
    var deletionLineIndex = 0
    var additionLineIndex = 0

    for hunk in hunks {
        var lines = splitWithNewlines(hunk)
        guard let firstLine = lines.first else {
            if throwOnError { throw PatchParseError("parsePatchContent: invalid hunk") }
            SwiffsDiagnostics.error("parsePatchContent: invalid hunk \(hunk)")
            continue
        }
        let fileHeader = parseHunkHeader(firstLine)
        var additionLines = 0
        var deletionLines = 0

        // Setup currentFile, this should be the first iteration of our hunks,
        // and technically not a hunk
        guard let fileHeader, var file = currentFile else {
            if currentFile != nil {
                if throwOnError { throw PatchParseError("parsePatchContent: Invalid hunk") }
                SwiffsDiagnostics.error("parsePatchContent: Invalid hunk \(hunk)")
                continue
            }
            var file = FileDiffMetadata(
                name: "",
                type: .change,
                isPartial: isPartial,
                deletionLines: !isPartial ? splitFileContentsKeepingEmpty(oldFile!.contents) : [],
                additionLines: !isPartial ? splitFileContentsKeepingEmpty(newFile!.contents) : [],
                cacheKey: options.cacheKey
            )
            // If either file is technically empty, then we should empty the
            // arrays respectively
            if file.additionLines.count == 1, newFile?.contents == "" {
                file.additionLines.removeAll()
            }
            if file.deletionLines.count == 1, oldFile?.contents == "" {
                file.deletionLines.removeAll()
            }

            for line in lines {
                if line.hasPrefix("diff --git") {
                    guard let match = gitDiffHeaderFilenames.firstMatchGroups(in: JSString.trim(String(line))),
                          let rawPrev = match[1], let rawName = match[2]
                    else {
                        if throwOnError { throw PatchParseError("parsePatchContent: invalid git diff header") }
                        SwiffsDiagnostics.error("parsePatchContent: invalid git diff header \(line)")
                        continue
                    }
                    let prevName = decodeDiffFileName(rawPrev, stripGitPrefix: true)
                    let name = decodeDiffFileName(rawName, stripGitPrefix: true)
                    file.name = name
                    if prevName != name {
                        file.prevName = prevName
                    }
                    continue
                }

                let filenameMatch = (line.hasPrefix("---") || line.hasPrefix("+++"))
                    ? filenameHeaderRegex.firstMatchGroups(in: String(line))
                    : nil
                if let filenameMatch, let type = filenameMatch[1], let rawFileName = filenameMatch[2] {
                    let fileName = decodeDiffFileName(rawFileName, stripGitPrefix: isGitDiff)
                    if type == "---", fileName != "/dev/null" {
                        file.prevName = fileName
                        file.name = fileName
                    } else if type == "+++", fileName != "/dev/null" {
                        file.name = fileName
                    }
                } else if isGitDiff {
                    // Git diffs have a bunch of additional metadata we can pull from
                    if line.hasPrefix("new mode ") {
                        file.mode = JSString.trim(String(line.dropFirst("new mode".count)))
                    }
                    if line.hasPrefix("old mode ") {
                        file.prevMode = JSString.trim(String(line.dropFirst("old mode".count)))
                    }
                    if line.hasPrefix("new file mode") {
                        file.type = .new
                        file.mode = JSString.trim(String(line.dropFirst("new file mode".count)))
                    }
                    if line.hasPrefix("deleted file mode") {
                        file.type = .deleted
                        file.mode = JSString.trim(String(line.dropFirst("deleted file mode".count)))
                    }
                    if line.hasPrefix("similarity index") {
                        file.type = line.hasPrefix("similarity index 100%") ? .renamePure : .renameChanged
                    }
                    if line.hasPrefix("index ") {
                        if let match = indexLineMetadata.firstMatchGroups(in: JSString.trim(String(line))) {
                            if let prevObjectId = match[1] { file.prevObjectId = prevObjectId }
                            if let newObjectId = match[2] { file.newObjectId = newObjectId }
                            if let mode = match[3] { file.mode = mode }
                        }
                    }
                    // Pure renames and copies have no --- / +++ headers. These
                    // paths are already relative to the repository.
                    if line.hasPrefix("rename from ") || line.hasPrefix("copy from ") {
                        let prefixLength = line.hasPrefix("rename") ? "rename from ".count : "copy from ".count
                        file.prevName = decodeDiffFileName(String(line.dropFirst(prefixLength)))
                    }
                    if line.hasPrefix("rename to ") || line.hasPrefix("copy to ") {
                        let prefixLength = line.hasPrefix("rename") ? "rename to ".count : "copy to ".count
                        file.name = decodeDiffFileName(String(line.dropFirst(prefixLength)))
                    }
                }
            }
            currentFile = file
            continue
        }
        currentFile = nil

        // Otherwise, time to start parsing out the hunk
        var currentContent: HunkContent?
        var lastLineType: HunkLineType?

        // Strip trailing bare newlines (format-patch separators between
        // commits) if needed
        while let last = lines.last, last == "\n" || last == "\r" || last == "\r\n" || last.isEmpty {
            lines.removeLast()
        }

        let additionStart = fileHeader.additionStart
        let deletionStart = fileHeader.deletionStart
        deletionLineIndex = isPartial ? deletionLineIndex : deletionStart - 1
        additionLineIndex = isPartial ? additionLineIndex : additionStart - 1

        var hunkData = Hunk(
            additionStart: additionStart,
            additionCount: fileHeader.additionCount,
            additionLines: additionLines,
            additionLineIndex: additionLineIndex,
            deletionStart: deletionStart,
            deletionCount: fileHeader.deletionCount,
            deletionLines: deletionLines,
            deletionLineIndex: deletionLineIndex,
            hunkContext: fileHeader.hunkContext,
            hunkSpecs: String(firstLine)
        )

        func flush() {
            if let content = currentContent {
                hunkData.hunkContent[hunkData.hunkContent.count - 1] = content
            }
        }

        // Now we process each line of the hunk
        var parsedAdditionLines = 0
        var parsedDeletionLines = 0
        var lineIndex = 1
        while lineIndex < lines.count {
            defer { lineIndex += 1 }
            let rawLine = lines[lineIndex]
            let firstByte = rawLine.utf8.first
            if parsedAdditionLines >= hunkData.additionCount,
               parsedDeletionLines >= hunkData.deletionCount,
               firstByte != UInt8(ascii: "\\")
            {
                let isUnexpectedBodyLine = isHunkBodyLine(rawLine) && !isFormatPatchVersionSeparator(rawLine)
                if !isUnexpectedBodyLine {
                    break
                }
                if throwOnError {
                    throw PatchParseError("parsePatchContent: hunk has more lines than expected")
                }
            }

            // If we can't properly process the line, try to salvage things and
            // continue... It's possible an AI generated diff might have some
            // stray blank lines or something in there
            guard let firstByte,
                  firstByte == UInt8(ascii: "+") || firstByte == UInt8(ascii: "-")
                  || firstByte == UInt8(ascii: " ") || firstByte == UInt8(ascii: "\\")
            else {
                if throwOnError { throw PatchParseError("parsePatchContent: invalid hunk line") }
                SwiffsDiagnostics.error("processFile: invalid rawLine: \(rawLine)")
                continue
            }

            switch firstByte {
            case UInt8(ascii: "+"):
                if throwOnError, parsedAdditionLines >= hunkData.additionCount {
                    throw PatchParseError("parsePatchContent: hunk has too many addition lines")
                }
                let line = getParsedLineContent(rawLine)
                if currentContent == nil || !currentContent!.isChange {
                    flush()
                    currentContent = .change(ChangeContent(
                        deletions: 0, deletionLineIndex: deletionLineIndex,
                        additions: 0, additionLineIndex: additionLineIndex
                    ))
                    hunkData.hunkContent.append(currentContent!)
                }
                additionLineIndex += 1
                parsedAdditionLines += 1
                if isPartial {
                    file.additionLines.append(line)
                }
                if case .change(var change) = currentContent {
                    change.additions += 1
                    currentContent = .change(change)
                }
                additionLines += 1
                lastLineType = .addition
            case UInt8(ascii: "-"):
                if throwOnError, parsedDeletionLines >= hunkData.deletionCount {
                    throw PatchParseError("parsePatchContent: hunk has too many deletion lines")
                }
                let line = getParsedLineContent(rawLine)
                if currentContent == nil || !currentContent!.isChange {
                    flush()
                    currentContent = .change(ChangeContent(
                        deletions: 0, deletionLineIndex: deletionLineIndex,
                        additions: 0, additionLineIndex: additionLineIndex
                    ))
                    hunkData.hunkContent.append(currentContent!)
                }
                deletionLineIndex += 1
                parsedDeletionLines += 1
                if isPartial {
                    file.deletionLines.append(line)
                }
                if case .change(var change) = currentContent {
                    change.deletions += 1
                    currentContent = .change(change)
                }
                deletionLines += 1
                lastLineType = .deletion
            case UInt8(ascii: " "):
                if throwOnError,
                   parsedDeletionLines >= hunkData.deletionCount || parsedAdditionLines >= hunkData.additionCount
                {
                    throw PatchParseError("parsePatchContent: hunk has too many context lines")
                }
                let line = getParsedLineContent(rawLine)
                if currentContent == nil || !currentContent!.isContext {
                    flush()
                    currentContent = .context(ContextContent(
                        lines: 0, additionLineIndex: additionLineIndex, deletionLineIndex: deletionLineIndex
                    ))
                    hunkData.hunkContent.append(currentContent!)
                }
                additionLineIndex += 1
                deletionLineIndex += 1
                parsedAdditionLines += 1
                parsedDeletionLines += 1
                if isPartial {
                    file.deletionLines.append(line)
                    file.additionLines.append(line)
                }
                if case .context(var context) = currentContent {
                    context.lines += 1
                    currentContent = .context(context)
                }
                lastLineType = .context
            default:
                // Metadata (`\ No newline at end of file`)
                guard let content = currentContent else { continue }
                if content.isContext {
                    hunkData.noEOFCRAdditions = true
                    hunkData.noEOFCRDeletions = true
                } else if lastLineType == .deletion {
                    hunkData.noEOFCRDeletions = true
                } else if lastLineType == .addition {
                    hunkData.noEOFCRAdditions = true
                }
                // If we're dealing with partial content from a diff, we need
                // to strip newlines manually from the content
                if isPartial, lastLineType == .addition || lastLineType == .context {
                    if let lastIndex = file.additionLines.indices.last {
                        file.additionLines[lastIndex] = cleanLastNewline(file.additionLines[lastIndex])
                    }
                }
                if isPartial, lastLineType == .deletion || lastLineType == .context {
                    if let lastIndex = file.deletionLines.indices.last {
                        file.deletionLines[lastIndex] = cleanLastNewline(file.deletionLines[lastIndex])
                    }
                }
            }
        }
        flush()

        if parsedAdditionLines != hunkData.additionCount || parsedDeletionLines != hunkData.deletionCount {
            if throwOnError {
                throw PatchParseError("parsePatchContent: hunk line count mismatch")
            }
            SwiffsDiagnostics.error(
                "parsePatchContent: hunk line count mismatch: \"\(JSString.trimEnd(String(firstLine)))\", declared old/new \(hunkData.deletionCount)/\(hunkData.additionCount), parsed old/new \(parsedDeletionLines)/\(parsedAdditionLines)"
            )
            // Re-encode each original boundary using the repaired count.
            // Zero-count ranges use the boundary itself as their start;
            // positive ranges use +1.
            let repairedAdditionStart = getHunkSideStartBoundary(hunkData.additionStart, hunkData.additionCount)
                + (parsedAdditionLines == 0 ? 0 : 1)
            let repairedDeletionStart = getHunkSideStartBoundary(hunkData.deletionStart, hunkData.deletionCount)
                + (parsedDeletionLines == 0 ? 0 : 1)

            // Hydrated hunks index into full-file line arrays, so their
            // indexes must move with repaired starts. Partial hunks index
            // patch-built arrays.
            if !isPartial {
                let additionStartDelta = repairedAdditionStart - hunkData.additionStart
                let deletionStartDelta = repairedDeletionStart - hunkData.deletionStart
                hunkData.additionLineIndex += additionStartDelta
                hunkData.deletionLineIndex += deletionStartDelta
                for index in hunkData.hunkContent.indices {
                    hunkData.hunkContent[index].additionLineIndex += additionStartDelta
                    hunkData.hunkContent[index].deletionLineIndex += deletionStartDelta
                }
            }

            hunkData.additionStart = repairedAdditionStart
            hunkData.deletionStart = repairedDeletionStart
            hunkData.additionCount = parsedAdditionLines
            hunkData.deletionCount = parsedDeletionLines
        }

        hunkData.additionLines = additionLines
        hunkData.deletionLines = deletionLines

        hunkData.collapsedBefore = max(
            getHunkSideStartBoundary(hunkData.additionStart, hunkData.additionCount) - lastHunkEnd,
            0
        )
        lastHunkEnd = getHunkSideEndBoundary(hunkData.additionStart, hunkData.additionCount)
        for content in hunkData.hunkContent {
            switch content {
            case .context(let context):
                hunkData.splitLineCount += context.lines
                hunkData.unifiedLineCount += context.lines
            case .change(let change):
                hunkData.splitLineCount += max(change.additions, change.deletions)
                hunkData.unifiedLineCount += change.deletions + change.additions
            }
        }
        hunkData.splitLineStart = file.splitLineCount + hunkData.collapsedBefore
        hunkData.unifiedLineStart = file.unifiedLineCount + hunkData.collapsedBefore

        file.splitLineCount += hunkData.collapsedBefore + hunkData.splitLineCount
        file.unifiedLineCount += hunkData.collapsedBefore + hunkData.unifiedLineCount
        file.hunks.append(hunkData)
        currentFile = file
    }

    guard var file = currentFile else {
        return nil
    }
    if throwOnError, isPartial, !isGitDiff, file.hunks.isEmpty {
        throw PatchParseError("parsePatchContent: unified file has no hunks")
    }

    // Account for collapsed lines after the final hunk and increment the
    // split/unified counts properly
    if let lastHunk = file.hunks.last, !isPartial, !file.additionLines.isEmpty, !file.deletionLines.isEmpty {
        let lastHunkEnd = getHunkSideEndBoundary(lastHunk.additionStart, lastHunk.additionCount)
        let collapsedAfter = max(file.additionLines.count - lastHunkEnd, 0)
        file.splitLineCount += collapsedAfter
        file.unifiedLineCount += collapsedAfter
    }

    // If this isn't a git diff style patch, then we'll need to sus out some
    // additional metadata manually
    if !isGitDiff {
        if let prevName = file.prevName, file.name != prevName {
            file.type = file.hunks.isEmpty ? .renamePure : .renameChanged
        } else if oldFile == nil || oldFile!.contents.isEmpty, let newFile, !newFile.contents.isEmpty {
            // Sort of a hack for detecting deleted/added files...
            file.type = .new
        } else if let oldFile, !oldFile.contents.isEmpty, newFile == nil || newFile!.contents.isEmpty {
            file.type = .deleted
        }
    }
    if file.type != .renamePure, file.type != .renameChanged {
        file.prevName = nil
    }
    // Pair change-block lines by similarity instead of the patch's positional
    // ordering.
    realignChangeContentBySimilarity(&file)
    return file
}

/// Parses a patch file string into an array of parsed patches.
///
/// - Parameters:
///   - data: The raw patch file content (supports multi-commit patches)
///   - cacheKeyPrefix: Optional prefix for collision-safe cache keys derived
///     from the prefix, patch index, and file index.
///   - throwOnError: When true, invalid data throws. When false, invalid data
///     is reported through `SwiffsDiagnostics` and the parser attempts to
///     recover when possible.
public func parsePatchFiles(_ data: String, cacheKeyPrefix: String? = nil, throwOnError: Bool = false) throws -> [ParsedPatch] {
    var patches: [ParsedPatch] = []
    let rawPatches = hasCommitMetadataBoundary(data) ? splitCommitMetadata(data[...]) : [data[...]]
    for patch in rawPatches {
        do {
            patches.append(try _processPatch(
                patch,
                cacheKeyPrefix: cacheKeyPrefix,
                throwOnError: throwOnError,
                patchIndex: cacheKeyPrefix != nil ? patches.count : nil
            ))
        } catch {
            if throwOnError { throw error }
            SwiffsDiagnostics.error("\(error)")
        }
    }
    return patches
}

/// Non-throwing convenience for `parsePatchFiles` with `throwOnError: false`.
public func parsePatchFiles(_ data: String, cacheKeyPrefix: String? = nil) -> [ParsedPatch] {
    (try? parsePatchFiles(data, cacheKeyPrefix: cacheKeyPrefix, throwOnError: false)) ?? []
}

// MARK: - Helpers

// Decode only quoted tokens, preserving whitespace inside them. Git's a/ and
// b/ prefixes are part of the quoted token and must be removed after decoding.
func decodeDiffFileName(_ value: String, stripGitPrefix: Bool = false) -> String {
    let rawName = JSString.trim(value)
    let name = rawName.hasPrefix("\"") ? (parseQuotedDiffFileName(rawName)?.fileName ?? rawName) : rawName
    if stripGitPrefix, name.hasPrefix("a/") || name.hasPrefix("b/") {
        return String(name.dropFirst(2))
    }
    return name
}

private func hasCommitMetadataBoundary(_ data: String) -> Bool {
    data.hasPrefix("From ") || data.contains("\nFrom ")
}

/// Equivalent of `data.split(/(?=^From [a-f0-9]+ .+$)/m)`.
private func splitCommitMetadata(_ data: Substring) -> [Substring] {
    var parts: [Substring] = []
    let utf8 = data.utf8
    var partStart = utf8.startIndex
    var lineStart = utf8.startIndex
    while lineStart != utf8.endIndex {
        if lineStart != utf8.startIndex, isCommitMetadataLine(data, at: lineStart) {
            parts.append(data[partStart ..< lineStart])
            partStart = lineStart
        }
        // Advance to next line start (after \n or \r).
        var index = lineStart
        while index != utf8.endIndex, utf8[index] != UInt8(ascii: "\n"), utf8[index] != UInt8(ascii: "\r") {
            index = utf8.index(after: index)
        }
        if index == utf8.endIndex { break }
        lineStart = utf8.index(after: index)
    }
    parts.append(data[partStart...])
    return parts
}

private func isCommitMetadataLine(_ data: Substring, at start: Substring.Index) -> Bool {
    let utf8 = data.utf8
    guard data[start...].hasPrefix("From ") else { return false }
    var index = utf8.index(start, offsetBy: 5)
    var hexCount = 0
    while index != utf8.endIndex {
        let byte = utf8[index]
        let isHex = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
        if !isHex { break }
        hexCount += 1
        index = utf8.index(after: index)
    }
    guard hexCount > 0, index != utf8.endIndex, utf8[index] == UInt8(ascii: " ") else { return false }
    index = utf8.index(after: index)
    guard index != utf8.endIndex else { return false }
    let byte = utf8[index]
    return byte != UInt8(ascii: "\n") && byte != UInt8(ascii: "\r")
}

/// File contents split like the upstream parser's local `splitFileContents`
/// (an empty string yields `[""]`).
private func splitFileContentsKeepingEmpty(_ contents: String) -> [String] {
    splitWithNewlines(contents).map(String.init)
}

private func splitGitDiffFiles(_ contents: Substring) -> [Substring] {
    splitAtLinePrefix(contents, "diff --git")
}

private func splitUnifiedDiffFiles(_ contents: Substring) -> [Substring] {
    if contents.isEmpty { return [contents] }
    var parts: [Substring] = []
    let utf8 = contents.utf8
    var partStartIndex = utf8.startIndex
    var lineStartIndex = utf8.startIndex
    var remainingDeletionLines = 0
    var remainingAdditionLines = 0
    var hasOpenedUnifiedFile = false

    while lineStartIndex != utf8.endIndex {
        let nextLineStartIndex = getNextLineStartIndex(contents, lineStartIndex)
        if remainingDeletionLines <= 0, remainingAdditionLines <= 0 {
            if isUnifiedDiffFileHeaderAt(contents, lineStartIndex) {
                if lineStartIndex > partStartIndex {
                    parts.append(contents[partStartIndex ..< lineStartIndex])
                }
                partStartIndex = lineStartIndex
                hasOpenedUnifiedFile = true
                lineStartIndex = getNextLineStartIndex(contents, nextLineStartIndex)
                continue
            }
            if hasOpenedUnifiedFile, contents[lineStartIndex...].hasPrefix("@@ -") {
                if let header = parseHunkHeader(contents[lineStartIndex ..< nextLineStartIndex]) {
                    remainingDeletionLines = header.deletionCount
                    remainingAdditionLines = header.additionCount
                }
            }
            lineStartIndex = nextLineStartIndex
            continue
        }

        let firstChar = utf8[lineStartIndex]
        if firstChar == UInt8(ascii: "\\") {
            lineStartIndex = nextLineStartIndex
            continue
        }
        if firstChar == UInt8(ascii: " ") {
            remainingDeletionLines = max(remainingDeletionLines - 1, 0)
            remainingAdditionLines = max(remainingAdditionLines - 1, 0)
        } else if firstChar == UInt8(ascii: "-") {
            remainingDeletionLines = max(remainingDeletionLines - 1, 0)
        } else if firstChar == UInt8(ascii: "+") {
            remainingAdditionLines = max(remainingAdditionLines - 1, 0)
        }
        lineStartIndex = nextLineStartIndex
    }
    parts.append(contents[partStartIndex...])
    return parts
}

private func startsWithUnifiedDiffFileHeader(_ contents: Substring) -> Bool {
    isUnifiedDiffFileHeaderAt(contents, contents.startIndex)
}

private func isUnifiedDiffFileHeaderAt(_ contents: Substring, _ lineStartIndex: Substring.Index) -> Bool {
    let nextLineStartIndex = getNextLineStartIndex(contents, lineStartIndex)
    return isUnifiedDiffHeaderLineAt(contents, lineStartIndex, "---")
        && isUnifiedDiffHeaderLineAt(contents, nextLineStartIndex, "+++")
}

private func isUnifiedDiffHeaderLineAt(_ contents: Substring, _ lineStartIndex: Substring.Index, _ prefix: String) -> Bool {
    let utf8 = contents.utf8
    guard lineStartIndex < utf8.endIndex, contents[lineStartIndex...].hasPrefix(prefix) else { return false }
    var index = utf8.index(lineStartIndex, offsetBy: prefix.utf8.count)
    guard index != utf8.endIndex else { return false }
    let separator = utf8[index]
    guard separator == UInt8(ascii: " ") || separator == UInt8(ascii: "\t") else { return false }
    index = utf8.index(after: index)
    while index != utf8.endIndex {
        let char = utf8[index]
        if char == UInt8(ascii: "\n") || char == UInt8(ascii: "\r") { break }
        if char != UInt8(ascii: " "), char != UInt8(ascii: "\t") { return true }
        index = utf8.index(after: index)
    }
    return false
}

private func getNextLineStartIndex(_ contents: Substring, _ lineStartIndex: Substring.Index) -> Substring.Index {
    let utf8 = contents.utf8
    guard let newline = utf8[lineStartIndex...].firstIndex(of: UInt8(ascii: "\n")) else {
        return utf8.endIndex
    }
    return utf8.index(after: newline)
}

private func isHunkBodyLine(_ line: Substring) -> Bool {
    let first = line.utf8.first
    return first == UInt8(ascii: "+") || first == UInt8(ascii: "-") || first == UInt8(ascii: " ")
}

private func isFormatPatchVersionSeparator(_ line: Substring) -> Bool {
    guard line.hasPrefix("--") else { return false }
    for byte in line.utf8.dropFirst(2) {
        if byte != UInt8(ascii: " "), byte != UInt8(ascii: "\t"), byte != UInt8(ascii: "\n"), byte != UInt8(ascii: "\r") {
            return false
        }
    }
    return true
}

func parseHunkHeader(_ line: Substring) -> ParsedHunkHeader? {
    guard line.hasPrefix("@@ -") else { return nil }
    let bytes = Array(line.utf8)
    func byte(_ i: Int) -> UInt8? { i < bytes.count ? bytes[i] : nil }
    func readPositiveInteger(_ startIndex: Int) -> (value: Int, endIndex: Int)? {
        var index = startIndex
        var value = 0
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
            value = value &* 10 &+ Int(bytes[index] - 0x30)
            index += 1
        }
        return index == startIndex ? nil : (value, index)
    }

    var index = 4
    guard let deletionStartResult = readPositiveInteger(index) else { return nil }
    let deletionStart = deletionStartResult.value
    index = deletionStartResult.endIndex

    var deletionCount = 1
    if byte(index) == UInt8(ascii: ",") {
        guard let result = readPositiveInteger(index + 1) else { return nil }
        deletionCount = result.value
        index = result.endIndex
    }

    guard byte(index) == UInt8(ascii: " "), byte(index + 1) == UInt8(ascii: "+") else { return nil }
    index += 2

    guard let additionStartResult = readPositiveInteger(index) else { return nil }
    let additionStart = additionStartResult.value
    index = additionStartResult.endIndex

    var additionCount = 1
    if byte(index) == UInt8(ascii: ",") {
        guard let result = readPositiveInteger(index + 1) else { return nil }
        additionCount = result.value
        index = result.endIndex
    }

    guard byte(index) == UInt8(ascii: " "), byte(index + 1) == UInt8(ascii: "@"), byte(index + 2) == UInt8(ascii: "@") else {
        return nil
    }

    var hunkContext: String?
    let contextStartIndex = index + 3
    if byte(contextStartIndex) == UInt8(ascii: " ") {
        let slice = bytes[(contextStartIndex + 1)...]
        hunkContext = trimLineEnd(String(decoding: slice, as: UTF8.self))
    }

    return ParsedHunkHeader(
        additionCount: additionCount,
        additionStart: additionStart,
        deletionCount: deletionCount,
        deletionStart: deletionStart,
        hunkContext: hunkContext
    )
}

private func trimLineEnd(_ value: String) -> String {
    if value.utf8.last == UInt8(ascii: "\n") {
        return cleanLastNewline(value)
    }
    return value
}

private func isGitDiffPatch(_ data: Substring) -> Bool {
    data.hasPrefix("diff --git") || data.contains("\ndiff --git")
}

private func containsLineStarting(_ data: Substring, with prefix: String) -> Bool {
    data.hasPrefix(prefix) || data.contains("\n" + prefix)
}

func splitAtLinePrefix(_ contents: Substring, _ prefix: String) -> [Substring] {
    if contents.isEmpty { return [contents] }
    let newlinePrefix = "\n" + prefix
    let firstBoundary: Substring.Index?
    if contents.hasPrefix(prefix) {
        firstBoundary = contents.startIndex
    } else {
        firstBoundary = findLinePrefixIndex(contents, newlinePrefix, from: contents.startIndex)
    }
    guard let firstBoundary else { return [contents] }

    var parts: [Substring] = []
    if firstBoundary > contents.startIndex {
        parts.append(contents[..<firstBoundary])
    }
    var start = firstBoundary
    while true {
        let searchFrom = contents.utf8.index(after: start)
        guard let next = findLinePrefixIndex(contents, newlinePrefix, from: searchFrom) else { break }
        parts.append(contents[start ..< next])
        start = next
    }
    parts.append(contents[start...])
    return parts
}

private func findLinePrefixIndex(_ contents: Substring, _ newlinePrefix: String, from: Substring.Index) -> Substring.Index? {
    // Byte-level search starting at `from`; returns the index just after the
    // newline.
    guard let range = contents[from...].range(of: newlinePrefix, options: .literal) else {
        return nil
    }
    return contents.utf8.index(after: range.lowerBound)
}

private func getParsedLineContent(_ rawLine: Substring) -> String {
    let processedLine = rawLine.dropFirst()
    return processedLine.isEmpty ? "\n" : String(processedLine)
}

/// Converts a unified hunk side's start/count into its consumed-file range.
public func getHunkSideStartBoundary(_ start: Int, _ count: Int) -> Int {
    start - (count == 0 ? 0 : 1)
}

public func getHunkSideEndBoundary(_ start: Int, _ count: Int) -> Int {
    getHunkSideStartBoundary(start, count) + count
}

/// Port of `getTotalLineCountFromHunks`.
public func getTotalLineCountFromHunks(_ hunks: [Hunk]) -> Int {
    guard let lastHunk = hunks.last else { return 0 }
    return max(
        getHunkSideEndBoundary(lastHunk.additionStart, lastHunk.additionCount),
        getHunkSideEndBoundary(lastHunk.deletionStart, lastHunk.deletionCount)
    )
}

/// Port of `getSingularPatch`.
public func getSingularPatch(_ patch: String) throws -> FileDiffMetadata {
    let parsedPatches = parsePatchFiles(patch)
    guard parsedPatches.count == 1 else {
        throw PatchParseError("PatchDiff: Provided patch must include only 1 patch, with 1 diff")
    }
    let files = parsedPatches[0].files
    guard files.count == 1 else {
        throw PatchParseError("FileDiff: Provided patch must contain exactly 1 file diff")
    }
    return files[0]
}
