// Port of jsdiff's `patch/create.js` (`structuredPatch`, `formatPatch`,
// `createTwoFilesPatch`).

import Foundation

public struct PatchHeaderOptions: Hashable, Sendable {
    public var includeIndex: Bool
    public var includeUnderline: Bool
    public var includeFileHeaders: Bool

    public init(includeIndex: Bool, includeUnderline: Bool, includeFileHeaders: Bool) {
        self.includeIndex = includeIndex
        self.includeUnderline = includeUnderline
        self.includeFileHeaders = includeFileHeaders
    }

    public static let includeHeaders = PatchHeaderOptions(includeIndex: true, includeUnderline: true, includeFileHeaders: true)
    public static let fileHeadersOnly = PatchHeaderOptions(includeIndex: false, includeUnderline: false, includeFileHeaders: true)
    public static let omitHeaders = PatchHeaderOptions(includeIndex: false, includeUnderline: false, includeFileHeaders: false)
}

/// Equivalent of jsdiff's `CreatePatchOptionsNonabortable`.
public struct CreatePatchOptions: Hashable, Sendable {
    /// Number of context lines surrounding each change (default 4).
    public var context: Int
    public var ignoreCase: Bool
    public var ignoreWhitespace: Bool
    public var ignoreNewlineAtEof: Bool
    public var stripTrailingCr: Bool
    public var maxEditLength: Int?
    public var timeout: Double?
    public var headerOptions: PatchHeaderOptions?

    public init(
        context: Int = 4,
        ignoreCase: Bool = false,
        ignoreWhitespace: Bool = false,
        ignoreNewlineAtEof: Bool = false,
        stripTrailingCr: Bool = false,
        maxEditLength: Int? = nil,
        timeout: Double? = nil,
        headerOptions: PatchHeaderOptions? = nil
    ) {
        self.context = context
        self.ignoreCase = ignoreCase
        self.ignoreWhitespace = ignoreWhitespace
        self.ignoreNewlineAtEof = ignoreNewlineAtEof
        self.stripTrailingCr = stripTrailingCr
        self.maxEditLength = maxEditLength
        self.timeout = timeout
        self.headerOptions = headerOptions
    }

    var diffOptions: DiffOptions {
        DiffOptions(
            ignoreCase: ignoreCase,
            ignoreWhitespace: ignoreWhitespace,
            ignoreNewlineAtEof: ignoreNewlineAtEof,
            stripTrailingCr: stripTrailingCr,
            maxEditLength: maxEditLength,
            timeout: timeout
        )
    }
}

public struct StructuredPatchHunk: Hashable, Sendable {
    public var oldStart: Int
    public var oldLines: Int
    public var newStart: Int
    public var newLines: Int
    public var lines: [String]
}

public struct StructuredPatch: Hashable, Sendable {
    public var oldFileName: String?
    public var newFileName: String?
    public var oldHeader: String?
    public var newHeader: String?
    public var hunks: [StructuredPatchHunk]
    public var isGit: Bool = false
    public var isRename: Bool = false
    public var isCopy: Bool = false
    public var isCreate: Bool = false
    public var isDelete: Bool = false
    public var oldMode: String?
    public var newMode: String?
}

