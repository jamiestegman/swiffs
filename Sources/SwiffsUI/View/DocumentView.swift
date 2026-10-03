import AppKit
import SwiffsCore

/// What the document view reports to the diff view.
protocol DocumentViewDelegate: AnyObject {
    func documentView(_ view: DocumentView, expand item: ItemModel, hunk: Int, direction: ExpansionDirection, all: Bool)
    func documentView(_ view: DocumentView, resolve item: ItemModel, conflict: Int, resolution: MergeConflictResolution)
    func documentView(_ view: DocumentView, didChangeLineSelection selection: DiffLineSelection?)
    func documentView(_ view: DocumentView, didRequestGutterAction selection: DiffLineSelection)
}

/// The scrolling document: draws the items near the viewport, hosts their
/// annotation and accessory views, and turns pointer input into hovers,
/// selections and actions.
final class DocumentView: NSView {
    let layout: DocumentLayout
    weak var delegate: DocumentViewDelegate?
    /// Width reserved in each item's header for its accessory.
    var accessoryWidths: [String: CGFloat] = [:]
    /// The selected lines.
    var lineSelection: DiffLineSelection? {
        didSet { if lineSelection != oldValue { redrawSelection(oldValue, lineSelection) } }
    }
    private(set) var hover: (itemID: String, row: Int, column: Int, inNumbers: Bool)?
    private(set) var hoveredControl: Control?
    var textSelection: TextSelection? {
        didSet { if textSelection != oldValue { redrawItems([oldValue?.itemID, textSelection?.itemID]) } }
    }
    var session: PointerSession = .idle
    private var trackingArea: NSTrackingArea?

    init(layout: DocumentLayout) {
        self.layout = layout
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var configuration: DiffConfiguration { layout.configuration }
    private var showsHeaders: Bool { configuration.showsHeaders }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let style = layout.style
        let selectionColor = textSelectionColor
        for item in layout.items(in: dirtyRect.minY, dirtyRect.maxY) {
            guard let geometry = item.geometry else { continue }
            let itemRect = CGRect(x: 0, y: item.top, width: bounds.width, height: item.height)
            context.saveGState()
            context.clip(to: itemRect.intersection(dirtyRect))
            context.setFillColor(style.cgColor(style.palette.bg))
            context.fill(itemRect.intersection(dirtyRect))
            if showsHeaders {
                let headerRect = CGRect(x: 0, y: item.top, width: bounds.width, height: Metrics.headerHeight)
                if headerRect.intersects(dirtyRect) {
                    HeaderPainter(content: HeaderContent(item), style: style).draw(in: headerRect, accessoryWidth: accessoryWidths[item.id] ?? 0, context: context)
                }
            }
            if !item.isCollapsed {
                var interaction = interaction(for: item)
                interaction.textSelectionColor = selectionColor
                ItemPainter(item: item, geometry: geometry, style: style, configuration: configuration, interaction: interaction)
                    .drawRows(in: dirtyRect, context: context)
            }
            context.restoreGState()
        }
    }

    func painter(for item: ItemModel) -> ItemPainter? {
        guard let geometry = item.geometry else { return nil }
        return ItemPainter(item: item, geometry: geometry, style: layout.style, configuration: configuration, interaction: interaction(for: item))
    }

    private func interaction(for item: ItemModel) -> ItemInteraction {
        var interaction = ItemInteraction()
        if let hover, hover.itemID == item.id {
            interaction.hoveredRow = hover.row
            interaction.hoveredColumn = hover.column
        }
        interaction.hoveredControl = hoveredControl
        if let selection = lineSelection, selection.itemID == item.id, let bounds = lineIndexBounds(selection.range, in: item) {
            interaction.isSelected = { [weak self] row, column in
                self?.isLine(at: row, column: column, in: item, within: bounds) ?? false
            }
        }
        interaction.gutterAction = gutterActionTarget(in: item)
        if let textSelection, textSelection.itemID == item.id { interaction.textSelection = textSelection }
        return interaction
    }

