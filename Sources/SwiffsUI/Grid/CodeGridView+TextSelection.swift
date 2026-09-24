// Native text selection for the code grid: the equivalent of browser text
// selection over `[data-line]` content. Selection stays within one column
// (each split side is its own `[data-code]` element) and skips line numbers,
// separators and annotations (`user-select: none` or non-line rows).

import AppKit
import SwiffsCore

/// A caret position: a grid row holding a line cell and a UTF-16 offset.
struct GridTextPosition: Comparable, Hashable {
    var row: Int
    var offset: Int

    static func < (lhs: GridTextPosition, rhs: GridTextPosition) -> Bool {
        lhs.row != rhs.row ? lhs.row < rhs.row : lhs.offset < rhs.offset
    }
}

struct GridTextSelection: Equatable {
    var column: Int
    var anchor: GridTextPosition
    var focus: GridTextPosition

    var start: GridTextPosition { min(anchor, focus) }
    var end: GridTextPosition { max(anchor, focus) }
    var isEmpty: Bool { anchor == focus }
}

/// How a text drag extends: by character, word or line.
enum TextSelectionGranularity {
    case character, word, line
}

extension CodeGridView {
    /// The line rendered in a column's cell of a row.
    func textLine(row: Int, column: Int) -> RenderedLine? {
        guard row >= 0, row < model.rows.count, column >= 0, column < columns.count else { return nil }
        let cells = model.rows[row].cells
        let index = columns[column].cellIndex
        guard index < cells.count, case .line(let line)? = cells[index] else { return nil }
        return line
    }

    func textLength(row: Int, column: Int) -> Int {
        guard let line = textLine(row: row, column: column) else { return 0 }
        return layout(for: line, column: columns[column]).utf16Count
    }

    /// Caret position under a point, clamped to the nearest line row in the
    /// column.
    func textPosition(at point: CGPoint, column: Int) -> GridTextPosition? {
        guard column < columns.count, !rowTops.isEmpty else { return nil }
        var row: Int
        if point.y < rowTops[0] {
            row = 0
        } else if let hit = rowIndex(at: point.y) {
            row = hit
        } else {
            row = rowTops.count - 1
        }
        let beyondEnd = point.y >= (rowTops.last ?? 0) + (rowHeights.last ?? 0)
        if textLine(row: row, column: column) == nil {
            // Snap to the next line below (or the previous one at the end).
            var below = row
            while below < model.rows.count, textLine(row: below, column: column) == nil { below += 1 }
            if below < model.rows.count {
                return GridTextPosition(row: below, offset: 0)
            }
            var above = row
            while above >= 0, textLine(row: above, column: column) == nil { above -= 1 }
            guard above >= 0 else { return nil }
            return GridTextPosition(row: above, offset: textLength(row: above, column: column))
        }
        if point.y < rowTops[0] { return GridTextPosition(row: row, offset: 0) }
        if beyondEnd { return GridTextPosition(row: row, offset: textLength(row: row, column: column)) }
        let geometry = columns[column]
        guard let line = textLine(row: row, column: column) else { return nil }
        let layout = layout(for: line, column: geometry)
        let x = point.x - textOriginX(for: geometry)
        let visualLine = Int((point.y - rowTops[row]) / style.lineHeight)
        return GridTextPosition(row: row, offset: layout.index(at: x, visualLine: visualLine))
    }

    func textOriginX(for column: ColumnGeometry) -> CGFloat {
        column.contentMinX + contentPaddingStart - (options.overflow == .scroll ? scrollX : 0)
    }

    /// Expands a position to word or line boundaries.
    func textRange(around position: GridTextPosition, column: Int, granularity: TextSelectionGranularity) -> (GridTextPosition, GridTextPosition) {
        switch granularity {
        case .character:
            return (position, position)
        case .line:
            return (GridTextPosition(row: position.row, offset: 0), GridTextPosition(row: position.row, offset: textLength(row: position.row, column: column)))
        case .word:
            guard let line = textLine(row: position.row, column: column) else { return (position, position) }
            let units = Array(layout(for: line, column: columns[column]).text.utf16)
            let range = wordRange(in: units, at: position.offset)
            return (GridTextPosition(row: position.row, offset: range.lowerBound), GridTextPosition(row: position.row, offset: range.upperBound))
        }
    }

    /// The selected text: line contents joined with newlines.
    func selectedText(_ selection: GridTextSelection) -> String {
        var parts: [String] = []
        let start = selection.start
        let end = selection.end
        var row = start.row
        while row <= end.row {
            if let line = textLine(row: row, column: selection.column) {
                let units = Array(layout(for: line, column: columns[selection.column]).text.utf16)
                let lower = row == start.row ? min(start.offset, units.count) : 0
                let upper = row == end.row ? min(end.offset, units.count) : units.count
                parts.append(String(decoding: units[lower ..< max(lower, upper)], as: UTF16.self))
            }
            row += 1
        }
        return parts.joined(separator: "\n")
    }

