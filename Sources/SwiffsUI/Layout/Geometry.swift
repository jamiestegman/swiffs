import AppKit
import SwiffsCore

enum Metrics {
    static let headerHeight: CGFloat = 44
    static let gap: CGFloat = 8
    /// Gutter's right border.
    static let gutterBorder: CGFloat = 2
    /// Border between split columns.
    static let splitBorder: CGFloat = 1
    static let separatorHeight: CGFloat = 32
    static let simpleSeparatorHeight: CGFloat = 4
    static let separatorRadius: CGFloat = 6
    static let barWidth: CGFloat = 4
    static let conflictActionsHeight: CGFloat = 28
    static let iconSize: CGFloat = 16
}

/// The columns an item lays out, known before its rows are built.
struct ItemShape: Equatable {
    enum Kind { case diff, file }

    var kind: Kind
    /// Cell slots in each row: two for a split-style diff, one otherwise.
    var cellCount: Int
    /// Two columns are shown side by side.
    var isSplit: Bool
    var hasDeletionsColumn: Bool
    var hasAdditionsColumn: Bool
    /// Drives the width of the line number column.
    var totalLines: Int
    var hasConflicts: Bool
}

/// One column of an item: its gutter and code.
struct Column: Equatable {
    /// Index into `RenderRow.cells`.
    var cellIndex: Int
    /// The diff side for split columns; nil for unified diffs and files.
    var side: AnnotationSide?
    var minX: CGFloat
    var width: CGFloat
    /// Gutter width including its right border.
    var gutterWidth: CGFloat

    var maxX: CGFloat { minX + width }
    var contentMinX: CGFloat { minX + gutterWidth }
    var contentWidth: CGFloat { max(0, width - gutterWidth) }
    var gutterRect: (minX: CGFloat, width: CGFloat) { (minX, max(0, gutterWidth - Metrics.gutterBorder)) }
}

/// Column placement and paddings for an item's shape at a width.
struct ItemGeometry: Equatable {
    var columns: [Column]
    var contentPaddingStart: CGFloat
    var contentPaddingEnd: CGFloat
    var codePaddingTop: CGFloat
    var codePaddingBottom: CGFloat

    init(shape: ItemShape, width: CGFloat, configuration: DiffConfiguration, ch: CGFloat) {
        let gutterWidth: CGFloat
        if !configuration.showsLineNumbers {
            gutterWidth = shape.kind == .file ? 0 : 4 + Metrics.gutterBorder
        } else {
            let digits = CGFloat(max(1, String(max(shape.totalLines, 0)).count))
            gutterWidth = (3 + digits) * ch + Metrics.gutterBorder
        }
        if shape.cellCount == 2, shape.isSplit {
            let half = (width / 2).rounded(.down)
            columns = [
                Column(cellIndex: 0, side: .deletions, minX: 0, width: half - Metrics.splitBorder, gutterWidth: gutterWidth),
                Column(cellIndex: 1, side: .additions, minX: half + Metrics.splitBorder, width: width - half - Metrics.splitBorder, gutterWidth: gutterWidth),
            ]
        } else if shape.cellCount == 2 {
            // A new or deleted file in a split diff has one full-width column.
            let side: AnnotationSide = shape.hasDeletionsColumn ? .deletions : .additions
            columns = [Column(cellIndex: side == .deletions ? 0 : 1, side: side, minX: 0, width: width, gutterWidth: gutterWidth)]
        } else {
            columns = [Column(cellIndex: 0, side: nil, minX: 0, width: width, gutterWidth: gutterWidth)]
        }
        contentPaddingStart = configuration.indicators == .classic && shape.kind == .diff ? 2 * ch : ch
        contentPaddingEnd = ch
        codePaddingTop = configuration.showsHeaders ? 0 : Metrics.gap
        codePaddingBottom = Metrics.gap
    }

    /// The column showing a side, or the only column.
    func column(for side: AnnotationSide?) -> Column? {
        columns.first { $0.side == nil || $0.side == side } ?? columns.first
    }

    func columnIndex(at x: CGFloat) -> Int? {
        columns.firstIndex { x >= $0.minX && x < $0.maxX }
    }
}

func separatorHeight(_ separator: SeparatorCell) -> CGFloat {
    switch separator.type {
    case .simple:
        Metrics.simpleSeparatorHeight
    case .metadata, .lineInfoBasic:
        Metrics.separatorHeight
    case .lineInfo, .custom:
        Metrics.separatorHeight + (separator.isFirstHunk ? 0 : Metrics.gap) + (separator.isLastHunk ? 0 : Metrics.gap)
    }
}
