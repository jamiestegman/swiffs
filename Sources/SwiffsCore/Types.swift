// Port of `packages/diffs/src/types.ts` from @pierre/diffs.
//
// The data model is intentionally JSON compatible (Codable) and mirrors the
// upstream TypeScript shapes field for field so documents produced by either
// implementation can be exchanged.

import Foundation

/// Represents a file's contents for generating diffs via `parseDiffFromFile`
/// or for when rendering a file directly using the File components.
public struct FileContents: Hashable, Sendable, Codable {
    /// Filename used for display in headers and for inferring the language for
    /// syntax highlighting.
    public var name: String
    /// The raw text contents of the file.
    public var contents: String
    /// Explicitly set the syntax highlighting language instead of inferring
    /// from filename. Generally you should not be setting this.
    public var lang: SupportedLanguage?
    /// Optional header passed to the diff library's `createTwoFilesPatch`.
    public var header: String?
    /// Identifies a file for highlight caching.
    public var cacheKey: String?

    public init(
        name: String,
        contents: String,
        lang: SupportedLanguage? = nil,
        header: String? = nil,
        cacheKey: String? = nil
    ) {
        self.name = name
        self.contents = contents
        self.lang = lang
        self.header = header
        self.cacheKey = cacheKey
    }
}

/// A language identifier (a Shiki/TextMate language id such as `typescript`,
/// or `text` / `ansi`).
public typealias SupportedLanguage = String

/// Describes the type of change for a file in a diff.
public enum ChangeType: String, Hashable, Sendable, Codable, CaseIterable {
    /// File content was modified, name unchanged.
    case change
    /// File was renamed/moved without content changes (100% similarity).
    case renamePure = "rename-pure"
    /// File was renamed/moved and content was also modified.
    case renameChanged = "rename-changed"
    /// A new file was added.
    case new
    /// An existing file was removed.
    case deleted
}

/// Represents a parsed patch file, typically corresponding to a single commit.
public struct ParsedPatch: Hashable, Sendable, Codable {
    /// Optional raw introductory text before the file diffs that may have been
    /// included in the patch (e.g., commit message, author, date).
    public var patchMetadata: String?
    /// Array of file changes contained in the patch.
    public var files: [FileDiffMetadata]

    public init(patchMetadata: String? = nil, files: [FileDiffMetadata]) {
        self.patchMetadata = patchMetadata
        self.files = files
    }
}

/// Represents a block of unchanged context lines within a hunk.
public struct ContextContent: Hashable, Sendable, Codable {
    /// Number of unchanged lines in this context block.
    public var lines: Int
    /// Zero-based index into `FileDiffMetadata.additionLines` where this
    /// context block starts.
    public var additionLineIndex: Int
    /// Zero-based index into `FileDiffMetadata.deletionLines` where this
    /// context block starts.
    public var deletionLineIndex: Int

    public init(lines: Int, additionLineIndex: Int, deletionLineIndex: Int) {
        self.lines = lines
        self.additionLineIndex = additionLineIndex
        self.deletionLineIndex = deletionLineIndex
    }
}

/// Represents a block of changes (additions and/or deletions) within a hunk.
public struct ChangeContent: Hashable, Sendable, Codable {
    /// Number of lines prefixed with `-` in this change block.
    public var deletions: Int
    /// Zero-based index into `FileDiffMetadata.deletionLines` where the
    /// deleted lines start.
    public var deletionLineIndex: Int
    /// Number of lines prefixed with `+` in this change block.
    public var additions: Int
    /// Zero-based index into `FileDiffMetadata.additionLines` where the added
    /// lines start.
    public var additionLineIndex: Int

    public init(deletions: Int, deletionLineIndex: Int, additions: Int, additionLineIndex: Int) {
        self.deletions = deletions
        self.deletionLineIndex = deletionLineIndex
        self.additions = additions
        self.additionLineIndex = additionLineIndex
    }
}

/// A segment of hunk content: a context group or a change group.
public enum HunkContent: Hashable, Sendable {
    case context(ContextContent)
    case change(ChangeContent)

    public var isContext: Bool {
        if case .context = self { return true }
        return false
    }

