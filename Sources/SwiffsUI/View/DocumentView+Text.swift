import AppKit
import SwiffsCore

/// Text selection stays within one column of one item, as each side of a
/// diff is its own text, and skips numbers, separators and annotations.
extension DocumentView: NSMenuItemValidation {
    func textLine(row: Int, column: Int, in item: ItemModel) -> RenderedLine? {
        guard case .line(let line)? = cell(row: row, column: column, in: item) else { return nil }
        return line
    }

    private func textLength(row: Int, column: Int, in item: ItemModel) -> Int {
        guard let line = textLine(row: row, column: column, in: item) else { return 0 }
        return item.text(side: line.side, lineIndex: line.lineIndex).utf16.count
    }

    func beginTextSelection(in item: ItemModel, column: Int, at point: CGPoint, clickCount: Int, extend: Bool) {
        guard let position = textPosition(at: point, column: column, in: item) else { return }
        window?.makeFirstResponder(self)
        if extend, let existing = textSelection, existing.itemID == item.id, existing.column == column {
            textSelection = TextSelection(itemID: item.id, column: column, anchor: existing.anchor, focus: position)
            session = .selectingText(itemID: item.id, column: column, lower: existing.anchor, upper: existing.anchor, granularity: .character, moved: true)
            return
        }
        let granularity: TextGranularity = clickCount >= 3 ? .line : clickCount == 2 ? .word : .character
        let range = textRange(around: position, column: column, in: item, granularity: granularity)
        session = .selectingText(itemID: item.id, column: column, lower: range.lower, upper: range.upper, granularity: granularity, moved: granularity != .character)
        textSelection = granularity == .character ? nil : TextSelection(itemID: item.id, column: column, anchor: range.lower, focus: range.upper)
    }

    /// The caret position under a point, clamped to the nearest line in the
    /// column.
    func textPosition(at point: CGPoint, column: Int, in item: ItemModel) -> TextPosition? {
        guard let body = item.body, let geometry = item.geometry, column < geometry.columns.count, !body.rows.isEmpty else { return nil }
        let showsHeaders = layout.configuration.showsHeaders
        let bodyTop = item.bodyTop(showsHeaders: showsHeaders)
        let above = point.y < bodyTop + body.rowTops[0]
        let below = point.y >= bodyTop + (body.rowTops.last ?? 0) + (body.rowHeights.last ?? 0)
        var row = above ? 0 : item.rowIndex(at: point.y, showsHeaders: showsHeaders) ?? body.rows.count - 1
        if textLine(row: row, column: column, in: item) == nil {
            var next = row
            while next < body.rows.count, textLine(row: next, column: column, in: item) == nil { next += 1 }
            if next < body.rows.count { return TextPosition(row: next, offset: 0) }
            while row >= 0, textLine(row: row, column: column, in: item) == nil { row -= 1 }
            guard row >= 0 else { return nil }
            return TextPosition(row: row, offset: textLength(row: row, column: column, in: item))
        }
        if above { return TextPosition(row: row, offset: 0) }
        if below { return TextPosition(row: row, offset: textLength(row: row, column: column, in: item)) }
        guard let line = textLine(row: row, column: column, in: item), let painter = painter(for: item) else { return nil }
        let geometryColumn = geometry.columns[column]
        let lineLayout = item.layout(for: line, column: geometryColumn, geometry: geometry, configuration: layout.configuration, style: layout.style)
        let visualLine = Int((point.y - bodyTop - body.rowTops[row]) / layout.style.lineHeight)
        return TextPosition(row: row, offset: lineLayout.index(at: point.x - painter.textOriginX(for: geometryColumn), visualLine: visualLine))
    }

    func textRange(around position: TextPosition, column: Int, in item: ItemModel, granularity: TextGranularity) -> (lower: TextPosition, upper: TextPosition) {
        switch granularity {
        case .character:
            return (position, position)
        case .line:
            return (TextPosition(row: position.row, offset: 0), TextPosition(row: position.row, offset: textLength(row: position.row, column: column, in: item)))
        case .word:
            guard let line = textLine(row: position.row, column: column, in: item) else { return (position, position) }
            let range = wordRange(in: Array(item.text(side: line.side, lineIndex: line.lineIndex).utf16), at: position.offset)
            return (TextPosition(row: position.row, offset: range.lowerBound), TextPosition(row: position.row, offset: range.upperBound))
        }
    }

    /// The selected text, lines joined with newlines.
    var selectedText: String? {
        guard let selection = textSelection, !selection.isEmpty, let item = layout.item(selection.itemID) else { return nil }
        var parts: [String] = []
        for row in selection.start.row ... selection.end.row {
            guard let line = textLine(row: row, column: selection.column, in: item) else { continue }
            let units = Array(item.text(side: line.side, lineIndex: line.lineIndex).utf16)
            let lower = row == selection.start.row ? min(selection.start.offset, units.count) : 0
            let upper = row == selection.end.row ? min(selection.end.offset, units.count) : units.count
            parts.append(String(decoding: units[lower ..< max(lower, upper)], as: UTF16.self))
        }
        return parts.joined(separator: "\n")
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Selects the code of the column holding the selection, or the first
    /// item's first column.
    override func selectAll(_ sender: Any?) {
        let column = textSelection?.column ?? 0
        guard let item = textSelection.flatMap({ layout.item($0.itemID) }) ?? layout.items.first(where: \.hasBody), let body = item.body else { return }
        let rows = body.rows.indices.filter { textLine(row: $0, column: column, in: item) != nil }
        guard let first = rows.first, let last = rows.last else { return }
        textSelection = TextSelection(itemID: item.id, column: column, anchor: TextPosition(row: first, offset: 0), focus: TextPosition(row: last, offset: textLength(row: last, column: column, in: item)))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): textSelection.map { !$0.isEmpty } ?? false
        case #selector(selectAll(_:)): layout.items.contains(where: \.hasBody)
        default: true
        }
    }
}