/// `structuredPatch` from jsdiff. Returns nil when the diff was aborted
/// (`maxEditLength` / `timeout`).
public func structuredPatch(
    oldFileName: String,
    newFileName: String,
    oldString: String,
    newString: String,
    oldHeader: String? = nil,
    newHeader: String? = nil,
    options: CreatePatchOptions = CreatePatchOptions()
) -> StructuredPatch? {
    let context = options.context
    guard let diff = LineDiff().diffTokenLines(oldString, newString, options: options.diffOptions) else {
        return nil
    }

    // STEP 1: Build up the patch with no "\ No newline at end of file" lines
    // and with the arrays of lines containing trailing newline characters.
    var entries = diff
    entries.append(LineChange(lines: [], added: false, removed: false))

    var hunks: [StructuredPatchHunk] = []
    var oldRangeStart = 0
    var newRangeStart = 0
    var curRange: [String] = []
    var oldLine = 1
    var newLine = 1

    func contextLines<S: Sequence>(_ lines: S) -> [String] where S.Element == String {
        lines.map { " " + $0 }
    }

    for i in 0 ..< entries.count {
        let current = entries[i]
        let lines = current.lines
        if current.added || current.removed {
            // If we have previous context, start with that
            if oldRangeStart == 0 {
                oldRangeStart = oldLine
                newRangeStart = newLine
                if i > 0 {
                    let prev = entries[i - 1]
                    curRange = context > 0 ? contextLines(prev.lines.suffix(context)) : []
                    oldRangeStart -= curRange.count
                    newRangeStart -= curRange.count
                }
            }
            // Output our changes
            let prefix = current.added ? "+" : "-"
            for line in lines {
                curRange.append(prefix + line)
            }
            // Track the updated file position
            if current.added {
                newLine += lines.count
            } else {
                oldLine += lines.count
            }
        } else {
            // Identical context lines. Track line changes
            if oldRangeStart != 0 {
                // Close out any changes that have been output (or join overlapping)
                if lines.count <= context * 2, i < entries.count - 2 {
                    // Overlapping
                    curRange.append(contentsOf: contextLines(lines))
                } else {
                    // end the range and output
                    let contextSize = min(lines.count, context)
                    curRange.append(contentsOf: contextLines(lines.prefix(contextSize)))
                    hunks.append(StructuredPatchHunk(
                        oldStart: oldRangeStart,
                        oldLines: oldLine - oldRangeStart + contextSize,
                        newStart: newRangeStart,
                        newLines: newLine - newRangeStart + contextSize,
                        lines: curRange
                    ))
                    oldRangeStart = 0
                    newRangeStart = 0
                    curRange = []
                }
            }
            oldLine += lines.count
            newLine += lines.count
        }
    }

    // Step 2: eliminate the trailing `\n` from each line of each hunk, and,
    // where needed, add "\ No newline at end of file".
    for h in hunks.indices {
        var output: [String] = []
        output.reserveCapacity(hunks[h].lines.count + 1)
        for line in hunks[h].lines {
            if line.utf8.last == UInt8(ascii: "\n") {
                output.append(String(line.utf8.dropLast())!)
            } else {
                output.append(line)
                output.append("\\ No newline at end of file")
            }
        }
        hunks[h].lines = output
    }

    return StructuredPatch(
        oldFileName: oldFileName,
        newFileName: newFileName,
        oldHeader: oldHeader,
        newHeader: newHeader,
        hunks: hunks
    )
}

/// Returns true if the filename contains characters that require C-style
/// quoting (as used by Git and GNU diffutils in diff output).
func needsQuoting(_ s: String) -> Bool {
    for unit in s.utf16 {
        if unit < 0x20 || unit > 0x7E || unit == 0x22 || unit == 0x5C {
            return true
        }
    }
    return false
}

/// C-style quotes a filename, encoding special characters as escape sequences
/// and non-ASCII bytes as octal escapes.
func quoteFileNameIfNeeded(_ s: String) -> String {
    if !needsQuoting(s) {
        return s
    }
    var result = "\""
    for b in s.utf8 {
        switch b {
        case 0x07: result += "\\a"
        case 0x08: result += "\\b"
        case 0x09: result += "\\t"
        case 0x0A: result += "\\n"
        case 0x0B: result += "\\v"
        case 0x0C: result += "\\f"
        case 0x0D: result += "\\r"
        case 0x22: result += "\\\""
        case 0x5C: result += "\\\\"
        case 0x20 ... 0x7E: result.unicodeScalars.append(Unicode.Scalar(b))
        default:
            let octal = String(b, radix: 8)
            result += "\\" + String(repeating: "0", count: max(0, 3 - octal.count)) + octal
        }
    }
    result += "\""
    return result
}

