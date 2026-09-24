// Geometry of the code grid: column placement (the CSS grid of gutters and
// content columns) and row heights.

import AppKit
import SwiffsCore

struct ColumnGeometry {
    /// Index into `RenderRow.cells`.
    var cellIndex: Int
    /// Side for split columns; nil for unified diffs and files.
    var side: AnnotationSide?
    var minX: CGFloat
    var width: CGFloat
    /// Gutter width including its 2px right border.
    var gutterWidth: CGFloat

    var maxX: CGFloat { minX + width }
    var contentMinX: CGFloat { minX + gutterWidth }
    var contentWidth: CGFloat { max(0, width - gutterWidth) }
    var gutterRect: (minX: CGFloat, width: CGFloat) { (minX, max(0, gutterWidth - GridMetrics.gutterBorder)) }
}

enum GridMetrics {
    /// `--diffs-gap-fallback`
    static let gap: CGFloat = 8
    /// `[data-gutter] ... border-right: 2px solid var(--diffs-bg)`
    static let gutterBorder: CGFloat = 2
    /// Split columns' `border-left/right: 1px solid var(--diffs-bg)`.
    static let splitBorder: CGFloat = 1
    static let separatorHeight: CGFloat = 32
    static let simpleSeparatorHeight: CGFloat = 4
    static let expandButtonWidth: CGFloat = 34
    static let separatorRadius: CGFloat = 6
    static let barWidth: CGFloat = 4
    static let mergeConflictActionsHeight: CGFloat = 28
}

extension CodeGridView {
    func computeColumns(width: CGFloat) -> [ColumnGeometry] {
        let gutterWidth = self.gutterWidth()
        if model.isSplit {
            let half = (width / 2).rounded(.down)
            return [
                ColumnGeometry(cellIndex: 0, side: .deletions, minX: 0, width: half - GridMetrics.splitBorder, gutterWidth: gutterWidth),
                ColumnGeometry(
                    cellIndex: 1,
                    side: .additions,
                    minX: half + GridMetrics.splitBorder,
                    width: width - half - GridMetrics.splitBorder,
                    gutterWidth: gutterWidth
                ),
            ]
        }
        if model.columnCount == 2 {
            // A split diff with one side (new/deleted file) renders a single
            // full-width column.
            let side: AnnotationSide = model.hasDeletionsColumn ? .deletions : .additions
            return [ColumnGeometry(cellIndex: side == .deletions ? 0 : 1, side: side, minX: 0, width: width, gutterWidth: gutterWidth)]
        }
        return [ColumnGeometry(cellIndex: 0, side: nil, minX: 0, width: width, gutterWidth: gutterWidth)]
    }

    /// `[data-column-number]`: `padding-left: 2ch; padding-right: 1ch` around
    /// a number box at least `${totalLines.length}ch` wide, plus the border.
    func gutterWidth() -> CGFloat {
        if options.disableLineNumbers {
            // `min-width: 4px; padding: 0` (files drop the border too).
            return model.kind == .file ? 0 : 4 + GridMetrics.gutterBorder
        }
        let digits = CGFloat(max(1, String(max(model.totalLines, 0)).count))
        return (3 + digits) * style.ch + GridMetrics.gutterBorder
    }

    /// Left padding of line content (`padding-inline: 1ch`, `2ch` for
    /// classic indicators).
    var contentPaddingStart: CGFloat {
        options.diffIndicators == .classic && model.kind == .diff ? 2 * style.ch : style.ch
    }

    var contentPaddingEnd: CGFloat { style.ch }

    /// Top/bottom padding of the code area.
    var codePaddingTop: CGFloat { options.hasHeader ? 0 : GridMetrics.gap }
    var codePaddingBottom: CGFloat { model.rows.isEmpty ? 0 : GridMetrics.gap }

    func separatorHeight(_ separator: SeparatorCell) -> CGFloat {
        switch separator.type {
        case .simple:
            return GridMetrics.simpleSeparatorHeight
        case .metadata, .lineInfoBasic:
            return GridMetrics.separatorHeight
        case .lineInfo, .custom:
            return GridMetrics.separatorHeight
                + (separator.isFirstHunk ? 0 : GridMetrics.gap)
                + (separator.isLastHunk ? 0 : GridMetrics.gap)
        }
    }
}