    public var isChange: Bool {
        if case .change = self { return true }
        return false
    }

    public var additionLineIndex: Int {
        get {
            switch self {
            case .context(let c): return c.additionLineIndex
            case .change(let c): return c.additionLineIndex
            }
        }
        set {
            switch self {
            case .context(var c): c.additionLineIndex = newValue; self = .context(c)
            case .change(var c): c.additionLineIndex = newValue; self = .change(c)
            }
        }
    }

    public var deletionLineIndex: Int {
        get {
            switch self {
            case .context(let c): return c.deletionLineIndex
            case .change(let c): return c.deletionLineIndex
            }
        }
        set {
            switch self {
            case .context(var c): c.deletionLineIndex = newValue; self = .context(c)
            case .change(var c): c.deletionLineIndex = newValue; self = .change(c)
            }
        }
    }
}

extension HunkContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, lines, additions, deletions, additionLineIndex, deletionLineIndex
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let additionLineIndex = try container.decode(Int.self, forKey: .additionLineIndex)
        let deletionLineIndex = try container.decode(Int.self, forKey: .deletionLineIndex)
        switch type {
        case "context":
            self = .context(ContextContent(
                lines: try container.decode(Int.self, forKey: .lines),
                additionLineIndex: additionLineIndex,
                deletionLineIndex: deletionLineIndex
            ))
        case "change":
            self = .change(ChangeContent(
                deletions: try container.decode(Int.self, forKey: .deletions),
                deletionLineIndex: deletionLineIndex,
                additions: try container.decode(Int.self, forKey: .additions),
                additionLineIndex: additionLineIndex
            ))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown hunk content type \(type)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .context(let c):
            try container.encode("context", forKey: .type)
            try container.encode(c.lines, forKey: .lines)
            try container.encode(c.additionLineIndex, forKey: .additionLineIndex)
            try container.encode(c.deletionLineIndex, forKey: .deletionLineIndex)
        case .change(let c):
            try container.encode("change", forKey: .type)
            try container.encode(c.deletions, forKey: .deletions)
            try container.encode(c.deletionLineIndex, forKey: .deletionLineIndex)
            try container.encode(c.additions, forKey: .additions)
            try container.encode(c.additionLineIndex, forKey: .additionLineIndex)
        }
    }
}

/// Represents a single hunk from a diff, corresponding to one `@@ ... @@`
/// block.
public struct Hunk: Hashable, Sendable, Codable {
    /// Number of unchanged lines between the previous hunk (or file start) and
    /// this hunk.
    public var collapsedBefore: Int

    /// Starting line number in the new file version, parsed from the `+X` in
    /// the hunk header.
    public var additionStart: Int
    /// Total line count in the new file version for this hunk (context plus
    /// `+` lines).
    public var additionCount: Int
    /// The number of lines prefixed with `+` in this hunk.
    public var additionLines: Int
    /// Zero-based index into `FileDiffMetadata.additionLines` where this
    /// hunk's content starts.
    public var additionLineIndex: Int

    /// Starting line number in the old file version, parsed from the `-X` in
    /// the hunk header.
    public var deletionStart: Int
    /// Total line count in the old file version for this hunk (context plus
    /// `-` lines).
    public var deletionCount: Int
    /// The number of lines prefixed with `-` in this hunk.
    public var deletionLines: Int
    /// Zero-based index into `FileDiffMetadata.deletionLines` where this
    /// hunk's content starts.
    public var deletionLineIndex: Int

    /// Content segments within this hunk.
    public var hunkContent: [HunkContent]
    /// Function/method name that appears after the `@@` markers if it existed
    /// in the diff.
    public var hunkContext: String?
    /// Raw hunk header string (e.g., `@@ -1,5 +1,7 @@`).
    public var hunkSpecs: String?

    /// Starting line index for this hunk when rendered in split view.
    public var splitLineStart: Int
    /// Total rendered line count for this hunk in split view.
    public var splitLineCount: Int

    /// Starting line index for this hunk when rendered in unified view.
    public var unifiedLineStart: Int
    /// Total rendered line count for this hunk in unified view.
    public var unifiedLineCount: Int

