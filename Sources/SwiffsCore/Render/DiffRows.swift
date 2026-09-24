// Native row model for rendered diffs and files.
//
// Port of `DiffHunksRenderer.processDiffResult` / `FileRenderer.
// processFileResult`: instead of HAST gutter/content columns laid out by a CSS
// grid, the result is a list of rows, each holding the cell rendered in every
// column (one column for unified diffs and files, two for split diffs).

import Foundation

/// A code line in a rendered row.
public struct RenderedLine: Hashable, Sendable {
    /// Which line array the content comes from.
    public var side: AnnotationSide
    /// Index into `deletionLines` / `additionLines` (or the file's lines).
    public var lineIndex: Int
    public var lineNumber: Int
    /// The paired line number on the other side (context rows only).
    public var altLineNumber: Int?
    public var lineType: LineType
    public var unifiedLineIndex: Int
    public var splitLineIndex: Int
    public var hunkIndex: Int
    /// The event type from `iterateOverDiff`.
    public var eventType: DiffLineEventType

    public init(
        side: AnnotationSide,
        lineIndex: Int,
        lineNumber: Int,
        altLineNumber: Int? = nil,
        lineType: LineType,
        unifiedLineIndex: Int,
        splitLineIndex: Int,
        hunkIndex: Int,
        eventType: DiffLineEventType
    ) {
        self.side = side
        self.lineIndex = lineIndex
        self.lineNumber = lineNumber
        self.altLineNumber = altLineNumber
        self.lineType = lineType
        self.unifiedLineIndex = unifiedLineIndex
        self.splitLineIndex = splitLineIndex
        self.hunkIndex = hunkIndex
        self.eventType = eventType
    }
}

/// Identifies the annotations attached to a line (`AnnotationSpan`).
public struct AnnotationKey: Hashable, Sendable {
    public var side: AnnotationSide?
    public var lineNumber: Int

    public init(side: AnnotationSide?, lineNumber: Int) {
        self.side = side
        self.lineNumber = lineNumber
    }
}

public struct AnnotationCell: Hashable, Sendable {
    /// Annotation groups rendered in this cell, in order (unified rows can
    /// merge deletion and addition annotations).
    public var keys: [AnnotationKey]
    public var hunkIndex: Int
    public var lineIndex: Int
    /// Line type used to color the gutter next to the annotation.
    public var lineType: LineType

    public init(keys: [AnnotationKey], hunkIndex: Int, lineIndex: Int, lineType: LineType) {
        self.keys = keys
        self.hunkIndex = hunkIndex
        self.lineIndex = lineIndex
        self.lineType = lineType
    }
}

/// Which expansion buttons a separator shows (`HunkData.expandable`).
public struct SeparatorExpandable: Hashable, Sendable {
    public var up: Bool
    public var down: Bool
    public var chunked: Bool
}

public struct SeparatorCell: Hashable, Sendable {
    public var type: HunkSeparators
    public var hunkIndex: Int
    /// Number of hidden lines; nil when unknown (partial diffs that can be
    /// hydrated).
    public var collapsedLines: Int?
    /// `hunkSpecs` for `metadata` separators.
    public var content: String?
    public var expandable: SeparatorExpandable?
    public var isFirstHunk: Bool
    public var isLastHunk: Bool
    public var slotName: String

    /// The label rendered in `line-info` separators.
    public var label: String {
        if type == .metadata { return content ?? "" }
        guard let collapsedLines else { return "More unchanged context may be available" }
        return "\(collapsedLines) unmodified line\(collapsedLines == 1 ? "" : "s")"
    }

    /// Expand buttons, in display order (`createSeparator`).
    public var expandButtons: [ExpansionDirection] {
        guard let expandable, type == .lineInfo || type == .lineInfoBasic else { return [] }
        if !expandable.chunked {
            return [!isFirstHunk && !isLastHunk ? .both : isFirstHunk ? .down : .up]
        }
        var buttons: [ExpansionDirection] = []
        if !isFirstHunk { buttons.append(.up) }
        if !isLastHunk { buttons.append(.down) }
        return buttons
    }
}