    private var textSelectionColor: CGColor {
        let isKey = window?.isKeyWindow == true && window?.firstResponder === self
        let color: NSColor = isKey ? .selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor
        var cgColor = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cgColor = color.cgColor }
        return cgColor
    }

    func redrawItems(_ ids: [String?]) {
        for id in Set(ids.compactMap { $0 }) {
            guard let item = layout.item(id) else { continue }
            setNeedsDisplay(CGRect(x: 0, y: item.top, width: bounds.width, height: item.height))
        }
    }

    func redrawRow(_ row: Int, in itemID: String) {
        guard let item = layout.item(itemID), let frame = item.rowFrame(row, showsHeaders: showsHeaders, width: bounds.width) else { return }
        setNeedsDisplay(frame)
    }

    private func redrawSelection(_ old: DiffLineSelection?, _ new: DiffLineSelection?) {
        redrawItems([old?.itemID, new?.itemID])
    }

    // MARK: Lines and selection

    /// The index a line has in its item's rows: split or unified for diffs.
    func rowLineIndex(_ line: RenderedLine, in item: ItemModel) -> Int {
        if item.shape.kind == .file { return line.lineIndex }
        return item.shape.cellCount == 2 ? line.splitLineIndex : line.unifiedLineIndex
    }

    /// The row line index of a selection end.
    func lineIndex(of point: SelectionPoint, in item: ItemModel) -> Int? {
        guard item.shape.kind == .diff, let diff = item.diff else { return point.lineNumber - 1 }
        guard let indexes = getLineIndexForDiff(diff, lineNumber: point.lineNumber, side: point.side ?? .additions) else { return nil }
        return item.shape.cellCount == 2 ? indexes.split : indexes.unified
    }

    func lineIndexBounds(_ range: SelectedLineRange, in item: ItemModel) -> ClosedRange<Int>? {
        guard let start = lineIndex(of: SelectionPoint(lineNumber: range.start, side: range.side), in: item),
              let end = lineIndex(of: SelectionPoint(lineNumber: range.end, side: range.endSide ?? range.side), in: item)
        else { return nil }
        return min(start, end) ... max(start, end)
    }

    func cell(row: Int, column: Int, in item: ItemModel) -> RenderCell? {
        guard let body = item.body, let geometry = item.geometry, row >= 0, row < body.rows.count, column >= 0, column < geometry.columns.count else { return nil }
        let cells = body.rows[row].cells
        let index = geometry.columns[column].cellIndex
        return index < cells.count ? cells[index] : nil
    }

    private func isLine(at row: Int, column: Int, in item: ItemModel, within bounds: ClosedRange<Int>) -> Bool {
        switch cell(row: row, column: column, in: item) {
        case .line(let line)?:
            return bounds.contains(rowLineIndex(line, in: item))
        case .annotation?:
            // An annotation under a selected line is selected with it.
            guard case .line(let line)? = cell(row: row - 1, column: column, in: item) else { return false }
            return bounds.contains(rowLineIndex(line, in: item))
        default:
            return false
        }
    }

    /// The ends of a selection, top first.
    func selectionEnds(_ range: SelectedLineRange, in item: ItemModel) -> (top: SelectionPoint, bottom: SelectionPoint)? {
        let start = SelectionPoint(lineNumber: range.start, side: range.side)
        let end = SelectionPoint(lineNumber: range.end, side: range.endSide ?? range.side)
        guard let startIndex = lineIndex(of: start, in: item), let endIndex = lineIndex(of: end, in: item) else { return nil }
        return startIndex > endIndex ? (end, start) : (start, end)
    }

    /// The row and column showing a selection point.
    func rowAndColumn(of point: SelectionPoint, in item: ItemModel) -> (row: Int, column: Int)? {
        guard let target = lineIndex(of: point, in: item), let body = item.body, let geometry = item.geometry else { return nil }
        for (rowIndex, row) in body.rows.enumerated() {
            for (columnIndex, column) in geometry.columns.enumerated() {
                guard column.cellIndex < row.cells.count, case .line(let line)? = row.cells[column.cellIndex] else { continue }
                if rowLineIndex(line, in: item) == target, line.lineNumber == point.lineNumber,
                   item.shape.kind == .file || point.side == nil || line.side == point.side || !geometry.isSplitLayout
                {
                    return (rowIndex, columnIndex)
                }
            }
        }
        return nil
    }

    /// Where the gutter action button shows in an item: the selection's last
    /// line while it has one, else the hovered line.
    func gutterActionTarget(in item: ItemModel) -> (row: Int, column: Int)? {
        guard configuration.showsGutterAction, item.hasBody else { return nil }
        if let selection = lineSelection, selection.itemID == item.id {
            guard let ends = selectionEnds(selection.range, in: item) else { return nil }
            return rowAndColumn(of: ends.bottom, in: item)
        }
        if let hover, hover.itemID == item.id, case .line? = cell(row: hover.row, column: hover.column, in: item) {
            return (hover.row, hover.column)
        }
        return nil
    }

    func selectionPoint(for line: RenderedLine, in item: ItemModel) -> SelectionPoint {
        SelectionPoint(lineNumber: line.lineNumber, side: item.shape.kind == .file ? nil : line.side)
    }

    // MARK: Hit testing

    func hit(at point: CGPoint) -> Hit {
        guard let index = layout.itemIndex(at: point.y) else { return .none }
        let item = layout.items[index]
        guard let geometry = item.geometry else { return .none }
        if showsHeaders, point.y < item.top + Metrics.headerHeight { return .header(item: index) }
        guard let body = item.body, let row = item.rowIndex(at: point.y, showsHeaders: showsHeaders), let painter = painter(for: item) else { return .none }
        let top = item.bodyTop(showsHeaders: showsHeaders) + body.rowTops[row]
        if let action = gutterActionTarget(in: item), action.row == row,
           painter.gutterActionRect(column: geometry.columns[action.column], top: top).contains(point)
        {
            return .control(item: index, .gutterAction(itemID: item.id))
        }
        for cell in body.rows[row].cells {
            guard case .separator(let separator)? = cell else { continue }
            guard separator.expandable != nil else { return .none }
            let frames = painter.separatorFrames(separator, top: top, height: body.rowHeights[row])
            for (direction, rect) in frames.buttons where rect.contains(point) {
                return .control(item: index, .expand(itemID: item.id, hunk: separator.hunkIndex, direction: direction))
            }
            if let content = frames.content, content.contains(point) {
                return .control(item: index, .expand(itemID: item.id, hunk: separator.hunkIndex, direction: .both))
            }
            return .none
        }
        guard let columnIndex = geometry.columnIndex(at: point.x) else { return .none }
        let column = geometry.columns[columnIndex]
        switch cell(row: row, column: columnIndex, in: item) {
        case .line(let line)?:
            return .line(item: index, row: row, column: columnIndex, line: line, inNumbers: point.x < column.contentMinX)
        case .annotation?:
            return .annotation(item: index, row: row, column: columnIndex)
        case .injected(let injected)?:
            guard case .mergeConflictActions(let conflict) = injected.kind else { return .none }
            let contentRect = CGRect(x: column.contentMinX, y: top, width: column.contentWidth, height: body.rowHeights[row])
            for frame in painter.conflictActionFrames(contentRect: contentRect) where frame.1.contains(point) {
                return .control(item: index, .conflictAction(itemID: item.id, row: row, conflict: conflict, resolution: frame.0))
            }
            return .none
        default:
            return .none
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHover(nil, control: nil)
        NSCursor.arrow.set()
    }

    func updateHover(at point: CGPoint) {
        let hit = hit(at: point)
        switch hit {
        case .line(let index, let row, let column, _, let inNumbers):
            setHover((layout.items[index].id, row, column, inNumbers), control: nil)
        case .control(let index, let control):
            if case .gutterAction = control, let hover, hover.itemID == layout.items[index].id {
                setHover(hover, control: control)
            } else {
                setHover(nil, control: control)
            }
        default:
            setHover(nil, control: nil)
        }
        updateCursor(for: hit)
    }

    private func setHover(_ newHover: (itemID: String, row: Int, column: Int, inNumbers: Bool)?, control: Control?) {
        let old = hover
        let sameLine = old?.itemID == newHover?.itemID && old?.row == newHover?.row && old?.column == newHover?.column
        guard !sameLine || old?.inNumbers != newHover?.inNumbers || control != hoveredControl else { return }
        let oldControl = hoveredControl
        hover = newHover
        hoveredControl = control
        if let old { redrawRow(old.row, in: old.itemID) }
        if let newHover { redrawRow(newHover.row, in: newHover.itemID) }
        if oldControl != control {
            for control in [oldControl, control].compactMap({ $0 }) {
                switch control {
                case .expand(let itemID, _, _), .gutterAction(let itemID): redrawItems([itemID])
                case .conflictAction(let itemID, let row, _, _): redrawRow(row, in: itemID)
                }
            }
        }
        if configuration.showsGutterAction, let selection = lineSelection, let item = layout.item(selection.itemID), let target = gutterActionTarget(in: item) {
            redrawRow(target.row, in: item.id)
        }
    }

    private func updateCursor(for hit: Hit) {
        switch hit {
        case .control:
            NSCursor.pointingHand.set()
        case .line(_, _, _, _, let inNumbers):
            if inNumbers {
                (configuration.allowsLineSelection ? NSCursor.pointingHand : NSCursor.arrow).set()
            } else {
                NSCursor.iBeam.set()
            }
        default:
            NSCursor.arrow.set()
        }
    }
}
