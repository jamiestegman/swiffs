import AppKit
import SwiffsCore

extension DocumentView {
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = hit(at: point)
        switch hit {
        case .control(let index, .gutterAction):
            let item = layout.items[index]
            guard let target = gutterActionTarget(in: item), case .line(let line)? = cell(row: target.row, column: target.column, in: item) else { return }
            let bottom = selectionPoint(for: line, in: item)
            var anchor = bottom
            if let selection = lineSelection, selection.itemID == item.id, let ends = selectionEnds(selection.range, in: item) {
                anchor = ends.top
            }
            session = .gutterAction(itemID: item.id, anchor: anchor, current: bottom)
            select(from: anchor, to: bottom, in: item.id)
        case .control(_, let control):
            session = .pressingControl(control)
        case .line(let index, _, _, let line, true) where layout.configuration.allowsLineSelection:
            let item = layout.items[index]
            let point = selectionPoint(for: line, in: item)
            window?.makeFirstResponder(self)
            textSelection = nil
            if event.modifierFlags.contains(.shift), let selection = lineSelection, selection.itemID == item.id, let ends = selectionEnds(selection.range, in: item),
               let pointIndex = lineIndex(of: point, in: item), let topIndex = lineIndex(of: ends.top, in: item)
            {
                // Extend from the end farther from the click.
                let anchor = pointIndex >= topIndex ? ends.top : ends.bottom
                session = .selectingLines(itemID: item.id, anchor: anchor)
                select(from: anchor, to: point, in: item.id)
                return
            }
            if let selection = lineSelection, selection.itemID == item.id, selection.range.start == point.lineNumber, selection.range.end == point.lineNumber,
               selection.range.side == point.side
            {
                session = .pressingSelectedLine(itemID: item.id, anchor: point)
                return
            }
            session = .selectingLines(itemID: item.id, anchor: point)
            select(from: point, to: point, in: item.id)
        case .line(let index, _, let column, _, false):
            beginTextSelection(in: layout.items[index], column: column, at: point, clickCount: event.clickCount, extend: event.modifierFlags.contains(.shift))
        default:
            textSelection = nil
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        autoscroll(with: event)
        switch session {
        case .idle, .pressingControl:
            return
        case .selectingText(let itemID, let column, let lower, let upper, let granularity, _):
            guard let item = layout.item(itemID), let position = textPosition(at: point, column: column, in: item) else { return }
            session = .selectingText(itemID: itemID, column: column, lower: lower, upper: upper, granularity: granularity, moved: true)
            let range = textRange(around: position, column: column, in: item, granularity: granularity)
            if position < lower {
                textSelection = TextSelection(itemID: itemID, column: column, anchor: upper, focus: range.lower)
            } else {
                textSelection = TextSelection(itemID: itemID, column: column, anchor: lower, focus: max(range.upper, upper))
            }
        case .selectingLines(let itemID, let anchor):
            guard let item = layout.item(itemID), let current = selectionPointForDrag(at: point, in: item) else { return }
            select(from: anchor, to: current, in: itemID)
        case .pressingSelectedLine(let itemID, let anchor):
            guard let item = layout.item(itemID), let current = selectionPointForDrag(at: point, in: item), current != anchor else { return }
            session = .selectingLines(itemID: itemID, anchor: anchor)
            select(from: anchor, to: current, in: itemID)
        case .gutterAction(let itemID, let anchor, _):
            guard let item = layout.item(itemID), let current = selectionPointForDrag(at: point, in: item) else { return }
            session = .gutterAction(itemID: itemID, anchor: anchor, current: current)
            select(from: anchor, to: current, in: itemID)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let session = self.session
        self.session = .idle
        switch session {
        case .idle:
            return
        case .pressingControl(let control):
            guard case .control(let index, control) = hit(at: point) else { return }
            perform(control, in: layout.items[index], all: event.modifierFlags.contains(.shift))
        case .selectingText(_, _, _, _, _, let moved):
            // A click without a drag places no selection.
            if !moved || textSelection?.isEmpty == true { textSelection = nil }
        case .selectingLines:
            return
        case .pressingSelectedLine(let itemID, _):
            if lineSelection?.itemID == itemID { setLineSelection(nil) }
        case .gutterAction(let itemID, let anchor, let current):
            delegate?.documentView(self, didRequestGutterAction: DiffLineSelection(itemID: itemID, range: Self.range(from: anchor, to: current)))
        }
    }

    private func perform(_ control: Control, in item: ItemModel, all: Bool) {
        switch control {
        case .expand(_, let hunk, let direction):
            delegate?.documentView(self, expand: item, hunk: hunk, direction: all ? .both : direction, all: all)
        case .conflictAction(_, _, let conflict, let resolution):
            delegate?.documentView(self, resolve: item, conflict: conflict, resolution: resolution)
        case .gutterAction:
            break
        }
    }

    static func range(from anchor: SelectionPoint, to current: SelectionPoint) -> SelectedLineRange {
        SelectedLineRange(start: anchor.lineNumber, side: anchor.side, end: current.lineNumber, endSide: anchor.side != current.side ? current.side : nil)
    }

    private func select(from anchor: SelectionPoint, to current: SelectionPoint, in itemID: String) {
        setLineSelection(DiffLineSelection(itemID: itemID, range: Self.range(from: anchor, to: current)))
    }

    func setLineSelection(_ selection: DiffLineSelection?) {
        guard selection != lineSelection else { return }
        lineSelection = selection
        delegate?.documentView(self, didChangeLineSelection: selection)
    }

    /// The line under a drag, by row: moving sideways keeps the row's line,
    /// and an annotation row resolves to the line above it.
    private func selectionPointForDrag(at point: CGPoint, in item: ItemModel) -> SelectionPoint? {
        guard let geometry = item.geometry, let body = item.body, !body.rows.isEmpty else { return nil }
        var row: Int
        if point.y < item.bodyTop(showsHeaders: layout.configuration.showsHeaders) {
            row = 0
        } else if let hit = item.rowIndex(at: point.y, showsHeaders: layout.configuration.showsHeaders) {
            row = hit
        } else {
            row = body.rows.count - 1
        }
        let column = geometry.columnIndex(at: point.x) ?? (point.x < 0 ? 0 : geometry.columns.count - 1)
        while row >= 0 {
            if case .line(let line)? = cell(row: row, column: column, in: item) { return selectionPoint(for: line, in: item) }
            row -= 1
        }
        return nil
    }

    // MARK: Horizontal scrolling

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard layout.configuration.overflow == .scroll, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
              let index = layout.itemIndex(at: point.y), layout.items[index].hasBody
        else {
            super.scrollWheel(with: event)
            return
        }
        let item = layout.items[index]
        if item.maxScrollX(configuration: layout.configuration) == 0 {
            item.measureAllLines(configuration: layout.configuration, style: layout.style)
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * layout.style.lineHeight
        let scrollX = max(0, min(item.scrollX - delta, item.maxScrollX(configuration: layout.configuration)))
        guard scrollX != item.scrollX else { return }
        item.scrollX = scrollX
        redrawItems([item.id])
    }
}