public enum RenderCell: Hashable, Sendable {
    case line(RenderedLine)
    case annotation(AnnotationCell)
    /// "No newline at end of file" row.
    case noNewline(LineType)
    /// Empty filler in a split column (`data-content-buffer`).
    case buffer
    case separator(SeparatorCell)
    /// Rows injected by subclasses (merge conflict markers/actions).
    case injected(InjectedCell)
}

public struct InjectedCell: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case mergeConflictMarker(MergeConflictMarkerRowType, text: String)
        case mergeConflictActions(conflictIndex: Int)
    }

    public var kind: Kind
    public var conflictIndex: Int

    public init(kind: Kind, conflictIndex: Int) {
        self.kind = kind
        self.conflictIndex = conflictIndex
    }
}

/// One rendered row: one cell per column.
public struct RenderRow: Hashable, Sendable {
    /// `[unified]` or `[deletions, additions]`; nil when a split column is
    /// absent (new/deleted files render a single column).
    public var cells: [RenderCell?]

    public init(cells: [RenderCell?]) {
        self.cells = cells
    }

    public var unified: RenderCell? { cells.first ?? nil }
    public var deletions: RenderCell? { cells.count == 2 ? cells[0] : nil }
    public var additions: RenderCell? { cells.count == 2 ? cells[1] : nil }
}

/// Mirrors `HunkData`, produced for each line-info separator.
public struct HunkData: Hashable, Sendable {
    public var slotName: String
    public var hunkIndex: Int
    public var lines: Int
    public var lineCountKnown: Bool
    public var type: CodeColumnType
    public var expandable: SeparatorExpandable?
}

public enum CodeColumnType: String, Hashable, Sendable {
    case unified, additions, deletions
}

public struct DiffRowsResult: Sendable {
    public var rows: [RenderRow]
    /// Whether the diff renders as two columns (split with both sides).
    public var isSplit: Bool
    /// Which columns are present: for split diffs `[deletions, additions]`,
    /// either of which may be missing for new/deleted files.
    public var hasDeletionsColumn: Bool
    public var hasAdditionsColumn: Bool
    public var hunkData: [HunkData]
    /// `max(totalLineCountFromHunks, additionLines, deletionLines)`; drives
    /// the line number column width.
    public var totalLines: Int
    public var rowCount: Int { rows.count }
}

public struct DiffRowsOptions: Hashable, Sendable {
    public var diffStyle: DiffStyle
    public var hunkSeparators: HunkSeparators
    public var expandUnchanged: Bool
    public var collapsedContextThreshold: Int
    public var expansionLineCount: Int
    /// True when a `loadDiffFiles` loader is available.
    public var canLoadDiffFiles: Bool

    public init(
        diffStyle: DiffStyle = .split,
        hunkSeparators: HunkSeparators = .lineInfo,
        expandUnchanged: Bool = false,
        collapsedContextThreshold: Int = DiffsConstants.defaultCollapsedContextThreshold,
        expansionLineCount: Int = 100,
        canLoadDiffFiles: Bool = false
    ) {
        self.diffStyle = diffStyle
        self.hunkSeparators = hunkSeparators
        self.expandUnchanged = expandUnchanged
        self.collapsedContextThreshold = collapsedContextThreshold
        self.expansionLineCount = expansionLineCount
        self.canLoadDiffFiles = canLoadDiffFiles
    }
}

public let fileAnnotationLineNumber = 0
public let fileAnnotationHunkIndex = -1
public let fileAnnotationLineIndex = -1