    /// True if the old file version has no trailing newline at end of file.
    public var noEOFCRDeletions: Bool
    /// True if the new file version has no trailing newline at end of file.
    public var noEOFCRAdditions: Bool

    public init(
        collapsedBefore: Int = 0,
        additionStart: Int,
        additionCount: Int,
        additionLines: Int = 0,
        additionLineIndex: Int,
        deletionStart: Int,
        deletionCount: Int,
        deletionLines: Int = 0,
        deletionLineIndex: Int,
        hunkContent: [HunkContent] = [],
        hunkContext: String? = nil,
        hunkSpecs: String? = nil,
        splitLineStart: Int = 0,
        splitLineCount: Int = 0,
        unifiedLineStart: Int = 0,
        unifiedLineCount: Int = 0,
        noEOFCRDeletions: Bool = false,
        noEOFCRAdditions: Bool = false
    ) {
        self.collapsedBefore = collapsedBefore
        self.additionStart = additionStart
        self.additionCount = additionCount
        self.additionLines = additionLines
        self.additionLineIndex = additionLineIndex
        self.deletionStart = deletionStart
        self.deletionCount = deletionCount
        self.deletionLines = deletionLines
        self.deletionLineIndex = deletionLineIndex
        self.hunkContent = hunkContent
        self.hunkContext = hunkContext
        self.hunkSpecs = hunkSpecs
        self.splitLineStart = splitLineStart
        self.splitLineCount = splitLineCount
        self.unifiedLineStart = unifiedLineStart
        self.unifiedLineCount = unifiedLineCount
        self.noEOFCRDeletions = noEOFCRDeletions
        self.noEOFCRAdditions = noEOFCRAdditions
    }
}

/// Metadata and content for a single file's diff. Think of this as a JSON
/// compatible representation of a diff for a single file.
public struct FileDiffMetadata: Hashable, Sendable, Codable {
    /// The file's name and path.
    public var name: String
    /// Previous file path, present only if file was renamed or moved.
    public var prevName: String?
    /// Explicitly override the syntax highlighting language instead of
    /// inferring from filename.
    public var lang: SupportedLanguage?

    /// Object ID for the new file content parsed from the `index` line.
    public var newObjectId: String?
    /// Object ID for the previous file content parsed from the `index` line.
    public var prevObjectId: String?

    /// Git file mode parsed from the diff (e.g., `100644`).
    public var mode: String?
    /// Previous git file mode, present if the mode changed.
    public var prevMode: String?

    /// The type of change for this file.
    public var type: ChangeType

    /// Diff hunks containing line-level change information.
    public var hunks: [Hunk]
    /// Pre-computed line size for this diff if rendered in `split` style.
    public var splitLineCount: Int
    /// Pre-computed line size for this diff if rendered in `unified` style.
    public var unifiedLineCount: Int

    /// Whether the diff was parsed from a patch file (true) or generated from
    /// full file contents (false). When true, `deletionLines`/`additionLines`
    /// contain only the lines present in the patch and hunk expansion is
    /// unavailable.
    public var isPartial: Bool

    /// Lines from the previous version of the file (each line retains its
    /// trailing newline).
    public var deletionLines: [String]
    /// Lines from the new version of the file (each line retains its trailing
    /// newline).
    public var additionLines: [String]

    /// Set while an attached editor's session-scoped hunk updates have
    /// reshaped `hunks` away from a plain recompute.
    public var editSessionDirty: Bool?

    /// Unique key used to avoid re-highlighting the same diff.
    public var cacheKey: String?

    public init(
        name: String,
        prevName: String? = nil,
        lang: SupportedLanguage? = nil,
        newObjectId: String? = nil,
        prevObjectId: String? = nil,
        mode: String? = nil,
        prevMode: String? = nil,
        type: ChangeType = .change,
        hunks: [Hunk] = [],
        splitLineCount: Int = 0,
        unifiedLineCount: Int = 0,
        isPartial: Bool,
        deletionLines: [String] = [],
        additionLines: [String] = [],
        editSessionDirty: Bool? = nil,
        cacheKey: String? = nil
    ) {
        self.name = name
        self.prevName = prevName
        self.lang = lang
        self.newObjectId = newObjectId
        self.prevObjectId = prevObjectId
        self.mode = mode
        self.prevMode = prevMode
        self.type = type
        self.hunks = hunks
        self.splitLineCount = splitLineCount
        self.unifiedLineCount = unifiedLineCount
        self.isPartial = isPartial
        self.deletionLines = deletionLines
        self.additionLines = additionLines
        self.editSessionDirty = editSessionDirty
        self.cacheKey = cacheKey
    }
}

