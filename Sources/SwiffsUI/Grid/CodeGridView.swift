// The code grid: draws gutter + content columns for every rendered row with
// Core Text, hosts annotation views and handles pointer interactions
// (the native counterpart of the `<pre>` built by the renderers plus
// `InteractionManager`).

import AppKit
import CoreText
import SwiffsCore
import SwiffsHighlight

/// Interaction callbacks from the grid to its owner.
@MainActor
protocol CodeGridDelegate: AnyObject {
    func grid(_ grid: CodeGridView, annotationViewFor cell: AnnotationCell, column: Int) -> NSView?
    func grid(_ grid: CodeGridView, expandHunk hunkIndex: Int, direction: ExpansionDirection, all: Bool)
    func grid(_ grid: CodeGridView, lineEvent: DiffsLineEvent, kind: GridLineEventKind)
    func grid(_ grid: CodeGridView, tokenEvent: DiffsTokenEvent, kind: GridTokenEventKind)
    func grid(_ grid: CodeGridView, selectionEvent range: SelectedLineRange?, phase: GridSelectionPhase)
    func grid(_ grid: CodeGridView, gutterUtilityClicked range: SelectedLineRange)
    /// Custom view for a merge conflict action row
    /// (`mergeConflictActionsType` as a render function).
    func grid(_ grid: CodeGridView, mergeConflictActionViewFor conflictIndex: Int) -> NSView?
    func grid(_ grid: CodeGridView, mergeConflictAction resolution: MergeConflictResolution, conflictIndex: Int)
    func gridDidChangeHeight(_ grid: CodeGridView)
    /// Whether the owner handles line/number clicks (makes rows interactive).
    var gridHandlesLineClicks: Bool { get }
    var gridHandlesLineNumberClicks: Bool { get }
    var gridHandlesGutterUtilityClicks: Bool { get }
    var gridHandlesTokenEvents: Bool { get }
    var gridHandlesLineHoverEvents: Bool { get }
}

enum GridLineEventKind {
    case click, numberClick, enter, leave
}

enum GridTokenEventKind {
    case click, enter, leave
}

enum GridSelectionPhase {
    case start, change, end, committed
}

/// What lies under a point.
enum GridHit: Equatable {
    case line(row: Int, column: Int, line: RenderedLine, numberColumn: Bool)
    case expand(hunkIndex: Int, direction: ExpansionDirection, all: Bool)
    case utility(row: Int, column: Int)
    case annotation(row: Int, column: Int)
    case mergeAction(row: Int, conflictIndex: Int, resolution: MergeConflictResolution)
    case none
}

final class CodeGridView: NSView {
    weak var delegate: CodeGridDelegate?
    weak var lineProvider: GridLineProvider?

    private(set) var model = GridModel.empty
    private(set) var options = GridOptions()
    private(set) var style: DiffsStyleContext

    // Layout
    private(set) var columns: [ColumnGeometry] = []
    private(set) var rowTops: [CGFloat] = []
    private(set) var rowHeights: [CGFloat] = []
    private(set) var contentHeight: CGFloat = 0
    private var layoutWidth: CGFloat = -1
    private var lineLayouts: [LineKey: LineLayout] = [:]
    private var maxTextWidth: [Int: CGFloat] = [:]
    private var annotationViews: [AnnotationViewKey: NSView] = [:]
    private var annotationHeights: [AnnotationViewKey: CGFloat] = [:]

    /// Shared horizontal offset of the code columns (split columns scroll
    /// together, like `ScrollSyncManager`).
    private(set) var scrollX: CGFloat = 0

    // Interaction state
    private(set) var hoveredRow: Int?
    private(set) var hoveredColumn: Int?
    private(set) var hoveredNumberColumn = false
    private var hoveredLineEvent: DiffsLineEvent?
    private var hoveredToken: DiffsTokenEvent?
    private var hoveredExpand: GridHit?
    private var hoveredMergeAction: GridHit?
    /// Native text selection (see `CodeGridView+TextSelection.swift`).
    var textSelection: GridTextSelection?
    /// Editor state (see `CodeGridView+Editing.swift`).
    let editing = GridEditingState()
    private var textDrag: (column: Int, lower: GridTextPosition, upper: GridTextPosition, granularity: TextSelectionGranularity, moved: Bool)?
    private(set) var lineSelectionRange: SelectedLineRange?
    private var proposedRange: SelectedLineRange??
    private var selectionAnchor: SelectionPoint?
    private var pointerSession: PointerSession = .idle
    var controlledSelection = false
    private var trackingArea: NSTrackingArea?

    private enum PointerSession: Equatable {
        case idle
        case selecting
        case pendingSingleLineUnselect(anchor: SelectionPoint)
        case gutterSelecting(anchor: SelectionPoint, current: SelectionPoint)
    }

    private struct LineKey: Hashable {
        var side: AnnotationSide
        var lineIndex: Int
        var dimmed: Bool
    }

    private struct AnnotationViewKey: Hashable {
        var row: Int
        var column: Int
    }

    /// Maps selection points to row indexes (`getLineIndex`).
    var lineIndexResolver: ((Int, AnnotationSide?) -> (unified: Int, split: Int)?)?

    init(style: DiffsStyleContext) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    // MARK: - Updates

    func update(model: GridModel, options: GridOptions, style: DiffsStyleContext) {
        let styleChanged = style !== self.style
        let sameShape = model.kind == self.model.kind && model.isSplit == self.model.isSplit
        // Appending rows (streaming) keeps cached layouts and views.
        let appendedOnly = sameShape && model.rows.count >= self.model.rows.count && model.rows.starts(with: self.model.rows)
        let rowsChanged = !appendedOnly && (model.rows != self.model.rows || !sameShape)
        self.model = model
        self.options = options
        self.style = style
        if styleChanged || rowsChanged {
            lineLayouts.removeAll()
            maxTextWidth.removeAll()
        }
        if rowsChanged {
            textSelection = nil
            for view in annotationViews.values { view.removeFromSuperview() }
            annotationViews.removeAll()
            annotationHeights.removeAll()
        }
        layoutWidth = -1
        relayout(width: bounds.width)
        if isEditing { rebuildEditorLineRows() }
        needsDisplay = true
    }

    /// Drops cached layouts of specific lines (streamed content changed).
    func invalidateLines<S: Sequence>(side: AnnotationSide, lineIndexes: S) where S.Element == Int {
        for lineIndex in lineIndexes {
            lineLayouts[LineKey(side: side, lineIndex: lineIndex, dimmed: false)] = nil
            lineLayouts[LineKey(side: side, lineIndex: lineIndex, dimmed: true)] = nil
        }
        if options.overflow == .wrap {
            layoutWidth = -1
            relayout(width: bounds.width)
        }
        needsDisplay = true
    }

    /// Drops cached line layouts (after highlighting results arrive).
    func invalidateLines() {
        lineLayouts.removeAll()
        maxTextWidth.removeAll()
        if options.overflow == .wrap {
            layoutWidth = -1
            relayout(width: bounds.width)
        }
        needsDisplay = true
    }

    func setSelectedRange(_ range: SelectedLineRange?) {
        lineSelectionRange = range
        proposedRange = nil
        needsDisplay = true
    }

    /// Height needed for the current rows at `width`.
    func requiredHeight(forWidth width: CGFloat) -> CGFloat {
        if width != layoutWidth { relayout(width: width) }
        return contentHeight
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged {
            relayout(width: newSize.width)
        }
    }