/// Whether a partial diff can load its full contents to expand context.
public func canHydrateCollapsedContext(_ fileDiff: FileDiffMetadata, hasFileLoader: Bool) -> Bool {
    fileDiff.isPartial && hasFileLoader && (fileDiff.type == .change || fileDiff.type == .renameChanged)
}

/// Hook for components that inject extra rows (merge conflicts).
public protocol InjectedRowsProvider {
    func unifiedRows(for context: RenderedLineContext) -> (before: [InjectedCell], after: [InjectedCell])?
    func splitRows(for context: RenderedLineContext) -> (before: [(InjectedCell?, InjectedCell?)], after: [(InjectedCell?, InjectedCell?)])?
}

public struct RenderedLineContext: Sendable {
    public var type: DiffLineEventType
    public var hunkIndex: Int
    public var lineIndex: Int
    public var unifiedLineIndex: Int
    public var splitLineIndex: Int
    public var deletionLine: DiffLineMetadata?
    public var additionLine: DiffLineMetadata?
}

/// Builds the rendered rows for a diff (`processDiffResult`).
///
/// - Parameters:
///   - annotationLines: Line numbers with annotations for each side
///     (`lineNumber: 0` marks file-level annotations).
public func buildDiffRows(
    fileDiff: FileDiffMetadata,
    options: DiffRowsOptions,
    expandedHunks: [Int: HunkExpansionRegion] = [:],
    deletionAnnotationLines: Set<Int> = [],
    additionAnnotationLines: Set<Int> = [],
    renderRange: RenderRange = .default,
    injectedRows: InjectedRowsProvider? = nil
) throws -> DiffRowsResult {
    let unified = options.diffStyle == .unified
    let canHydrateContext = canHydrateCollapsedContext(fileDiff, hasFileLoader: options.canLoadDiffFiles)
    let isExpandableDiff = !fileDiff.isPartial || canHydrateContext

    var unifiedCells: [RenderCell] = []
    var deletionCells: [RenderCell] = []
    var additionCells: [RenderCell] = []
    var hunkData: [HunkData] = []

    let trailingRangeSize = try getTrailingContextRangeSize(
        fileDiff: fileDiff,
        errorPrefix: "DiffHunksRenderer.processDiffResult"
    )

    // Pending one-sided change rows that need a buffer on the other column.
    var pendingSize = 0
    var pendingSide: AnnotationSide?
    func flushPending() {
        if unified { return }
        if pendingSize <= 0 || pendingSide == nil {
            pendingSide = nil
            pendingSize = 0
            return
        }
        for _ in 0 ..< pendingSize {
            if pendingSide == .additions {
                additionCells.append(.buffer)
            } else {
                deletionCells.append(.buffer)
            }
        }
        pendingSize = 0
        pendingSide = nil
    }

    func pushSeparator(_ column: CodeColumnType, hunkIndex: Int, collapsedLines: Int?, rangeSize: Int, hunkSpecs: String?, isFirstHunk: Bool, isLastHunk: Bool) {
        if let collapsedLines, collapsedLines <= 0 { return }
        func append(_ cell: RenderCell) {
            switch column {
            case .unified: unifiedCells.append(cell)
            case .deletions: deletionCells.append(cell)
            case .additions: additionCells.append(cell)
            }
        }
        let slotName = "hunk-separator-\(column.rawValue)-\(hunkIndex)"
        switch options.hunkSeparators {
        case .metadata:
            if let hunkSpecs {
                append(.separator(SeparatorCell(
                    type: .metadata, hunkIndex: hunkIndex, collapsedLines: collapsedLines, content: hunkSpecs,
                    expandable: nil, isFirstHunk: isFirstHunk, isLastHunk: isLastHunk, slotName: slotName
                )))
            }
            return
        case .simple:
            if hunkIndex > 0 {
                append(.separator(SeparatorCell(
                    type: .simple, hunkIndex: hunkIndex, collapsedLines: collapsedLines, content: nil,
                    expandable: nil, isFirstHunk: isFirstHunk, isLastHunk: false, slotName: slotName
                )))
            }
            return
        default:
            break
        }
        let chunked = rangeSize > options.expansionLineCount
        let expandable = isExpandableDiff ? SeparatorExpandable(up: !isFirstHunk, down: !isLastHunk, chunked: chunked) : nil
        append(.separator(SeparatorCell(
            type: options.hunkSeparators,
            hunkIndex: hunkIndex,
            collapsedLines: collapsedLines,
            content: nil,
            expandable: expandable,
            isFirstHunk: isFirstHunk,
            isLastHunk: isLastHunk,
            slotName: slotName
        )))
        hunkData.append(HunkData(
            slotName: slotName,
            hunkIndex: hunkIndex,
            lines: collapsedLines ?? 0,
            lineCountKnown: collapsedLines != nil,
            type: column,
            expandable: expandable
        ))
    }

    func pushSeparators(hunkIndex: Int, collapsedLines: Int?, rangeSize: Int, hunkSpecs: String?, isFirstHunk: Bool, isLastHunk: Bool) {
        flushPending()
        if unified {
            pushSeparator(.unified, hunkIndex: hunkIndex, collapsedLines: collapsedLines, rangeSize: rangeSize, hunkSpecs: hunkSpecs, isFirstHunk: isFirstHunk, isLastHunk: isLastHunk)
        } else {
            pushSeparator(.deletions, hunkIndex: hunkIndex, collapsedLines: collapsedLines, rangeSize: rangeSize, hunkSpecs: hunkSpecs, isFirstHunk: isFirstHunk, isLastHunk: isLastHunk)
            pushSeparator(.additions, hunkIndex: hunkIndex, collapsedLines: collapsedLines, rangeSize: rangeSize, hunkSpecs: hunkSpecs, isFirstHunk: isFirstHunk, isLastHunk: isLastHunk)
        }
    }

    // File-level annotations (lineNumber 0).
    if renderRange.startingLine == fileAnnotationLineNumber, renderRange.totalLines > 0 {
        let hasDeletionFileAnnotations = fileDiff.type != .new && deletionAnnotationLines.contains(fileAnnotationLineNumber)
        let hasAdditionFileAnnotations = fileDiff.type != .deleted && additionAnnotationLines.contains(fileAnnotationLineNumber)
        if hasDeletionFileAnnotations || hasAdditionFileAnnotations {
            let deletionKeys = hasDeletionFileAnnotations ? [AnnotationKey(side: .deletions, lineNumber: 0)] : []
            let additionKeys = hasAdditionFileAnnotations ? [AnnotationKey(side: .additions, lineNumber: 0)] : []
            if unified {
                unifiedCells.append(.annotation(AnnotationCell(
                    keys: deletionKeys + additionKeys, hunkIndex: fileAnnotationHunkIndex,
                    lineIndex: fileAnnotationLineIndex, lineType: .context
                )))
            } else {
                deletionCells.append(.annotation(AnnotationCell(
                    keys: deletionKeys, hunkIndex: fileAnnotationHunkIndex, lineIndex: fileAnnotationLineIndex, lineType: .context
                )))
                additionCells.append(.annotation(AnnotationCell(
                    keys: additionKeys, hunkIndex: fileAnnotationHunkIndex, lineIndex: fileAnnotationLineIndex, lineType: .context
                )))
            }
        }
    }

    func pushSplitInjected(_ rows: [(InjectedCell?, InjectedCell?)]) {
        for (deletion, addition) in rows {
            if deletion == nil, addition == nil { continue }
            let missingSide: AnnotationSide? = deletion != nil && addition != nil ? nil : deletion == nil ? .deletions : .additions
            if missingSide == nil || pendingSide != missingSide {
                flushPending()
            }
            if let deletion { deletionCells.append(.injected(deletion)) }
            if let addition { additionCells.append(.injected(addition)) }
            if let missingSide {
                pendingSide = missingSide
                pendingSize += 1
            }
        }
    }

    try iterateOverDiff(
        diff: fileDiff,
        diffStyle: unified ? .unified : .split,
        startingLine: renderRange.startingLine,
        totalLines: renderRange.totalLines,
        expandedHunks: options.expandUnchanged ? .all : .regions(expandedHunks),
        collapsedContextThreshold: options.collapsedContextThreshold
    ) { props in
        let deletionLine = props.deletionLine
        let additionLine = props.additionLine
        let type = props.type
        let hunkIndex = props.hunkIndex
        let splitLineIndex = deletionLine?.splitLineIndex ?? additionLine!.splitLineIndex
        let unifiedLineIndex = additionLine?.unifiedLineIndex ?? deletionLine!.unifiedLineIndex

        if !unified, type != .change {
            flushPending()
        }

        if props.collapsedBefore > 0 {
            pushSeparators(
                hunkIndex: hunkIndex,
                collapsedLines: props.collapsedBefore,
                rangeSize: max(props.hunk?.collapsedBefore ?? 0, 0),
                hunkSpecs: props.hunk?.hunkSpecs,
                isFirstHunk: hunkIndex == 0,
                isLastHunk: false
            )
        }

        let lineIndex = unified ? unifiedLineIndex : splitLineIndex
        let context = RenderedLineContext(
            type: type,
            hunkIndex: hunkIndex,
            lineIndex: lineIndex,
            unifiedLineIndex: unifiedLineIndex,
            splitLineIndex: splitLineIndex,
            deletionLine: deletionLine,
            additionLine: additionLine
        )

        func renderedLine(_ side: AnnotationSide, _ meta: DiffLineMetadata, _ other: DiffLineMetadata?) -> RenderedLine {
            let lineType: LineType
            switch type {
            case .change: lineType = side == .deletions ? .changeDeletion : .changeAddition
            case .context: lineType = .context
            case .contextExpanded: lineType = .contextExpanded
            }
            return RenderedLine(
                side: side,
                lineIndex: meta.lineIndex,
                lineNumber: meta.lineNumber,
                altLineNumber: type == .change ? nil : other?.lineNumber,
                lineType: lineType,
                unifiedLineIndex: meta.unifiedLineIndex,
                splitLineIndex: splitLineIndex,
                hunkIndex: hunkIndex,
                eventType: type
            )
        }

        if unified {
            let injected = injectedRows?.unifiedRows(for: context)
            for cell in injected?.before ?? [] { unifiedCells.append(.injected(cell)) }
            // Unified rows render the addition line for context rows.
            if let additionLine {
                unifiedCells.append(.line(renderedLine(.additions, additionLine, deletionLine)))
            } else if let deletionLine {
                unifiedCells.append(.line(renderedLine(.deletions, deletionLine, additionLine)))
            }
            var keys: [AnnotationKey] = []
            if let deletionLine, deletionAnnotationLines.contains(deletionLine.lineNumber) {
                keys.append(AnnotationKey(side: .deletions, lineNumber: deletionLine.lineNumber))
            }
            if let additionLine, additionAnnotationLines.contains(additionLine.lineNumber) {
                keys.append(AnnotationKey(side: .additions, lineNumber: additionLine.lineNumber))
            }
            if !keys.isEmpty {
                let lineType: LineType = type == .change
                    ? (deletionLine != nil && additionLine == nil ? .changeDeletion : .changeAddition)
                    : (type == .context ? .context : .contextExpanded)
                unifiedCells.append(.annotation(AnnotationCell(keys: keys, hunkIndex: hunkIndex, lineIndex: lineIndex, lineType: lineType)))
            }
            for cell in injected?.after ?? [] { unifiedCells.append(.injected(cell)) }
        } else {
            let injected = injectedRows?.splitRows(for: context)
            if let before = injected?.before { pushSplitInjected(before) }

            var missingSide: AnnotationSide?
            if type == .change {
                if additionLine == nil { missingSide = .additions } else if deletionLine == nil { missingSide = .deletions }
            }
            if let missingSide {
                if pendingSide != nil, pendingSide != missingSide {
                    flushPending()
                }
                pendingSide = missingSide
                pendingSize += 1
            } else if type == .change {
                // A change row with both sides fills the column a pending
                // one-sided buffer was holding open; flush first so the
                // buffer lands above this row.
                flushPending()
            }

            let deletionHas = deletionLine.map { deletionAnnotationLines.contains($0.lineNumber) } ?? false
            let additionHas = additionLine.map { additionAnnotationLines.contains($0.lineNumber) } ?? false
            let hasAnnotations = deletionHas || additionHas
            if hasAnnotations, pendingSize > 0 {
                flushPending()
            }
            if let deletionLine {
                deletionCells.append(.line(renderedLine(.deletions, deletionLine, additionLine)))
            }
            if let additionLine {
                additionCells.append(.line(renderedLine(.additions, additionLine, deletionLine)))
            }
            if hasAnnotations {
                let deletionType: LineType = type == .change ? (deletionLine != nil ? .changeDeletion : .context) : (type == .context ? .context : .contextExpanded)
                let additionType: LineType = type == .change ? (additionLine != nil ? .changeAddition : .context) : (type == .context ? .context : .contextExpanded)
                deletionCells.append(.annotation(AnnotationCell(
                    keys: deletionHas ? [AnnotationKey(side: .deletions, lineNumber: deletionLine!.lineNumber)] : [],
                    hunkIndex: hunkIndex, lineIndex: lineIndex, lineType: deletionType
                )))
                additionCells.append(.annotation(AnnotationCell(
                    keys: additionHas ? [AnnotationKey(side: .additions, lineNumber: additionLine!.lineNumber)] : [],
                    hunkIndex: hunkIndex, lineIndex: lineIndex, lineType: additionType
                )))
            }
            if let after = injected?.after { pushSplitInjected(after) }
        }

        let hunk = props.hunk
        let isFinalSplitHunkRow = !unified && hunk != nil && splitLineIndex == hunk!.splitLineStart + hunk!.splitLineCount - 1
        let isFinalHunkRow = hunkIndex == fileDiff.hunks.count - 1 && hunk != nil && (
            unified
                ? unifiedLineIndex == hunk!.unifiedLineStart + hunk!.unifiedLineCount - 1
                : splitLineIndex == hunk!.splitLineStart + hunk!.splitLineCount - 1
        )
        let noEOFCRDeletion = (deletionLine?.noEOFCR ?? false) || (isFinalSplitHunkRow && hunk!.noEOFCRDeletions)
        let noEOFCRAddition = (additionLine?.noEOFCR ?? false) || (isFinalSplitHunkRow && hunk!.noEOFCRAdditions)
        if noEOFCRAddition || noEOFCRDeletion {
            if !unified { flushPending() }
            if noEOFCRDeletion {
                let noEOFType: LineType = type == .context ? .context : type == .contextExpanded ? .contextExpanded : .changeDeletion
                if unified {
                    unifiedCells.append(.noNewline(noEOFType))
                } else {
                    deletionCells.append(.noNewline(noEOFType))
                    if !noEOFCRAddition { additionCells.append(.buffer) }
                }
            }
            if noEOFCRAddition {
                let noEOFType: LineType = type == .context ? .context : type == .contextExpanded ? .contextExpanded : .changeAddition
                if unified {
                    unifiedCells.append(.noNewline(noEOFType))
                } else {
                    additionCells.append(.noNewline(noEOFType))
                    if !noEOFCRDeletion { deletionCells.append(.buffer) }
                }
            }
        }

        if options.hunkSeparators != .simple, options.hunkSeparators != .metadata,
           props.collapsedAfter > 0 || (isFinalHunkRow && canHydrateContext)
        {
            pushSeparators(
                hunkIndex: type == .contextExpanded ? hunkIndex : hunkIndex + 1,
                collapsedLines: isFinalHunkRow && canHydrateContext ? nil : props.collapsedAfter,
                rangeSize: trailingRangeSize,
                hunkSpecs: nil,
                isFirstHunk: false,
                isLastHunk: true
            )
        }
        return false
    }

    if !unified { flushPending() }

    let totalLines = max(
        getTotalLineCountFromHunks(fileDiff.hunks),
        fileDiff.additionLines.count,
        fileDiff.deletionLines.count
    )

    let hasBuffer = renderRange.bufferBefore > 0 || renderRange.bufferAfter > 0
    let rows: [RenderRow]
    var hasDeletionsColumn = false
    var hasAdditionsColumn = false
    if unified {
        rows = unifiedCells.map { RenderRow(cells: [$0]) }
    } else {
        hasAdditionsColumn = fileDiff.type != .deleted
        hasDeletionsColumn = fileDiff.type != .new
        let count = max(deletionCells.count, additionCells.count)
        var built: [RenderRow] = []
        built.reserveCapacity(count)
        for i in 0 ..< count {
            let deletion: RenderCell? = hasDeletionsColumn ? (i < deletionCells.count ? deletionCells[i] : .buffer) : nil
            let addition: RenderCell? = hasAdditionsColumn ? (i < additionCells.count ? additionCells[i] : .buffer) : nil
            built.append(RenderRow(cells: [deletion, addition]))
        }
        rows = built
    }
    let hasContent = !rows.isEmpty || hasBuffer
    return DiffRowsResult(
        rows: hasContent ? rows : [],
        isSplit: !unified && hasDeletionsColumn && hasAdditionsColumn,
        hasDeletionsColumn: hasDeletionsColumn,
        hasAdditionsColumn: hasAdditionsColumn,
        hunkData: hunkData,
        totalLines: totalLines
    )
}