// MARK: - Line and rendering enums

/// Line types that can be parsed from a patch file.
public enum HunkLineType: String, Hashable, Sendable, Codable {
    case context, expanded, addition, deletion, metadata
}

public enum ThemeType: String, Hashable, Sendable, Codable {
    case system, light, dark
}

/// Style of the separators rendered between hunks.
public enum HunkSeparators: String, Hashable, Sendable, Codable {
    case simple
    case metadata
    case lineInfo = "line-info"
    case lineInfoBasic = "line-info-basic"
    /// Deprecated upstream; kept for parity.
    case custom
}

/// How intra-line changes are computed.
public enum LineDiffType: String, Hashable, Sendable, Codable {
    /// Word diff that joins word regions separated by a single character.
    case wordAlt = "word-alt"
    case word
    case char
    case none
}

public enum DiffIndicators: String, Hashable, Sendable, Codable {
    case classic, bars, none
}

public enum DiffStyle: String, Hashable, Sendable, Codable {
    case unified, split
}

public enum Overflow: String, Hashable, Sendable, Codable {
    case scroll, wrap
}

/// Types of rendered lines in a rendered diff.
public enum LineType: String, Hashable, Sendable, Codable {
    case changeDeletion = "change-deletion"
    case changeAddition = "change-addition"
    case context
    case contextExpanded = "context-expanded"
}

public enum AnnotationSide: String, Hashable, Sendable, Codable {
    case deletions, additions
}

public typealias SelectionSide = AnnotationSide

public struct SelectedLineRange: Hashable, Sendable, Codable {
    public var start: Int
    public var side: SelectionSide?
    public var end: Int
    public var endSide: SelectionSide?

    public init(start: Int, side: SelectionSide? = nil, end: Int, endSide: SelectionSide? = nil) {
        self.start = start
        self.side = side
        self.end = end
        self.endSide = endSide
    }
}

public struct SelectionPoint: Hashable, Sendable, Codable {
    public var lineNumber: Int
    public var side: SelectionSide?

    public init(lineNumber: Int, side: SelectionSide?) {
        self.lineNumber = lineNumber
        self.side = side
    }
}

/// Annotation rendered for a file line. Use `lineNumber: 0` to render a
/// file-level annotation above the first rendered file line.
public struct LineAnnotation<Metadata> {
    public var lineNumber: Int
    public var metadata: Metadata

    public init(lineNumber: Int, metadata: Metadata) {
        self.lineNumber = lineNumber
        self.metadata = metadata
    }
}

extension LineAnnotation where Metadata == Void {
    public init(lineNumber: Int) {
        self.init(lineNumber: lineNumber, metadata: ())
    }
}

extension LineAnnotation: Sendable where Metadata: Sendable {}
extension LineAnnotation: Equatable where Metadata: Equatable {}
extension LineAnnotation: Hashable where Metadata: Hashable {}

/// Annotation rendered for one side of a diff line. Use `lineNumber: 0` to
/// render a side-specific file-level annotation above the first hunk.
public struct DiffLineAnnotation<Metadata> {
    public var side: AnnotationSide
    public var lineNumber: Int
    public var metadata: Metadata

    public init(side: AnnotationSide, lineNumber: Int, metadata: Metadata) {
        self.side = side
        self.lineNumber = lineNumber
        self.metadata = metadata
    }
}

extension DiffLineAnnotation where Metadata == Void {
    public init(side: AnnotationSide, lineNumber: Int) {
        self.init(side: side, lineNumber: lineNumber, metadata: ())
    }
}

extension DiffLineAnnotation: Sendable where Metadata: Sendable {}
extension DiffLineAnnotation: Equatable where Metadata: Equatable {}
extension DiffLineAnnotation: Hashable where Metadata: Hashable {}