/// `formatPatch` from jsdiff.
public func formatPatch(_ patch: StructuredPatch, headerOptions: PatchHeaderOptions? = nil) -> String {
    var headerOptions = headerOptions ?? .includeHeaders
    var ret: [String] = []
    if patch.isGit {
        headerOptions = .includeHeaders
        var gitOldName = patch.oldFileName ?? ""
        var gitNewName = patch.newFileName ?? ""
        if patch.isCreate, gitOldName == "/dev/null" {
            gitOldName = gitNewName.hasPrefix("b/") ? "a/" + gitNewName.dropFirst(2) : gitNewName
        } else if patch.isDelete, gitNewName == "/dev/null" {
            gitNewName = gitOldName.hasPrefix("a/") ? "b/" + gitOldName.dropFirst(2) : gitOldName
        }
        ret.append("diff --git " + quoteFileNameIfNeeded(gitOldName) + " " + quoteFileNameIfNeeded(gitNewName))
        if patch.isDelete {
            ret.append("deleted file mode " + (patch.oldMode ?? "100644"))
        }
        if patch.isCreate {
            ret.append("new file mode " + (patch.newMode ?? "100644"))
        }
        if let oldMode = patch.oldMode, let newMode = patch.newMode, !patch.isDelete, !patch.isCreate {
            ret.append("old mode " + oldMode)
            ret.append("new mode " + newMode)
        }
        func strip(_ name: String?, _ prefix: String) -> String {
            let name = name ?? ""
            return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
        }
        if patch.isRename {
            ret.append("rename from " + quoteFileNameIfNeeded(strip(patch.oldFileName, "a/")))
            ret.append("rename to " + quoteFileNameIfNeeded(strip(patch.newFileName, "b/")))
        }
        if patch.isCopy {
            ret.append("copy from " + quoteFileNameIfNeeded(strip(patch.oldFileName, "a/")))
            ret.append("copy to " + quoteFileNameIfNeeded(strip(patch.newFileName, "b/")))
        }
    } else {
        if headerOptions.includeIndex, patch.oldFileName == patch.newFileName, let name = patch.oldFileName {
            ret.append("Index: " + name)
        }
        if headerOptions.includeUnderline {
            ret.append("===================================================================")
        }
    }
    let hasHunks = !patch.hunks.isEmpty
    if headerOptions.includeFileHeaders, let oldName = patch.oldFileName, let newName = patch.newFileName,
       !patch.isGit || hasHunks
    {
        let oldHeader = (patch.oldHeader?.isEmpty == false) ? "\t" + patch.oldHeader! : ""
        let newHeader = (patch.newHeader?.isEmpty == false) ? "\t" + patch.newHeader! : ""
        ret.append("--- " + quoteFileNameIfNeeded(oldName) + oldHeader)
        ret.append("+++ " + quoteFileNameIfNeeded(newName) + newHeader)
    }
    for hunk in patch.hunks {
        // Unified Diff Format quirk: If the chunk size is 0, the first number
        // is one lower than one would expect.
        let oldStart = hunk.oldLines == 0 ? hunk.oldStart - 1 : hunk.oldStart
        let newStart = hunk.newLines == 0 ? hunk.newStart - 1 : hunk.newStart
        ret.append("@@ -\(oldStart),\(hunk.oldLines) +\(newStart),\(hunk.newLines) @@")
        ret.append(contentsOf: hunk.lines)
    }
    return ret.joined(separator: "\n") + "\n"
}

/// `createTwoFilesPatch` from jsdiff. Returns nil when the diff was aborted.
public func createTwoFilesPatch(
    oldFileName: String,
    newFileName: String,
    oldString: String,
    newString: String,
    oldHeader: String? = nil,
    newHeader: String? = nil,
    options: CreatePatchOptions = CreatePatchOptions()
) -> String? {
    guard let patch = structuredPatch(
        oldFileName: oldFileName,
        newFileName: newFileName,
        oldString: oldString,
        newString: newString,
        oldHeader: oldHeader,
        newHeader: newHeader,
        options: options
    ) else {
        return nil
    }
    return formatPatch(patch, headerOptions: options.headerOptions)
}

/// `createPatch` from jsdiff.
public func createPatch(
    fileName: String,
    oldString: String,
    newString: String,
    oldHeader: String? = nil,
    newHeader: String? = nil,
    options: CreatePatchOptions = CreatePatchOptions()
) -> String? {
    createTwoFilesPatch(
        oldFileName: fileName,
        newFileName: fileName,
        oldString: oldString,
        newString: newString,
        oldHeader: oldHeader,
        newHeader: newHeader,
        options: options
    )
}

// MARK: - Line diff producing line arrays

struct LineChange {
    var lines: [String]
    var added: Bool
    var removed: Bool
}

extension LineDiff {
    /// Runs `diffLines` but keeps each component as an array of line tokens
    /// instead of a joined string. `structuredPatch` would immediately split
    /// the joined value again (`splitLines`), which produces exactly these
    /// tokens, so this avoids the round trip.
    func diffTokenLines(_ oldString: String, _ newString: String, options: DiffOptions) -> [LineChange]? {
        let oldTokens = tokenize(oldString, options: options).filter { !$0.isEmpty }
        let newTokens = tokenize(newString, options: options).filter { !$0.isEmpty }
        var ids: [ExactStringKey: Int] = [:]
        func intern(_ token: String) -> Int {
            let key = ExactStringKey(value: equalityKey(token, options: options))
            if let id = ids[key] { return id }
            let id = ids.count
            ids[key] = id
            return id
        }
        let oldIds = oldTokens.map(intern)
        let newIds = newTokens.map(intern)
        guard let components = MyersDiff.diff(
            old: oldIds,
            new: newIds,
            oneChangePerToken: options.oneChangePerToken,
            maxEditLength: options.maxEditLength,
            timeout: options.timeout
        ) else {
            return nil
        }
        var result: [LineChange] = []
        result.reserveCapacity(components.count)
        var newPos = 0
        var oldPos = 0
        for component in components {
            if !component.removed {
                result.append(LineChange(
                    lines: Array(newTokens[newPos ..< newPos + component.count]),
                    added: component.added,
                    removed: false
                ))
                newPos += component.count
                if !component.added {
                    oldPos += component.count
                }
            } else {
                result.append(LineChange(
                    lines: Array(oldTokens[oldPos ..< oldPos + component.count]),
                    added: false,
                    removed: true
                ))
                oldPos += component.count
            }
        }
        return result
    }
}