public struct FileRowsResult: Sendable {
    public var rows: [RenderRow]
    public var totalLines: Int
}

/// Builds rows for a single file (`processFileResult`).
public func buildFileRows(
    lineCount: Int,
    annotationLines: Set<Int> = [],
    renderRange: RenderRange = .default
) -> FileRowsResult {
    var rows: [RenderRow] = []
    let endLine = renderRange.totalLines == .max ? lineCount : min(renderRange.startingLine + renderRange.totalLines, lineCount)
    if renderRange.startingLine == fileAnnotationLineNumber, renderRange.totalLines > 0, annotationLines.contains(fileAnnotationLineNumber) {
        rows.append(RenderRow(cells: [.annotation(AnnotationCell(
            keys: [AnnotationKey(side: nil, lineNumber: 0)],
            hunkIndex: fileAnnotationHunkIndex,
            lineIndex: fileAnnotationLineIndex,
            lineType: .context
        ))]))
    }
    var lineIndex = renderRange.startingLine
    while lineIndex < endLine {
        let lineNumber = lineIndex + 1
        rows.append(RenderRow(cells: [.line(RenderedLine(
            side: .additions,
            lineIndex: lineIndex,
            lineNumber: lineNumber,
            lineType: .context,
            unifiedLineIndex: lineIndex,
            splitLineIndex: lineIndex,
            hunkIndex: 0,
            eventType: .context
        ))]))
        if annotationLines.contains(lineNumber) {
            rows.append(RenderRow(cells: [.annotation(AnnotationCell(
                keys: [AnnotationKey(side: nil, lineNumber: lineNumber)],
                hunkIndex: 0,
                lineIndex: lineNumber,
                lineType: .context
            ))]))
        }
        lineIndex += 1
    }
    return FileRowsResult(rows: rows, totalLines: lineCount)
}