public struct HunkExpansionRegion: Hashable, Sendable, Codable {
    public var fromStart: Int
    public var fromEnd: Int

    public init(fromStart: Int, fromEnd: Int) {
        self.fromStart = fromStart
        self.fromEnd = fromEnd
    }

    public static let `default` = HunkExpansionRegion(fromStart: 0, fromEnd: 0)
}

public enum ExpansionDirection: String, Hashable, Sendable, Codable {
    case up, down, both
}

/// A window of rendered content, in dense rendered-row indexes for the
/// active diff style.
public struct RenderRange: Hashable, Sendable, Codable {
    public var startingLine: Int
    public var totalLines: Int
    public var bufferBefore: Double
    public var bufferAfter: Double

    public init(startingLine: Int, totalLines: Int, bufferBefore: Double = 0, bufferAfter: Double = 0) {
        self.startingLine = startingLine
        self.totalLines = totalLines
        self.bufferBefore = bufferBefore
        self.bufferAfter = bufferAfter
    }

    /// Equivalent of upstream `DEFAULT_RENDER_RANGE` (`totalLines: Infinity`).
    public static let `default` = RenderRange(startingLine: 0, totalLines: .max)
    public static let empty = RenderRange(startingLine: 0, totalLines: 0)
}

public struct VirtualFileMetrics: Hashable, Sendable, Codable {
    /// Number of rendered lines per hunk chunk when virtualization batches
    /// line rendering.
    public var hunkLineCount: Int
    /// Estimated single-line row height used before a line is measured.
    public var lineHeight: Double
    /// Height reserved for the file or diff header region.
    public var diffHeaderHeight: Double
    /// Height reserved for each collapsed-context separator row.
    public var hunkSeparatorHeight: Double?
    /// Vertical spacing used around hunks and file-level padding.
    public var spacing: Double
    /// Optional top padding applied after the file header.
    public var paddingTop: Double?
    /// Optional bottom padding applied after file content.
    public var paddingBottom: Double?

    public init(
        hunkLineCount: Int,
        lineHeight: Double,
        diffHeaderHeight: Double,
        hunkSeparatorHeight: Double? = nil,
        spacing: Double,
        paddingTop: Double? = nil,
        paddingBottom: Double? = nil
    ) {
        self.hunkLineCount = hunkLineCount
        self.lineHeight = lineHeight
        self.diffHeaderHeight = diffHeaderHeight
        self.hunkSeparatorHeight = hunkSeparatorHeight
        self.spacing = spacing
        self.paddingTop = paddingTop
        self.paddingBottom = paddingBottom
    }
}

public struct CodeViewLayout: Hashable, Sendable, Codable {
    public var paddingTop: Double
    public var paddingBottom: Double
    public var gap: Double

    public init(paddingTop: Double, paddingBottom: Double, gap: Double) {
        self.paddingTop = paddingTop
        self.paddingBottom = paddingBottom
        self.gap = gap
    }
}

public struct SmoothScrollSettings: Hashable, Sendable, Codable {
    /// Natural frequency of the critically-damped spring, in rad/ms.
    public var omega: Double
    /// Distance from destination below which the spring is considered settled.
    public var positionEpsilon: Double
    /// Velocity magnitude (px/ms) below which the spring is stationary.
    public var velocityEpsilon: Double

    public init(omega: Double, positionEpsilon: Double, velocityEpsilon: Double) {
        self.omega = omega
        self.positionEpsilon = positionEpsilon
        self.velocityEpsilon = velocityEpsilon
    }
}

// MARK: - Merge conflicts

public enum MergeConflictMarkerRowType: String, Hashable, Sendable, Codable {
    case markerStart = "marker-start"
    case markerBase = "marker-base"
    case markerSeparator = "marker-separator"
    case markerEnd = "marker-end"
}

public struct MergeConflictMarkerRow: Hashable, Sendable, Codable {
    public var type: MergeConflictMarkerRowType
    public var hunkIndex: Int
    /// Index into `hunk.hunkContent` for the structural block this row belongs
    /// to.
    public var contentIndex: Int
    public var conflictIndex: Int
    public var lineText: String
    /// Unified rendered-row index where this virtual row should be injected.
    public var lineIndex: Int

