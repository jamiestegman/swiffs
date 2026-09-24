// Data rendered by `CodeGridView`: the rows from `buildDiffRows` /
// `buildFileRows` plus line content.

import Foundation
import SwiffsCore
import SwiffsHighlight

enum GridKind: Equatable {
    case diff
    case file
}

/// Supplies line content for the grid.
@MainActor
protocol GridLineProvider: AnyObject {
    /// Highlighted (or plain) content for a line.
    func line(side: AnnotationSide, lineIndex: Int) -> HighlightedLine
}

struct GridModel {
    var kind: GridKind
    var rows: [RenderRow]
    /// `true` for two-column split diffs.
    var isSplit: Bool
    /// Number of cell slots per row (1 for unified/file, 2 for split).
    var columnCount: Int
    /// Which split columns are present (new/deleted files have one).
    var hasDeletionsColumn: Bool
    var hasAdditionsColumn: Bool
    /// Drives the line number column width.
    var totalLines: Int
    var hasMergeConflict = false
    var mergeConflictActionsType: MergeConflictActionsType = .default

    static let empty = GridModel(kind: .diff, rows: [], isSplit: false, columnCount: 1, hasDeletionsColumn: false, hasAdditionsColumn: false, totalLines: 0)

    init(kind: GridKind, rows: [RenderRow], isSplit: Bool, columnCount: Int, hasDeletionsColumn: Bool, hasAdditionsColumn: Bool, totalLines: Int) {
        self.kind = kind
        self.rows = rows
        self.isSplit = isSplit
        self.columnCount = columnCount
        self.hasDeletionsColumn = hasDeletionsColumn
        self.hasAdditionsColumn = hasAdditionsColumn
        self.totalLines = totalLines
    }

    init(diff result: DiffRowsResult, style: DiffStyle) {
        let split = style == .split
        self.init(
            kind: .diff,
            rows: result.rows,
            isSplit: split,
            columnCount: split ? 2 : 1,
            hasDeletionsColumn: result.hasDeletionsColumn,
            hasAdditionsColumn: result.hasAdditionsColumn,
            totalLines: result.totalLines
        )
    }

    init(file result: FileRowsResult) {
        self.init(
            kind: .file,
            rows: result.rows,
            isSplit: false,
            columnCount: 1,
            hasDeletionsColumn: false,
            hasAdditionsColumn: false,
            totalLines: result.totalLines
        )
    }
}

/// Rendering options consumed by the grid.
struct GridOptions: Equatable {
    var overflow: Overflow = .scroll
    var diffIndicators: DiffIndicators = .bars
    var disableBackground = false
    var disableLineNumbers = false
    var hunkSeparators: HunkSeparators = .lineInfo
    var lineHoverHighlight: LineHoverHighlight = .disabled
    var enableGutterUtility = false
    var enableLineSelection = false
    var enableTokenInteractionsOnWhitespace = false
    /// True when the grid is preceded by a file header (removes the top
    /// padding, like `[data-diffs-header] ~ [data-diff] [data-code]`).
    var hasHeader = true
}