    private func relayout(width: CGFloat) {
        guard width > 0 else { return }
        if width != layoutWidth, options.overflow == .wrap {
            lineLayouts.removeAll()
        }
        layoutWidth = width
        columns = computeColumns(width: width)
        let lineHeight = style.lineHeight
        var tops: [CGFloat] = []
        var heights: [CGFloat] = []
        tops.reserveCapacity(model.rows.count)
        heights.reserveCapacity(model.rows.count)
        var y = codePaddingTop
        for (rowIndex, row) in model.rows.enumerated() {
            var height: CGFloat = 0
            for (columnIndex, column) in columns.enumerated() {
                guard column.cellIndex < row.cells.count, let cell = row.cells[column.cellIndex] else { continue }
                let cellHeight: CGFloat
                switch cell {
                case .line(let line):
                    if options.overflow == .wrap {
                        cellHeight = CGFloat(layout(for: line, column: column).visualLineCount) * lineHeight
                    } else {
                        cellHeight = lineHeight
                    }
                case .annotation(let annotation):
                    cellHeight = measureAnnotation(annotation, row: rowIndex, column: columnIndex, geometry: column)
                case .noNewline, .buffer:
                    cellHeight = lineHeight
                case .separator(let separator):
                    cellHeight = separatorHeight(separator)
                case .injected(let injected):
                    if case .mergeConflictActions(let conflictIndex) = injected.kind {
                        cellHeight = measureMergeActions(conflictIndex: conflictIndex, row: rowIndex, column: columnIndex, geometry: column)
                    } else {
                        cellHeight = lineHeight
                    }
                }
                height = max(height, cellHeight)
            }
            tops.append(y)
            heights.append(height)
            y += height
        }
        rowTops = tops
        rowHeights = heights
        let newHeight = model.rows.isEmpty ? 0 : y + codePaddingBottom
        let heightChanged = newHeight != contentHeight
        contentHeight = newHeight
        clampScrollX()
        layoutAnnotationViews()
        if heightChanged {
            delegate?.gridDidChangeHeight(self)
        }
    }

    // MARK: - Lines

    private func wrapWidth(for column: ColumnGeometry) -> CGFloat? {
        guard options.overflow == .wrap else { return nil }
        return max(style.ch * 4, column.contentWidth - contentPaddingStart - contentPaddingEnd)
    }

    func layout(for line: RenderedLine, column: ColumnGeometry) -> LineLayout {
        let key = LineKey(side: line.side, lineIndex: line.lineIndex, dimmed: false)
        if let cached = lineLayouts[key] { return cached }
        let highlighted = lineProvider?.line(side: line.side, lineIndex: line.lineIndex) ?? HighlightedLine(text: "", tokens: [])
        let layout = LineLayout.make(highlighted, style: style, wrapWidth: wrapWidth(for: column))
        lineLayouts[key] = layout
        if layout.width > maxTextWidth[column.cellIndex] ?? 0 {
            maxTextWidth[column.cellIndex] = layout.width
        }
        return layout
    }

    /// Estimated widest line per column for the horizontal scroll range.
    private func estimatedMaxTextWidth(for column: ColumnGeometry) -> CGFloat {
        if let known = maxTextWidth[column.cellIndex], known > 0 {
            return known
        }
        return 0
    }

    private func maxScrollX(for column: ColumnGeometry) -> CGFloat {
        guard options.overflow == .scroll else { return 0 }
        let textWidth = estimatedMaxTextWidth(for: column)
        return max(0, textWidth + contentPaddingStart + contentPaddingEnd - column.contentWidth)
    }

    private var maxScrollX: CGFloat {
        columns.map(maxScrollX(for:)).max() ?? 0
    }

    private func clampScrollX() {
        scrollX = max(0, min(scrollX, maxScrollX))
    }

    /// Lays out every line of a column to learn the scroll width. Called
    /// lazily when horizontal scrolling starts.
    private func measureAllLineWidths() {
        for row in model.rows {
            for column in columns {
                guard column.cellIndex < row.cells.count, case .line(let line)? = row.cells[column.cellIndex] else { continue }
                _ = layout(for: line, column: column)
            }
        }
    }

    // MARK: - Annotations

    private func measureAnnotation(_ annotation: AnnotationCell, row: Int, column: Int, geometry: ColumnGeometry) -> CGFloat {
        let key = AnnotationViewKey(row: row, column: column)
        var view = annotationViews[key]
        if view == nil, !annotation.keys.isEmpty, let created = delegate?.grid(self, annotationViewFor: annotation, column: column) {
            annotationViews[key] = created
            addSubview(created)
            view = created
        }
        guard let view else { return 0 }
        let width = geometry.contentWidth
        let height: CGFloat
        if let measured = annotationHeights[key], abs((view.frame.width) - width) < 0.5 {
            height = measured
        } else {
            view.frame.size.width = width
            view.layoutSubtreeIfNeeded()
            let fitting = view.fittingSize.height
            height = max(0, fitting > 0 ? fitting : view.intrinsicContentSize.height)
            annotationHeights[key] = height
        }
        return height
    }

    /// `[data-merge-conflict-actions-content]` has `min-height: 1.75rem`;
    /// custom action views may grow it.
    private func measureMergeActions(conflictIndex: Int, row: Int, column: Int, geometry: ColumnGeometry) -> CGFloat {
        let minimum = GridMetrics.mergeConflictActionsHeight
        guard model.mergeConflictActionsType == .custom else { return minimum }
        let key = AnnotationViewKey(row: row, column: column)
        var view = annotationViews[key]
        if view == nil, let created = delegate?.grid(self, mergeConflictActionViewFor: conflictIndex) {
            annotationViews[key] = created
            addSubview(created)
            view = created
        }
        guard let view else { return minimum }
        let width = geometry.contentWidth
        if let measured = annotationHeights[key], abs(view.frame.width - width) < 0.5 {
            return max(minimum, measured)
        }
        view.frame.size.width = width
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize.height
        let height = max(0, fitting > 0 ? fitting : view.intrinsicContentSize.height)
        annotationHeights[key] = height
        return max(minimum, height)
    }

    private func layoutAnnotationViews() {
        for (key, view) in annotationViews {
            guard key.row < rowTops.count, key.column < columns.count else {
                view.isHidden = true
                continue
            }
            let column = columns[key.column]
            view.isHidden = false
            view.frame = CGRect(
                x: column.contentMinX,
                y: rowTops[key.row],
                width: column.contentWidth,
                height: rowHeights[key.row]
            )
        }
    }

    /// Re-measures annotation views (call after their content changes).
    func invalidateAnnotationSizes() {
        annotationHeights.removeAll()
        layoutWidth = -1
        relayout(width: bounds.width)
        needsDisplay = true
    }

    // MARK: - Hit testing