    public init(
        type: MergeConflictMarkerRowType,
        hunkIndex: Int,
        contentIndex: Int,
        conflictIndex: Int,
        lineText: String,
        lineIndex: Int
    ) {
        self.type = type
        self.hunkIndex = hunkIndex
        self.contentIndex = contentIndex
        self.conflictIndex = conflictIndex
        self.lineText = lineText
        self.lineIndex = lineIndex
    }
}

public enum MergeConflictResolution: String, Hashable, Sendable, Codable {
    case current, incoming, both
}

public struct MergeConflictRegion: Hashable, Sendable, Codable {
    public var conflictIndex: Int
    public var startLineIndex: Int
    public var startLineNumber: Int
    public var separatorLineIndex: Int
    public var separatorLineNumber: Int
    public var endLineIndex: Int
    public var endLineNumber: Int
    public var baseMarkerLineIndex: Int?
    public var baseMarkerLineNumber: Int?

    public init(
        conflictIndex: Int,
        startLineIndex: Int,
        startLineNumber: Int,
        separatorLineIndex: Int,
        separatorLineNumber: Int,
        endLineIndex: Int,
        endLineNumber: Int,
        baseMarkerLineIndex: Int? = nil,
        baseMarkerLineNumber: Int? = nil
    ) {
        self.conflictIndex = conflictIndex
        self.startLineIndex = startLineIndex
        self.startLineNumber = startLineNumber
        self.separatorLineIndex = separatorLineIndex
        self.separatorLineNumber = separatorLineNumber
        self.endLineIndex = endLineIndex
        self.endLineNumber = endLineNumber
        self.baseMarkerLineIndex = baseMarkerLineIndex
        self.baseMarkerLineNumber = baseMarkerLineNumber
    }
}

public struct MergeConflictActionPayload: Hashable, Sendable, Codable {
    public var resolution: MergeConflictResolution
    public var conflict: MergeConflictRegion

    public init(resolution: MergeConflictResolution, conflict: MergeConflictRegion) {
        self.resolution = resolution
        self.conflict = conflict
    }
}

/// Unresolved merge conflict indexes use three different coordinate spaces:
/// source line indexes live on `conflict.*LineIndex`; hunk-content indexes
/// live on the fields below; rendered row indexes live on `markerRows`.
public struct ProcessFileConflictData: Hashable, Sendable, Codable {
    /// Index of the hunk that owns this unresolved conflict.
    public var hunkIndex: Int
    /// First hunk-content entry that belongs to the conflict region.
    public var startContentIndex: Int
    /// Last hunk-content entry that belongs to the conflict region.
    public var endContentIndex: Int
    /// Hunk-content index for the current/ours change block.
    public var currentContentIndex: Int?
    /// Hunk-content index for the optional base context block.
    public var baseContentIndex: Int?
    /// Hunk-content index for the incoming/theirs change block.
    public var incomingContentIndex: Int?
    /// Hunk-content index that anchors the end marker row.
    public var endMarkerContentIndex: Int

    public init(
        hunkIndex: Int,
        startContentIndex: Int,
        endContentIndex: Int,
        currentContentIndex: Int? = nil,
        baseContentIndex: Int? = nil,
        incomingContentIndex: Int? = nil,
        endMarkerContentIndex: Int
    ) {
        self.hunkIndex = hunkIndex
        self.startContentIndex = startContentIndex
        self.endContentIndex = endContentIndex
        self.currentContentIndex = currentContentIndex
        self.baseContentIndex = baseContentIndex
        self.incomingContentIndex = incomingContentIndex
        self.endMarkerContentIndex = endMarkerContentIndex
    }
}

public enum DiffAcceptRejectHunkType: String, Hashable, Sendable, Codable {
    case accept, reject, both
}

public struct DiffAcceptRejectHunkConfig: Hashable, Sendable, Codable {
    public var type: DiffAcceptRejectHunkType
    public var changeIndex: Int

    public init(type: DiffAcceptRejectHunkType, changeIndex: Int) {
        self.type = type
        self.changeIndex = changeIndex
    }
}