    /// Highlight rectangles of the selection within one row.
    func textSelectionRects(row: Int, column: Int, top: CGFloat) -> [CGRect] {
        guard let selection = textSelection, selection.column == column, !selection.isEmpty else { return [] }
        let start = selection.start
        let end = selection.end
        guard row >= start.row, row <= end.row, let line = textLine(row: row, column: column) else { return [] }
        let geometry = columns[column]
        let layout = layout(for: line, column: geometry)
        let lower = row == start.row ? start.offset : 0
        let upper = row == end.row ? end.offset : layout.utf16Count
        let originX = textOriginX(for: geometry)
        let lineHeight = style.lineHeight
        var rects: [CGRect] = []
        for (index, ctLine) in layout.lines.enumerated() {
            let lineStart = layout.lineStarts[index]
            let lineEnd = index + 1 < layout.lineStarts.count ? layout.lineStarts[index + 1] : layout.utf16Count
            let s = max(lower, lineStart)
            let e = min(upper, lineEnd)
            let continues = row < end.row && index == layout.lines.count - 1
            if e < s || (e == s && !continues) { continue }
            let x0 = CTLineGetOffsetForStringIndex(ctLine, s, nil)
            var x1 = CTLineGetOffsetForStringIndex(ctLine, e, nil)
            // The line break of a selected line shows as one space.
            if continues { x1 += style.ch }
            rects.append(CGRect(x: originX + x0, y: top + CGFloat(index) * lineHeight, width: max(0, x1 - x0), height: lineHeight))
        }
        if layout.lines.isEmpty, row < end.row {
            rects.append(CGRect(x: originX, y: top, width: style.ch, height: lineHeight))
        }
        return rects
    }

    @objc func copy(_ sender: Any?) {
        if let client = editing.client {
            client.editorPerform(.copy)
            return
        }
        guard let selection = textSelection, !selection.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText(selection), forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        if let client = editing.client {
            client.editorPerform(.selectAll)
            return
        }
        let column = textSelection?.column ?? 0
        guard column < columns.count else { return }
        var first: Int?
        var last: Int?
        for row in model.rows.indices where textLine(row: row, column: column) != nil {
            if first == nil { first = row }
            last = row
        }
        guard let first, let last else { return }
        textSelection = GridTextSelection(
            column: column,
            anchor: GridTextPosition(row: first, offset: 0),
            focus: GridTextPosition(row: last, offset: textLength(row: last, column: column))
        )
        needsDisplay = true
    }

    /// Clears the text selection.
    func clearTextSelection() {
        guard textSelection != nil else { return }
        textSelection = nil
        needsDisplay = true
    }

    var textSelectionColor: CGColor {
        let isKey = window?.isKeyWindow == true && window?.firstResponder === self
        let color: NSColor = isKey ? .selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor
        var cgColor = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cgColor = color.cgColor
        }
        return cgColor
    }
}

extension CodeGridView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let client = editing.client {
            switch menuItem.action {
            case #selector(copy(_:)): return client.editorCanPerform(.copy)
            case #selector(cut(_:)): return client.editorCanPerform(.cut)
            case #selector(paste(_:)): return client.editorCanPerform(.paste)
            case #selector(selectAll(_:)): return client.editorCanPerform(.selectAll)
            case #selector(undo(_:)): return client.editorCanPerform(.undo)
            case #selector(redo(_:)): return client.editorCanPerform(.redo)
            default: return true
            }
        }
        switch menuItem.action {
        case #selector(copy(_:)):
            return textSelection.map { !$0.isEmpty } ?? false
        case #selector(selectAll(_:)):
            return !model.rows.isEmpty
        default:
            return true
        }
    }
}

/// Word boundaries like a browser double-click: runs of word characters,
/// whitespace or other punctuation.
func wordRange(in units: [UInt16], at offset: Int) -> Range<Int> {
    guard !units.isEmpty else { return 0 ..< 0 }
    let scalars = String(decoding: units, as: UTF16.self)
    // Map UTF-16 offsets to scalar classes.
    var classes: [(start: Int, end: Int, kind: Int)] = []
    var position = 0
    for scalar in scalars.unicodeScalars {
        let length = scalar.utf16.count
        let kind: Int
        if scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_" || scalar.properties.isIdeographic {
            kind = 0
        } else if scalar.properties.isWhitespace {
            kind = 1
        } else {
            kind = 2
        }
        classes.append((position, position + length, kind))
        position += length
    }
    // Prefer the character after the caret, else the one before it.
    var index = classes.firstIndex { offset >= $0.start && offset < $0.end } ?? (classes.count - 1)
    if offset >= position { index = classes.count - 1 }
    let kind = classes[index].kind
    var lower = index
    while lower > 0, classes[lower - 1].kind == kind { lower -= 1 }
    var upper = index
    while upper + 1 < classes.count, classes[upper + 1].kind == kind { upper += 1 }
    return classes[lower].start ..< classes[upper].end
}