    func rowIndex(at y: CGFloat) -> Int? {
        guard !rowTops.isEmpty else { return nil }
        var low = 0
        var high = rowTops.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if y < rowTops[mid] {
                high = mid - 1
            } else if y >= rowTops[mid] + rowHeights[mid] {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    func columnIndex(at x: CGFloat) -> Int? {
        for (index, column) in columns.enumerated() where x >= column.minX && x < column.maxX {
            return index
        }
        return nil
    }

    func hitTest(point: CGPoint) -> GridHit {
        guard let row = rowIndex(at: point.y), let columnIndex = columnIndex(at: point.x) else { return .none }
        let column = columns[columnIndex]
        let rowData = model.rows[row]
        if let utility = utilityButtonRect(), utility.row == row, utility.rect.contains(point) {
            return .utility(row: row, column: utility.column)
        }
        // Separators are drawn across the row; buttons live in the first
        // column.
        if let separator = separatorCell(in: rowData) {
            return hitSeparator(separator, row: row, point: point)
        }
        guard column.cellIndex < rowData.cells.count, let cell = rowData.cells[column.cellIndex] else { return .none }
        switch cell {
        case .line(let line):
            return .line(row: row, column: columnIndex, line: line, numberColumn: point.x < column.contentMinX)
        case .annotation:
            return .annotation(row: row, column: columnIndex)
        case .injected(let injected):
            guard case .mergeConflictActions(let conflictIndex) = injected.kind, model.mergeConflictActionsType == .default else {
                return .none
            }
            let contentRect = CGRect(x: column.contentMinX, y: rowTops[row], width: column.contentWidth, height: rowHeights[row])
            for frame in mergeActionFrames(contentRect: contentRect) where frame.1.contains(point) {
                return .mergeAction(row: row, conflictIndex: conflictIndex, resolution: frame.0)
            }
            return .none
        default:
            return .none
        }
    }

    private func separatorCell(in row: RenderRow) -> SeparatorCell? {
        for cell in row.cells {
            if case .separator(let separator)? = cell { return separator }
        }
        return nil
    }

    private func hitSeparator(_ separator: SeparatorCell, row: Int, point: CGPoint) -> GridHit {
        guard let first = columns.first, separator.expandable != nil else { return .none }
        let frames = separatorFrames(separator, row: row, column: first)
        for (direction, rect) in frames.buttons where rect.contains(point) {
            return .expand(hunkIndex: separator.hunkIndex, direction: direction, all: false)
        }
        if let content = frames.content, content.contains(point) {
            return .expand(hunkIndex: separator.hunkIndex, direction: .both, all: false)
        }
        return .none
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dirtyRect = dirtyRect.intersection(bounds)
        context.clip(to: bounds)
        let palette = style.palette
        context.setFillColor(style.cgColor(palette.bg))
        context.fill(dirtyRect)
        guard !rowTops.isEmpty else { return }
        var row = firstRow(atOrBelow: dirtyRect.minY)
        while row < rowTops.count, rowTops[row] < dirtyRect.maxY {
            drawRow(row, context: context)
            row += 1
        }
    }

    private func firstRow(atOrBelow y: CGFloat) -> Int {
        var low = 0
        var high = rowTops.count
        while low < high {
            let mid = (low + high) / 2
            if rowTops[mid] + rowHeights[mid] <= y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func drawRow(_ rowIndex: Int, context: CGContext) {
        let row = model.rows[rowIndex]
        let top = rowTops[rowIndex]
        let height = rowHeights[rowIndex]
        if let separator = separatorCell(in: row) {
            drawSeparatorRow(separator, row: rowIndex, top: top, height: height, context: context)
            return
        }
        for (columnIndex, column) in columns.enumerated() {
            guard column.cellIndex < row.cells.count, let cell = row.cells[column.cellIndex] else { continue }
            drawCell(cell, row: rowIndex, columnIndex: columnIndex, column: column, top: top, height: height, context: context)
        }
    }

    private func isHovered(row: Int, column: Int) -> Bool {
        hoveredRow == row && hoveredColumn == column
    }

    private func lineState(for line: RenderedLine?, lineType: LineType?, row: Int, column: Int, numberCell: Bool) -> LineVisualState {
        let hovered: Bool = {
            guard isHovered(row: row, column: column) || (hoveredRow == row && !model.isSplit) else { return false }
            switch options.lineHoverHighlight {
            case .disabled: return false
            case .both: return true
            case .line: return !numberCell
            case .number: return numberCell
            }
        }()
        return LineVisualState(
            lineType: lineType,
            backgroundEnabled: !options.disableBackground,
            selected: isRowSelected(row: row, column: column),
            hovered: hovered,
            hasMergeConflict: model.hasMergeConflict
        )
    }

    private func drawCell(_ cell: RenderCell, row: Int, columnIndex: Int, column: ColumnGeometry, top: CGFloat, height: CGFloat, context: CGContext) {
        let palette = style.palette
        let gutter = column.gutterRect
        let gutterRect = CGRect(x: gutter.minX, y: top, width: gutter.width, height: height)
        let contentRect = CGRect(x: column.contentMinX, y: top, width: column.contentWidth, height: height)
        switch cell {
        case .line(let line):
            // Unresolved files render change lines as context tinted by
            // conflict side (`getUnifiedLineDecoration`).
            var visualType = line.lineType
            var tint: MergeConflictLineTint?
            if model.hasMergeConflict, line.lineType == .changeDeletion || line.lineType == .changeAddition {
                tint = line.lineType == .changeDeletion ? .current : .incoming
                visualType = .context
            }
            var contentState = lineState(for: line, lineType: visualType, row: row, column: columnIndex, numberCell: false)
            var numberState = lineState(for: line, lineType: visualType, row: row, column: columnIndex, numberCell: true)
            contentState.mergeConflict = tint
            numberState.mergeConflict = tint
            fill(contentRect, palette.background(for: .line, state: contentState), context)
            let selectionRects = textSelectionRects(row: row, column: columnIndex, top: top)
            if !selectionRects.isEmpty {
                context.saveGState()
                context.clip(to: contentRect)
                context.setFillColor(textSelectionColor)
                context.fill(selectionRects)
                context.restoreGState()
            }
            if isEditing { drawEditorBackground(line: line, row: row, column: columnIndex, contentRect: contentRect, context: context) }
            drawLineText(line, column: column, top: top, contentRect: contentRect, context: context)
            if isEditing { drawEditorForeground(line: line, row: row, column: columnIndex, contentRect: contentRect, context: context) }
            fill(gutterRect, palette.background(for: .lineNumber, state: numberState), context)
            drawIndicator(for: visualType, gutterRect: gutterRect, contentRect: contentRect, context: context)
            if !options.disableLineNumbers {
                drawLineNumber(line.lineNumber, color: palette.lineNumberColor(state: numberState), gutterRect: gutterRect, top: top, context: context)
            }
            if let utility = utilityButtonRect(), utility.row == row, utility.column == columnIndex {
                drawUtilityButton(utility.rect, context: context)
            }
        case .annotation(let annotation):
            let selected = isRowSelected(row: row, column: columnIndex)
            let state = LineVisualState(lineType: nil, backgroundEnabled: !options.disableBackground, selected: selected, hasMergeConflict: model.hasMergeConflict)
            _ = annotation
            fill(contentRect, palette.background(for: .annotation, state: state), context)
            // `[data-gutter-buffer='annotation']` carries no line type.
            var gutterState = state
            gutterState.lineType = nil
            fill(gutterRect, palette.background(for: .gutterBuffer(.annotation), state: gutterState), context)
        case .noNewline(let lineType):
            let state = LineVisualState(lineType: lineType, backgroundEnabled: !options.disableBackground)
            fill(contentRect, palette.background(for: .noNewline, state: state), context)
            fill(gutterRect, palette.background(for: .gutterBuffer(.metadata), state: state), context)
            drawIndicator(for: lineType, gutterRect: nil, contentRect: contentRect, context: context)
            let color = style.cgColor(palette.fg.withAlpha(palette.fg.a * 0.6))
            let text = makeTextLine("No newline at end of file", font: style.typography.codeFont, color: color)
            context.saveGState()
            context.clip(to: contentRect)
            drawTextLine(text, in: context, x: column.contentMinX + contentPaddingStart - scrollX, baseline: top + style.baseline)
            context.restoreGState()
        case .buffer:
            fill(gutterRect, palette.bgContextGutter, context)
            drawHatch(contentRect, column: column, context: context)
        case .separator:
            break
        case .injected(let injected):
            drawInjected(injected, row: row, columnIndex: columnIndex, column: column, top: top, height: height, context: context)
        }
    }

    private func fill(_ rect: CGRect, _ color: RGBAColor, _ context: CGContext) {
        context.setFillColor(style.cgColor(color))
        context.fill(rect)
    }

    private func drawLineText(_ line: RenderedLine, column: ColumnGeometry, top: CGFloat, contentRect: CGRect, context: CGContext) {
        let layout = layout(for: line, column: column)
        context.saveGState()
        context.clip(to: contentRect)
        let x = column.contentMinX + contentPaddingStart - (options.overflow == .scroll ? scrollX : 0)
        let spanColor = style.palette.diffSpanBackground(lineType: line.lineType).map(style.cgColor)
        layout.draw(in: context, origin: CGPoint(x: x, y: top), style: style, spanColor: spanColor)
        context.restoreGState()
    }

    private func drawLineNumber(_ number: Int, color: RGBAColor, gutterRect: CGRect, top: CGFloat, context: CGContext) {
        let text = makeTextLine(String(number), font: style.typography.codeFont, color: style.cgColor(color))
        let width = textLineWidth(text)
        let right = gutterRect.maxX - style.ch
        drawTextLine(text, in: context, x: right - width, baseline: top + style.baseline)
    }

    private func drawIndicator(for lineType: LineType, gutterRect: CGRect?, contentRect: CGRect, context: CGContext) {
        guard model.kind == .diff else { return }
        let palette = style.palette
        switch options.diffIndicators {
        case .bars:
            guard let gutterRect, lineType == .changeAddition || lineType == .changeDeletion else { return }
            let bar = CGRect(x: gutterRect.minX, y: gutterRect.minY, width: GridMetrics.barWidth, height: gutterRect.height)
            if lineType == .changeAddition {
                fill(bar, palette.additionBase, context)
            } else {
                // `linear-gradient(0deg, bg-deletion 50%, deletion-base 50%)`
                // tiled every 2px.
                fill(bar, palette.bgDeletion, context)
                context.setFillColor(style.cgColor(palette.deletionBase))
                var y = bar.minY
                while y < bar.maxY {
                    context.fill(CGRect(x: bar.minX, y: y, width: bar.width, height: min(1, bar.maxY - y)))
                    y += 2
                }
            }
        case .classic:
            guard lineType == .changeAddition || lineType == .changeDeletion else { return }
            let symbol = lineType == .changeAddition ? "+" : "-"
            let color = lineType == .changeAddition ? palette.additionBase : palette.deletionBase
            let text = makeTextLine(symbol, font: style.typography.codeFont, color: style.cgColor(color))
            context.saveGState()
            context.clip(to: contentRect)
            drawTextLine(text, in: context, x: contentRect.minX - (options.overflow == .scroll ? scrollX : 0), baseline: contentRect.minY + style.baseline)
            context.restoreGState()
        case .none:
            break
        }
    }

    /// `[data-content-buffer]`: diagonal stripes of `--diffs-bg-buffer`
    /// (`repeating-linear-gradient(-45deg, ...)` on an 8px tile).
    private func drawHatch(_ rect: CGRect, column: ColumnGeometry, context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        context.setStrokeColor(style.cgColor(style.palette.bgBuffer))
        context.setLineWidth(1.414)
        let period: CGFloat = 8
        // Lines x + y = c, anchored to the column so stripes stay continuous
        // across rows.
        let phase = column.contentMinX + 5 + 4.95
        let minC = rect.minX + rect.minY - period
        let maxC = rect.maxX + rect.maxY + period
        var c = phase + ((minC - phase) / period).rounded(.down) * period
        while c <= maxC {
            context.move(to: CGPoint(x: c - rect.maxY, y: rect.maxY))
            context.addLine(to: CGPoint(x: c - rect.minY, y: rect.minY))
            c += period
        }
        context.strokePath()
        context.restoreGState()
    }

    // MARK: Separators

    struct SeparatorFrames {
        var pill: CGRect?
        var buttons: [(ExpansionDirection, CGRect)]
        var content: CGRect?
        var textX: CGFloat
    }

    func separatorFrames(_ separator: SeparatorCell, row: Int, column: ColumnGeometry) -> SeparatorFrames {
        let top = rowTops[row]
        let marginTop: CGFloat = separator.type == .lineInfo || separator.type == .custom ? (separator.isFirstHunk ? 0 : GridMetrics.gap) : 0
        let height = min(GridMetrics.separatorHeight, rowHeights[row])
        let y = top + marginTop
        let buttons = separator.expandButtons
        let gutterRight = column.minX + column.gutterWidth
        switch separator.type {
        case .lineInfo, .custom:
            let unified = !model.isSplit
            let leftInset = column.minX + GridMetrics.gap
            let buttonRight = gutterRight - GridMetrics.gutterBorder
            var buttonFrames: [(ExpansionDirection, CGRect)] = []
            var contentMinX = leftInset
            if !buttons.isEmpty {
                let buttonRect = CGRect(x: leftInset, y: y, width: max(0, buttonRight - leftInset), height: height)
                buttonFrames = splitButtons(buttons, in: buttonRect)
                contentMinX = gutterRight
            }
            let contentMaxX = unified ? column.maxX - GridMetrics.gap : column.maxX
            let content = CGRect(x: contentMinX, y: y, width: max(0, contentMaxX - contentMinX), height: height)
            return SeparatorFrames(
                pill: CGRect(x: leftInset, y: y, width: max(0, contentMaxX - leftInset), height: height),
                buttons: buttonFrames,
                content: content,
                textX: content.minX + style.ch
            )
        case .lineInfoBasic:
            var buttonFrames: [(ExpansionDirection, CGRect)] = []
            var contentMinX = column.minX
            if !buttons.isEmpty {
                let buttonRect = CGRect(x: column.minX, y: y, width: max(0, gutterRight - GridMetrics.gutterBorder - column.minX), height: height)
                buttonFrames = splitButtons(buttons, in: buttonRect)
                contentMinX = gutterRight
            }
            let content = CGRect(x: contentMinX, y: y, width: max(0, column.maxX - contentMinX), height: height)
            return SeparatorFrames(pill: nil, buttons: buttonFrames, content: content, textX: content.minX + style.ch)
        case .metadata:
            let content = CGRect(x: gutterRight, y: y, width: max(0, column.maxX - gutterRight), height: height)
            return SeparatorFrames(pill: nil, buttons: [], content: content, textX: gutterRight + style.ch)
        case .simple:
            return SeparatorFrames(pill: nil, buttons: [], content: nil, textX: 0)
        }
    }

    private func splitButtons(_ buttons: [ExpansionDirection], in rect: CGRect) -> [(ExpansionDirection, CGRect)] {
        if buttons.count <= 1 {
            return buttons.map { ($0, rect) }
        }
        // `grid-template-rows: 50% 50%` with a 1px divider between.
        let half = rect.height / 2
        return [
            (buttons[0], CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: half - 1)),
            (buttons[1], CGRect(x: rect.minX, y: rect.minY + half + 1, width: rect.width, height: half - 1)),
        ]
    }

    private func drawSeparatorRow(_ separator: SeparatorCell, row: Int, top: CGFloat, height: CGFloat, context: CGContext) {
        let palette = style.palette
        let separatorColor = style.cgColor(palette.bgSeparator)
        switch separator.type {
        case .simple:
            context.setFillColor(separatorColor)
            for column in columns {
                context.fill(CGRect(x: column.minX, y: top, width: column.width, height: min(height, GridMetrics.simpleSeparatorHeight)))
            }
        case .metadata:
            context.setFillColor(separatorColor)
            for column in columns {
                context.fill(CGRect(x: column.minX, y: top, width: column.width, height: height))
            }
            if let first = columns.first {
                let frames = separatorFrames(separator, row: row, column: first)
                let label = (separator.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                drawSeparatorLabel(label, x: frames.textX, top: frames.content?.minY ?? top, height: GridMetrics.separatorHeight, clip: nil, context: context)
            }
        case .lineInfoBasic:
            context.setFillColor(separatorColor)
            for column in columns {
                context.fill(CGRect(x: column.minX, y: top, width: column.width, height: height))
            }
            if let first = columns.first {
                let frames = separatorFrames(separator, row: row, column: first)
                drawButtonBorders(frames.buttons, context: context)
                drawButtons(frames.buttons, separator: separator, context: context)
                drawSeparatorLabel(separator.label, x: frames.textX, top: top, height: height, clip: frames.content, context: context)
            }
        case .lineInfo, .custom:
            guard let first = columns.first else { return }
            let frames = separatorFrames(separator, row: row, column: first)
            let radius = GridMetrics.separatorRadius
            context.setFillColor(separatorColor)
            if let pill = frames.pill, !model.isSplit {
                context.addPath(CGPath(roundedRect: pill, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            } else if let pill = frames.pill {
                // Left half: rounded on the left; right half: rounded on the
                // right edge only.
                fillRoundedRect(pill, radius: radius, left: true, right: false, context: context)
                if columns.count > 1 {
                    let second = columns[1]
                    let rect = CGRect(x: second.minX, y: pill.minY, width: max(0, second.maxX - GridMetrics.gap - second.minX), height: pill.height)
                    fillRoundedRect(rect, radius: radius, left: false, right: true, context: context)
                }
            }
            drawButtonBorders(frames.buttons, context: context)
            drawButtons(frames.buttons, separator: separator, context: context)
            drawSeparatorLabel(separator.label, x: frames.textX, top: frames.content?.minY ?? top, height: GridMetrics.separatorHeight, clip: frames.content, context: context)
        }
    }

    /// Expand buttons' `border-right: 2px` and, for stacked buttons, the
    /// 1px `border-bottom`/`border-top` in the page color.
    private func drawButtonBorders(_ buttons: [(ExpansionDirection, CGRect)], context: CGContext) {
        guard let first = buttons.first?.1 else { return }
        context.setFillColor(style.cgColor(style.palette.bg))
        let height = buttons.count > 1 ? buttons[1].1.maxY - first.minY : first.height
        context.fill(CGRect(x: first.maxX, y: first.minY, width: GridMetrics.gutterBorder, height: height))
        if buttons.count > 1 {
            context.fill(CGRect(x: first.minX, y: first.maxY, width: first.width, height: buttons[1].1.minY - first.maxY))
        }
    }

    private func fillRoundedRect(_ rect: CGRect, radius: CGFloat, left: Bool, right: Bool, context: CGContext) {
        let path = CGMutablePath()
        let r = min(radius, rect.height / 2, rect.width / 2)
        path.move(to: CGPoint(x: rect.minX + (left ? r : 0), y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - (right ? r : 0), y: rect.minY))
        if right {
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.minX + (left ? r : 0), y: rect.maxY))
        if left {
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.closeSubpath()
        context.addPath(path)
        context.fillPath()
    }

    private func drawButtons(_ buttons: [(ExpansionDirection, CGRect)], separator: SeparatorCell, context: CGContext) {
        let palette = style.palette
        for (direction, rect) in buttons {
            let hovered = hoveredExpand == .expand(hunkIndex: separator.hunkIndex, direction: direction, all: false)
            let color = style.cgColor(hovered ? palette.fg : palette.fgNumber)
            let icon: DiffsIcon = direction == .both ? .expandAll : .expand
            let iconRect = CGRect(x: rect.midX - 8, y: rect.midY - 8, width: 16, height: 16)
            if direction == .down {
                // `[data-expand-down] [data-icon] { transform: scaleY(-1) }`
                context.saveGState()
                context.translateBy(x: 0, y: iconRect.midY)
                context.scaleBy(x: 1, y: -1)
                context.translateBy(x: 0, y: -iconRect.midY)
                icon.draw(in: context, rect: iconRect, color: color)
                context.restoreGState()
            } else {
                icon.draw(in: context, rect: iconRect, color: color)
            }
        }
    }

    private func drawSeparatorLabel(_ label: String, x: CGFloat, top: CGFloat, height: CGFloat, clip: CGRect?, context: CGContext) {
        let palette = style.palette
        let text = makeTextLine(label, font: style.headerFont, color: style.cgColor(palette.fgNumber))
        let font = style.headerFont
        let baseline = top + ((height - (font.ascender - font.descender)) / 2 + font.ascender).rounded()
        context.saveGState()
        if let clip { context.clip(to: clip) }
        drawTextLine(text, in: context, x: x, baseline: baseline)
        context.restoreGState()
    }

    // MARK: Injected rows (merge conflicts)

    private func drawInjected(_ injected: InjectedCell, row: Int, columnIndex: Int, column: ColumnGeometry, top: CGFloat, height: CGFloat, context: CGContext) {
        let palette = style.palette
        let gutter = column.gutterRect
        let gutterRect = CGRect(x: gutter.minX, y: top, width: gutter.width, height: height)
        let contentRect = CGRect(x: column.contentMinX, y: top, width: column.contentWidth, height: height)
        switch injected.kind {
        case .mergeConflictMarker(let type, let text):
            let state = LineVisualState(backgroundEnabled: !options.disableBackground, hasMergeConflict: true)
            fill(contentRect, palette.background(for: .mergeConflictMarker(type), state: state), context)
            fill(gutterRect, palette.background(for: .gutterBuffer(.mergeConflictMarker(type)), state: state), context)
            let line = makeTextLine(text, font: style.typography.codeFont, color: style.cgColor(palette.fg))
            context.saveGState()
            context.clip(to: contentRect)
            let x = column.contentMinX + style.ch - scrollX
            drawTextLine(line, in: context, x: x, baseline: top + style.baseline)
            let suffix: String? = type == .markerStart ? "(Current Change)" : type == .markerEnd ? "(Incoming Change)" : nil
            if let suffix {
                let small = NSFont(descriptor: style.headerFont.fontDescriptor, size: 12) ?? style.headerFont
                let suffixLine = makeTextLine(suffix, font: small, color: style.cgColor(palette.fgConflictMarker))
                drawTextLine(suffixLine, in: context, x: x + textLineWidth(line) + style.ch, baseline: top + style.baseline)
            }
            context.restoreGState()
        case .mergeConflictActions:
            let state = LineVisualState(backgroundEnabled: !options.disableBackground, hasMergeConflict: true)
            fill(contentRect, palette.background(for: .mergeConflictActions, state: state), context)
            fill(gutterRect, palette.background(for: .gutterBuffer(.mergeConflictAction), state: state), context)
            if model.mergeConflictActionsType == .default {
                drawMergeActions(injected, row: row, contentRect: contentRect, context: context)
            }
        }
    }

    /// Frames of the merge conflict action buttons for a row.
    func mergeActionFrames(contentRect: CGRect) -> [(MergeConflictResolution, CGRect, String)] {
        let font = NSFont(descriptor: style.headerFont.fontDescriptor, size: 12) ?? style.headerFont
        var x = contentRect.minX + 8
        var frames: [(MergeConflictResolution, CGRect, String)] = []
        let items: [(MergeConflictResolution, String)] = [(.current, "Accept current change"), (.incoming, "Accept incoming change"), (.both, "Accept both")]
        for (index, item) in items.enumerated() {
            let width = textLineWidth(makeTextLine(item.1, font: font, color: .black))
            frames.append((item.0, CGRect(x: x, y: contentRect.minY, width: width, height: contentRect.height), item.1))
            x += width
            if index < items.count - 1 {
                x += 4 + textLineWidth(makeTextLine("|", font: font, color: .black)) + 4
            }
        }
        return frames
    }

    private func drawMergeActions(_ injected: InjectedCell, row: Int, contentRect: CGRect, context: CGContext) {
        let palette = style.palette
        let font = NSFont(descriptor: style.headerFont.fontDescriptor, size: 12) ?? style.headerFont
        let baseline = contentRect.minY + ((contentRect.height - (font.ascender - font.descender)) / 2 + font.ascender).rounded()
        let frames = mergeActionFrames(contentRect: contentRect)
        for (index, frame) in frames.enumerated() {
            var color = palette.fgNumber
            if case .mergeAction(let hoveredRow, _, let resolution)? = hoveredMergeAction, hoveredRow == row, resolution == frame.0 {
                switch resolution {
                case .current: color = palette.additionBase
                case .incoming: color = palette.modifiedBase
                case .both: color = palette.fg
                }
            }
            let line = makeTextLine(frame.2, font: font, color: style.cgColor(color))
            drawTextLine(line, in: context, x: frame.1.minX, baseline: baseline)
            if index < frames.count - 1 {
                let separator = makeTextLine("|", font: font, color: style.cgColor(palette.fgNumber.withAlpha(palette.fgNumber.a * 0.6)))
                drawTextLine(separator, in: context, x: frame.1.maxX + 4, baseline: baseline)
            }
        }
    }

    // MARK: - Gutter utility

    private var utilityTarget: (row: Int, column: Int)? {
        guard options.enableGutterUtility else { return nil }
        if let range = currentSelectionRange, let endpoints = selectionEnds(range) {
            return rowAndColumn(for: endpoints.bottom)
        }
        if let hoveredRow, let hoveredColumn, case .line? = cell(row: hoveredRow, column: hoveredColumn) {
            return (hoveredRow, hoveredColumn)
        }
        return nil
    }

    func utilityButtonRect() -> (row: Int, column: Int, rect: CGRect)? {
        guard let target = utilityTarget, target.row < rowTops.count, target.column < columns.count else { return nil }
        let column = columns[target.column]
        let lineHeight = style.lineHeight
        let numberRight = column.minX + column.gutterWidth - GridMetrics.gutterBorder
        // `margin-right: calc((1lh - 1ch) * -1)` from the number cell's right
        // edge.
        let maxX = numberRight + (lineHeight - style.ch)
        return (target.row, target.column, CGRect(x: maxX - lineHeight, y: rowTops[target.row], width: lineHeight, height: lineHeight))
    }

    private func drawUtilityButton(_ rect: CGRect, context: CGContext) {
        let palette = style.palette
        context.setFillColor(style.cgColor(palette.modifiedBase))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.fillPath()
        DiffsIcon.plus.draw(in: context, rect: CGRect(x: rect.midX - 8, y: rect.midY - 8, width: 16, height: 16), color: style.cgColor(palette.bg))
    }

    // MARK: - Selection

    private var currentSelectionRange: SelectedLineRange? {
        if let proposedRange { return proposedRange }
        return lineSelectionRange
    }

    private func cell(row: Int, column: Int) -> RenderCell? {
        guard row < model.rows.count, column < columns.count else { return nil }
        let cells = model.rows[row].cells
        let index = columns[column].cellIndex
        return index < cells.count ? cells[index] : nil
    }

    private func rowLineIndex(_ line: RenderedLine) -> Int {
        model.kind == .file ? line.lineIndex : (model.isSplit ? line.splitLineIndex : line.unifiedLineIndex)
    }

    private func rowIndexes(for point: SelectionPoint) -> Int? {
        if model.kind == .file { return point.lineNumber - 1 }
        guard let indexes = lineIndexResolver?(point.lineNumber, point.side) else { return nil }
        return model.isSplit ? indexes.split : indexes.unified
    }

    private func selectionEnds(_ range: SelectedLineRange) -> (top: SelectionPoint, bottom: SelectionPoint)? {
        let start = SelectionPoint(lineNumber: range.start, side: range.side)
        let end = SelectionPoint(lineNumber: range.end, side: range.endSide ?? range.side)
        guard let startIndex = rowIndexes(for: start), let endIndex = rowIndexes(for: end) else { return nil }
        return startIndex > endIndex ? (end, start) : (start, end)
    }

    private func rowAndColumn(for point: SelectionPoint) -> (row: Int, column: Int)? {
        guard let target = rowIndexes(for: point) else { return nil }
        for (rowIndex, row) in model.rows.enumerated() {
            for (columnIndex, column) in columns.enumerated() {
                guard column.cellIndex < row.cells.count, case .line(let line)? = row.cells[column.cellIndex] else { continue }
                if rowLineIndex(line) == target, line.lineNumber == point.lineNumber,
                   model.kind == .file || point.side == nil || line.side == point.side || !model.isSplit
                {
                    return (rowIndex, columnIndex)
                }
            }
        }
        return nil
    }

    private func isRowSelected(row: Int, column: Int) -> Bool {
        guard let range = currentSelectionRange,
              let startIndex = rowIndexes(for: SelectionPoint(lineNumber: range.start, side: range.side)),
              let endIndex = rowIndexes(for: SelectionPoint(lineNumber: range.end, side: range.endSide ?? range.side))
        else { return false }
        let first = min(startIndex, endIndex)
        let last = max(startIndex, endIndex)
        switch cell(row: row, column: column) {
        case .line(let line)?:
            let index = rowLineIndex(line)
            return index >= first && index <= last
        case .annotation?:
            // Annotation rows directly after a selected line are selected.
            guard row > 0, case .line(let line)? = cell(row: row - 1, column: column) else { return false }
            let index = rowLineIndex(line)
            return index >= first && index <= last
        default:
            return false
        }
    }

    // MARK: - Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    private func clearHover() {
        if let token = hoveredToken {
            delegate?.grid(self, tokenEvent: token, kind: .leave)
            hoveredToken = nil
        }
        if let line = hoveredLineEvent {
            delegate?.grid(self, lineEvent: line, kind: .leave)
            hoveredLineEvent = nil
        }
        if hoveredRow != nil || hoveredExpand != nil || hoveredMergeAction != nil {
            hoveredRow = nil
            hoveredColumn = nil
            hoveredExpand = nil
            hoveredMergeAction = nil
            needsDisplay = true
        }
        NSCursor.arrow.set()
    }

    private func lineEvent(for line: RenderedLine, numberColumn: Bool) -> DiffsLineEvent {
        DiffsLineEvent(
            lineNumber: line.lineNumber,
            side: model.kind == .file ? nil : line.side,
            lineType: line.lineType,
            numberColumn: numberColumn
        )
    }

    private func updateHover(at point: CGPoint) {
        let hit = hitTest(point: point)
        var newRow: Int?
        var newColumn: Int?
        var numberColumn = false
        var newExpand: GridHit?
        var newMergeAction: GridHit?
        switch hit {
        case .line(let row, let column, _, let isNumber):
            newRow = row
            newColumn = column
            numberColumn = isNumber
        case .utility(let row, let column):
            newRow = row
            newColumn = column
            numberColumn = true
        case .expand:
            newExpand = hit
        case .mergeAction:
            newMergeAction = hit
        default:
            break
        }
        // Token transitions
        let token = tokenEvent(at: point, hit: hit)
        if token != hoveredToken {
            if let previous = hoveredToken { delegate?.grid(self, tokenEvent: previous, kind: .leave) }
            hoveredToken = token
            if let token { delegate?.grid(self, tokenEvent: token, kind: .enter) }
        }
        // Line transitions
        let sameLine = newRow == hoveredRow && newColumn == hoveredColumn
        if !sameLine {
            if let previous = hoveredLineEvent {
                delegate?.grid(self, lineEvent: previous, kind: .leave)
                hoveredLineEvent = nil
            }
            if let newRow, let newColumn, case .line(let line)? = cell(row: newRow, column: newColumn) {
                let event = lineEvent(for: line, numberColumn: numberColumn)
                hoveredLineEvent = event
                delegate?.grid(self, lineEvent: event, kind: .enter)
            }
        }
        if !sameLine || numberColumn != hoveredNumberColumn || newExpand != hoveredExpand || newMergeAction != hoveredMergeAction {
            hoveredRow = newRow
            hoveredColumn = newColumn
            hoveredNumberColumn = numberColumn
            hoveredExpand = newExpand
            hoveredMergeAction = newMergeAction
            needsDisplay = true
        }
        updateCursor(hit: hit)
    }

    private func updateCursor(hit: GridHit) {
        switch hit {
        case .expand, .utility, .mergeAction:
            NSCursor.pointingHand.set()
        case .line(_, _, _, let numberColumn):
            let interactiveNumbers = options.enableLineSelection || (delegate?.gridHandlesLineNumberClicks ?? false)
            let interactiveLines = delegate?.gridHandlesLineClicks ?? false
            if (numberColumn && interactiveNumbers) || (!numberColumn && interactiveLines) {
                NSCursor.pointingHand.set()
            } else if !numberColumn || isEditing {
                NSCursor.iBeam.set()
            } else {
                NSCursor.arrow.set()
            }
        default:
            NSCursor.arrow.set()
        }
    }

    private func tokenEvent(at point: CGPoint, hit: GridHit) -> DiffsTokenEvent? {
        guard delegate?.gridHandlesTokenEvents == true, case .line(let row, let columnIndex, let line, let numberColumn) = hit, !numberColumn else { return nil }
        let column = columns[columnIndex]
        let layout = layout(for: line, column: column)
        let x = point.x - (column.contentMinX + contentPaddingStart - (options.overflow == .scroll ? scrollX : 0))
        let visualLine = Int((point.y - rowTops[row]) / style.lineHeight)
        let index = layout.index(at: x, visualLine: visualLine)
        guard let token = layout.tokens.first(where: { index >= $0.start && index < $0.end }) else { return nil }
        let units = Array(layout.text.utf16)
        let text = String(decoding: units[token.start ..< min(token.end, units.count)], as: UTF16.self)
        if !options.enableTokenInteractionsOnWhitespace, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        return DiffsTokenEvent(
            lineNumber: line.lineNumber,
            side: model.kind == .file ? nil : line.side,
            lineCharStart: token.start,
            lineCharEnd: token.end,
            tokenText: text
        )
    }

    private func selectionPoint(for hit: GridHit) -> (point: SelectionPoint, rowIndex: Int)? {
        guard case .line(_, _, let line, _) = hit else { return nil }
        let point = SelectionPoint(lineNumber: line.lineNumber, side: model.kind == .file ? nil : line.side)
        return (point, rowLineIndex(line))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = hitTest(point: point)
        switch hit {
        case .utility:
            if delegate?.gridHandlesGutterUtilityClicks == true, let bottom = utilityBottomPoint() {
                let ends = currentSelectionRange.flatMap(selectionEnds)
                let anchor = ends?.top ?? bottom
                pointerSession = .gutterSelecting(anchor: anchor, current: bottom)
                selectionAnchor = anchor
                updateSelection(to: bottom, emitChange: false)
                delegate?.grid(self, selectionEvent: currentSelectionRange, phase: .start)
            }
            return
        case .line(_, _, _, let numberColumn) where numberColumn && options.enableLineSelection:
            guard let (point, rowIndex) = selectionPoint(for: hit) else { return }
            if event.modifierFlags.contains(.shift), let range = lineSelectionRange,
               let startIndex = rowIndexes(for: SelectionPoint(lineNumber: range.start, side: range.side)),
               let endIndex = rowIndexes(for: SelectionPoint(lineNumber: range.end, side: range.endSide ?? range.side))
            {
                let useStart = startIndex <= endIndex ? rowIndex >= startIndex : rowIndex <= endIndex
                selectionAnchor = useStart
                    ? SelectionPoint(lineNumber: range.start, side: range.side)
                    : SelectionPoint(lineNumber: range.end, side: range.endSide ?? range.side)
                updateSelection(to: point, emitChange: false)
                delegate?.grid(self, selectionEvent: currentSelectionRange, phase: .start)
                pointerSession = .selecting
                return
            }
            if lineSelectionRange?.start == point.lineNumber, lineSelectionRange?.end == point.lineNumber {
                selectionAnchor = point
                pointerSession = .pendingSingleLineUnselect(anchor: point)
                return
            }
            if controlledSelection {
                proposedRange = .some(nil)
            } else {
                lineSelectionRange = nil
            }
            selectionAnchor = point
            updateSelection(to: point, emitChange: false)
            delegate?.grid(self, selectionEvent: currentSelectionRange, phase: .start)
            pointerSession = .selecting
        case .line(_, let columnIndex, _, false):
            if let client = editing.client, let position = editorPosition(at: point) {
                window?.makeFirstResponder(self)
                editing.isDragging = true
                client.editorMouseDown(at: position, clickCount: event.clickCount, modifiers: event.modifierFlags)
                restartCaretBlink()
                return
            }
            beginTextDrag(at: point, column: columnIndex, clickCount: event.clickCount, extend: event.modifierFlags.contains(.shift))
        case .none, .annotation:
            // While editing, clicks on empty space place the caret at the
            // nearest editable position.
            if let client = editing.client, case .none = hit, let position = editorPosition(at: point) {
                window?.makeFirstResponder(self)
                editing.isDragging = true
                client.editorMouseDown(at: position, clickCount: event.clickCount, modifiers: event.modifierFlags)
                restartCaretBlink()
                return
            }
            clearTextSelection()
            super.mouseDown(with: event)
        default:
            clearTextSelection()
            super.mouseDown(with: event)
        }
    }

    private func beginTextDrag(at point: CGPoint, column: Int, clickCount: Int, extend: Bool) {
        guard let position = textPosition(at: point, column: column) else { return }
        window?.makeFirstResponder(self)
        let granularity: TextSelectionGranularity = clickCount >= 3 ? .line : clickCount == 2 ? .word : .character
        if extend, let existing = textSelection, existing.column == column {
            textSelection = GridTextSelection(column: column, anchor: existing.anchor, focus: position)
            textDrag = (column, existing.anchor, existing.anchor, .character, true)
            needsDisplay = true
            return
        }
        let (lower, upper) = textRange(around: position, column: column, granularity: granularity)
        textDrag = (column, lower, upper, granularity, granularity != .character)
        textSelection = granularity == .character ? nil : GridTextSelection(column: column, anchor: lower, focus: upper)
        needsDisplay = true
    }

    private func extendTextDrag(to point: CGPoint) {
        guard var drag = textDrag, let position = textPosition(at: point, column: drag.column) else { return }
        drag.moved = true
        textDrag = drag
        let (lower, upper) = textRange(around: position, column: drag.column, granularity: drag.granularity)
        if position < drag.lower {
            textSelection = GridTextSelection(column: drag.column, anchor: drag.upper, focus: lower)
        } else {
            textSelection = GridTextSelection(column: drag.column, anchor: drag.lower, focus: max(upper, drag.upper))
        }
        needsDisplay = true
    }

    private func utilityBottomPoint() -> SelectionPoint? {
        if let range = currentSelectionRange, let ends = selectionEnds(range) { return ends.bottom }
        guard let target = utilityTarget, case .line(let line)? = cell(row: target.row, column: target.column) else { return nil }
        return SelectionPoint(lineNumber: line.lineNumber, side: model.kind == .file ? nil : line.side)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        autoscroll(with: event)
        if editing.isDragging, let client = editing.client {
            if let position = editorPosition(at: point) { client.editorMouseDragged(to: position) }
            return
        }
        if textDrag != nil {
            extendTextDrag(to: point)
            return
        }
        guard let (selection, _) = selectionPointForDrag(at: point) else { return }
        switch pointerSession {
        case .idle:
            return
        case .gutterSelecting(let anchor, _):
            pointerSession = .gutterSelecting(anchor: anchor, current: selection)
            updateSelection(to: selection, emitChange: true)
        case .selecting:
            updateSelection(to: selection, emitChange: true)
        case .pendingSingleLineUnselect(let anchor):
            if selection == anchor { return }
            updateSelection(to: selection, emitChange: false)
            delegate?.grid(self, selectionEvent: currentSelectionRange, phase: .start)
            delegate?.grid(self, selectionEvent: currentSelectionRange, phase: .change)
            pointerSession = .selecting
        }
    }

    /// Row-based hit testing during drags: lateral movement still resolves
    /// to the row under the pointer.
    private func selectionPointForDrag(at point: CGPoint) -> (SelectionPoint, Int)? {
        guard let row = rowIndex(at: point.y) else { return nil }
        let columnIndex = columnIndex(at: point.x) ?? (point.x < 0 ? 0 : columns.count - 1)
        var candidates: [RenderCell?] = [cell(row: row, column: columnIndex)]
        if row > 0 { candidates.append(cell(row: row - 1, column: columnIndex)) }
        for candidate in candidates {
            if case .line(let line)? = candidate {
                return (SelectionPoint(lineNumber: line.lineNumber, side: model.kind == .file ? nil : line.side), rowLineIndex(line))
            }
        }
        return nil
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if editing.isDragging {
            editing.isDragging = false
            editing.client?.editorMouseUp()
            return
        }
        if let drag = textDrag {
            textDrag = nil
            if drag.moved {
                // A drag that selected text is not a click.
                if textSelection?.isEmpty == true { textSelection = nil }
                return
            }
            clearTextSelection()
        }
        switch pointerSession {
        case .idle:
            handleClick(at: point, event: event)
            return
        case .gutterSelecting(let anchor, var current):
            if let (selection, _) = selectionPointForDrag(at: point) {
                current = selection
                updateSelection(to: selection, emitChange: true)
            }
            let range = buildRange(anchor: anchor, current: current)
            delegate?.grid(self, gutterUtilityClicked: range)
            selectionAnchor = nil
            delegate?.grid(self, selectionEvent: range, phase: .end)
            delegate?.grid(self, selectionEvent: range, phase: .committed)
            proposedRange = nil
        case .pendingSingleLineUnselect:
            updateSelection(to: nil, emitChange: false)
            selectionAnchor = nil
            delegate?.grid(self, selectionEvent: currentSelectionRange, phase: .end)
            delegate?.grid(self, selectionEvent: currentSelectionRange, phase: .committed)
            proposedRange = nil
        case .selecting:
            selectionAnchor = nil
            delegate?.grid(self, selectionEvent: currentSelectionRange, phase: .end)
            delegate?.grid(self, selectionEvent: currentSelectionRange, phase: .committed)
            proposedRange = nil
        }
        pointerSession = .idle
        needsDisplay = true
    }

    private func handleClick(at point: CGPoint, event: NSEvent) {
        let hit = hitTest(point: point)
        switch hit {
        case .expand(let hunkIndex, let direction, let all):
            let expandAll = all || event.modifierFlags.contains(.shift)
            delegate?.grid(self, expandHunk: hunkIndex, direction: expandAll ? .both : direction, all: expandAll)
        case .mergeAction(_, let conflictIndex, let resolution):
            delegate?.grid(self, mergeConflictAction: resolution, conflictIndex: conflictIndex)
        case .line(_, _, let line, let numberColumn):
            if let token = tokenEvent(at: point, hit: hit) {
                delegate?.grid(self, tokenEvent: token, kind: .click)
            }
            let event = lineEvent(for: line, numberColumn: numberColumn)
            if numberColumn, delegate?.gridHandlesLineNumberClicks == true {
                delegate?.grid(self, lineEvent: event, kind: .numberClick)
            } else {
                delegate?.grid(self, lineEvent: event, kind: .click)
            }
        default:
            break
        }
    }

    private func buildRange(anchor: SelectionPoint, current: SelectionPoint) -> SelectedLineRange {
        SelectedLineRange(
            start: anchor.lineNumber,
            side: anchor.side,
            end: current.lineNumber,
            endSide: anchor.side != current.side ? current.side : nil
        )
    }

    private func updateSelection(to point: SelectionPoint?, emitChange: Bool) {
        let previous = currentSelectionRange
        var next: SelectedLineRange?
        if let point {
            let anchor = selectionAnchor ?? point
            next = buildRange(anchor: SelectionPoint(lineNumber: anchor.lineNumber, side: anchor.side ?? point.side), current: point)
        }
        if previous == next { return }
        if controlledSelection {
            proposedRange = .some(next)
        } else {
            lineSelectionRange = next
        }
        needsDisplay = true
        if emitChange {
            delegate?.grid(self, selectionEvent: currentSelectionRange, phase: .change)
        }
    }

    // MARK: - Horizontal scrolling

    override func scrollWheel(with event: NSEvent) {
        guard options.overflow == .scroll, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
            super.scrollWheel(with: event)
            return
        }
        if maxScrollX == 0 { measureAllLineWidths() }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * style.lineHeight
        let previous = scrollX
        scrollX = max(0, min(scrollX - delta, maxScrollX))
        if scrollX != previous {
            layoutAnnotationViews()
            needsDisplay = true
        }
    }

    /// Scrolls the code columns horizontally.
    func setScrollX(_ value: CGFloat) {
        if maxScrollX == 0 { measureAllLineWidths() }
        scrollX = max(0, min(value, maxScrollX))
        needsDisplay = true
    }

    // MARK: - Copy

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let client = editing.client {
            editing.isFocused = true
            client.editorFocusChanged(true)
            restartCaretBlink()
            needsDisplay = true
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, let client = editing.client {
            editing.isFocused = false
            stopCaretBlink()
            client.editorFocusChanged(false)
            needsDisplay = true
        }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        guard let client = editing.client else {
            super.keyDown(with: event)
            return
        }
        restartCaretBlink()
        if client.editorMarkedText != nil {
            if inputContext?.handleEvent(event) == true { return }
        }
        if client.editorKeyDown(event) { return }
        interpretKeyEvents([event])
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let client = editing.client, window?.firstResponder === self, client.editorKeyDown(event) {
            restartCaretBlink()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func cut(_ sender: Any?) {
        editing.client?.editorPerform(.cut)
    }

    @objc func paste(_ sender: Any?) {
        editing.client?.editorPerform(.paste)
    }

    @objc func undo(_ sender: Any?) {
        editing.client?.editorPerform(.undo)
    }

    @objc func redo(_ sender: Any?) {
        editing.client?.editorPerform(.redo)
    }

    /// Row frame in view coordinates.
    func rowFrame(_ row: Int) -> CGRect? {
        guard row < rowTops.count else { return nil }
        return CGRect(x: 0, y: rowTops[row], width: bounds.width, height: rowHeights[row])
    }

    /// Finds the row rendering a line.
    func row(forLineNumber lineNumber: Int, side: AnnotationSide?) -> Int? {
        for (rowIndex, row) in model.rows.enumerated() {
            for cell in row.cells {
                if case .line(let line)? = cell, line.lineNumber == lineNumber, side == nil || model.kind == .file || line.side == side {
                    return rowIndex
                }
            }
        }
        return nil
    }
}
