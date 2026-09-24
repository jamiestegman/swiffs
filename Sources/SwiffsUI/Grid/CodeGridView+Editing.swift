// Editing support for the code grid: maps points to document positions,
// draws editor selections, overlays and carets, and forwards keyboard and
// text input (including IME composition) to an editor client.

import AppKit
import SwiffsCore
import SwiffsEditor

/// A highlighted document range drawn behind the text.
struct GridEditorOverlay: Equatable {
    enum Kind: Equatable {
        case searchMatch
        case activeSearchMatch
        case bracketMatch
        case marker(MarkerSeverity)
        case remoteSelection(CGColor)
        case predictionDeletion
    }

    var range: DocumentRange
    var kind: Kind
}

/// Receives editing input from the grid (implemented by `DiffsEditor`).
@MainActor
protocol GridEditorClient: AnyObject {
    /// Which line side holds the document (`.additions` for files and diffs).
    var editorSide: AnnotationSide { get }
    var editorSelections: [EditorSelection] { get }
    var editorOverlays: [GridEditorOverlay] { get }
    /// Remote carets: position and color.
    var editorRemoteCarets: [(position: Position, color: CGColor)] { get }
    var editorSelectionColor: CGColor? { get }
    var editorCaretColor: CGColor? { get }
    /// Theme colors for search matches (`editor.findMatchHighlightBackground`)
    /// and bracket matches (`editorBracketMatch.background`).
    var editorSearchMatchColor: CGColor? { get }
    /// Inline ghost text (edit prediction) drawn after a position.
    var editorGhostText: [(position: Position, text: String)] { get }
    var editorBracketMatchColor: CGColor? { get }
    var editorMarkedText: (text: String, range: DocumentRange)? { get }

    func editorKeyDown(_ event: NSEvent) -> Bool
    func editorInsertText(_ text: String)
    func editorSetMarkedText(_ text: String, selectedRange: NSRange)
    func editorUnmarkText()
    func editorDoCommand(_ selector: Selector) -> Bool
    func editorMouseDown(at position: Position, clickCount: Int, modifiers: NSEvent.ModifierFlags)
    func editorMouseDragged(to position: Position)
    func editorMouseUp()
    func editorFocusChanged(_ focused: Bool)
    /// Pointer hover (for marker popovers); `point` is in grid coordinates.
    func editorMouseMoved(to position: Position?, point: CGPoint)
    func editorModifiersChanged(_ flags: NSEvent.ModifierFlags)
    func editorPerform(_ action: GridEditorAction)
    func editorCanPerform(_ action: GridEditorAction) -> Bool
}

enum GridEditorAction {
    case copy, cut, paste, selectAll, undo, redo
}

/// Editing state stored on the grid.
final class GridEditingState {
    weak var client: GridEditorClient?
    var caretVisible = true
    var caretTimer: Timer?
    var isFocused = false
    var isDragging = false
    /// Document line → (row, column) for the editor side.
    var lineRows: [Int: (row: Int, column: Int)] = [:]
    var lineRowsVersion = -1
}

extension CodeGridView {
    var editorClient: GridEditorClient? {
        get { editing.client }
        set {
            editing.client = newValue
            editing.lineRowsVersion = -1
            if newValue == nil { stopCaretBlink() }
            needsDisplay = true
        }
    }

    var isEditing: Bool { editing.client != nil }

    // MARK: Position mapping

    func rebuildEditorLineRows() {
        guard let client = editing.client else { return }
        var map: [Int: (row: Int, column: Int)] = [:]
        for (rowIndex, row) in model.rows.enumerated() {
            for (columnIndex, column) in columns.enumerated() {
                guard column.cellIndex < row.cells.count, case .line(let line)? = row.cells[column.cellIndex],
                      line.side == client.editorSide, line.lineType != .changeDeletion
                else { continue }
                map[line.lineIndex] = (rowIndex, columnIndex)
            }
        }
        editing.lineRows = map
    }

    /// The row and column rendering a document line.
    func editorLocation(ofLine line: Int) -> (row: Int, column: Int)? {
        editing.lineRows[line]
    }

    /// Rect of a caret at a document position (grid coordinates).
    func editorCaretRect(_ position: Position) -> CGRect? {
        guard let location = editorLocation(ofLine: position.line), let line = textLine(row: location.row, column: location.column) else { return nil }
        let geometry = columns[location.column]
        let layout = layout(for: line, column: geometry)
        let character = min(position.character, layout.utf16Count)
        let (visualLine, x) = layout.position(of: character)
        let lineHeight = style.lineHeight
        let top = rowTops[location.row] + CGFloat(visualLine) * lineHeight
        return CGRect(x: textOriginX(for: geometry) + x, y: top, width: 2, height: lineHeight)
    }

    /// Document position under a point, snapping to the nearest editable line.
    func editorPosition(at point: CGPoint) -> Position? {
        guard let client = editing.client, !rowTops.isEmpty else { return nil }
        let preferredColumn = columns.firstIndex { column in
            model.rows.contains { row in
                guard column.cellIndex < row.cells.count, case .line(let line)? = row.cells[column.cellIndex] else { return false }
                return line.side == client.editorSide && line.lineType != .changeDeletion
            }
        } ?? 0
        var row: Int
        if point.y < rowTops[0] {
            row = 0
        } else if let hit = rowIndex(at: point.y) {
            row = hit
        } else {
            row = rowTops.count - 1
        }
        func editableLine(_ row: Int) -> RenderedLine? {
            guard let line = textLine(row: row, column: preferredColumn), line.side == client.editorSide, line.lineType != .changeDeletion else { return nil }
            return line
        }
        guard editableLine(row) != nil else {
            var below = row
            while below < model.rows.count, editableLine(below) == nil { below += 1 }
            if below < model.rows.count, let line = editableLine(below) {
                return Position(line: line.lineIndex, character: 0)
            }
            var above = row
            while above >= 0, editableLine(above) == nil { above -= 1 }
            guard above >= 0, let line = editableLine(above) else { return nil }
            return Position(line: line.lineIndex, character: layout(for: line, column: columns[preferredColumn]).utf16Count)
        }
        let line = editableLine(row)!
        let geometry = columns[preferredColumn]
        let layout = layout(for: line, column: geometry)
        if point.y < rowTops[0] { return Position(line: line.lineIndex, character: 0) }
        let x = point.x - textOriginX(for: geometry)
        let visualLine = max(0, Int((point.y - rowTops[row]) / style.lineHeight))
        return Position(line: line.lineIndex, character: layout.index(at: x, visualLine: visualLine))
    }

    // MARK: Drawing

    /// Rects covering a document range on one rendered line.
    func editorRangeRects(_ range: DocumentRange, line: RenderedLine, row: Int, column: Int, extendsPastLineEnd: Bool) -> [CGRect] {
        let docLine = line.lineIndex
        guard range.start.line <= docLine, range.end.line >= docLine else { return [] }
        let geometry = columns[column]
        let layout = layout(for: line, column: geometry)
        let lower = range.start.line == docLine ? min(range.start.character, layout.utf16Count) : 0
        let upper = range.end.line == docLine ? min(range.end.character, layout.utf16Count) : layout.utf16Count
        let continues = extendsPastLineEnd && range.end.line > docLine
        let originX = textOriginX(for: geometry)
        let lineHeight = style.lineHeight
        let top = rowTops[row]
        var rects: [CGRect] = []
        if layout.lines.isEmpty {
            if continues { rects.append(CGRect(x: originX, y: top, width: style.ch * 0.6, height: lineHeight)) }
            return rects
        }
        for (index, ctLine) in layout.lines.enumerated() {
            let lineStart = layout.lineStarts[index]
            let lineEnd = index + 1 < layout.lineStarts.count ? layout.lineStarts[index + 1] : layout.utf16Count
            let s = max(lower, lineStart)
            let e = min(upper, lineEnd)
            let isLast = index == layout.lines.count - 1
            if e < s || (e == s && !(continues && isLast)) { continue }
            let x0 = CTLineGetOffsetForStringIndex(ctLine, s, nil)
            var x1 = CTLineGetOffsetForStringIndex(ctLine, e, nil)
            if continues, isLast { x1 += style.ch * 0.6 }
            rects.append(CGRect(x: originX + x0, y: top + CGFloat(index) * lineHeight, width: max(0, x1 - x0), height: lineHeight))
        }
        return rects
    }

    /// Draws editor selections and overlays behind a line's text.
    func drawEditorBackground(line: RenderedLine, row: Int, column: Int, contentRect: CGRect, context: CGContext) {
        guard let client = editing.client, line.side == client.editorSide, line.lineType != .changeDeletion else { return }
        context.saveGState()
        context.clip(to: contentRect)
        for overlay in client.editorOverlays {
            let rects = editorRangeRects(overlay.range, line: line, row: row, column: column, extendsPastLineEnd: false)
            guard !rects.isEmpty else { continue }
            switch overlay.kind {
            case .marker(let severity):
                context.setStrokeColor(markerColor(severity))
                context.setLineWidth(1)
                for rect in rects { drawSquiggle(in: context, rect: rect) }
            case .bracketMatch:
                context.setFillColor(client.editorBracketMatchColor ?? style.cgColor(style.palette.fg.withAlpha(0.12)))
                context.fill(rects)
                context.setStrokeColor(style.cgColor(style.palette.fg.withAlpha(0.35)))
                for rect in rects { context.stroke(rect.insetBy(dx: 0.5, dy: 0.5)) }
            case .searchMatch:
                context.setFillColor(client.editorSearchMatchColor ?? NSColor.findHighlightColor.withAlphaComponent(0.35).cgColor)
                context.fill(rects)
            case .activeSearchMatch:
                context.setFillColor(NSColor.findHighlightColor.cgColor)
                context.fill(rects)
            case .remoteSelection(let color):
                context.setFillColor(color.copy(alpha: 0.25) ?? color)
                context.fill(rects)
            case .predictionDeletion:
                context.setFillColor(style.cgColor(style.palette.deletionBase.withAlpha(0.25)))
                context.fill(rects)
            }
        }
        let selectionColor = client.editorSelectionColor ?? (editing.isFocused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).cgColor
        context.setFillColor(selectionColor)
        for selection in client.editorSelections where !selection.isCollapsed {
            let rects = editorRangeRects(selection.range, line: line, row: row, column: column, extendsPastLineEnd: true)
            for rect in rects {
                let path = CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
                context.addPath(path)
                context.fillPath()
            }
        }
        context.restoreGState()
    }

    /// Draws carets and IME marked text underline over a line.
    func drawEditorForeground(line: RenderedLine, row: Int, column: Int, contentRect: CGRect, context: CGContext) {
        guard let client = editing.client, line.side == client.editorSide, line.lineType != .changeDeletion else { return }
        context.saveGState()
        context.clip(to: contentRect)
        if let marked = client.editorMarkedText {
            context.setFillColor(style.cgColor(style.palette.fg))
            for rect in editorRangeRects(marked.range, line: line, row: row, column: column, extendsPastLineEnd: false) {
                context.fill(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 1))
            }
        }
        for ghost in client.editorGhostText where ghost.position.line == line.lineIndex {
            guard let rect = editorCaretRect(ghost.position) else { continue }
            let color = style.cgColor(style.palette.fg.withAlpha(style.palette.fg.a * 0.45))
            let textLine = makeTextLine(ghost.text, font: style.regularFont, color: color)
            drawTextLine(textLine, in: context, x: rect.minX, baseline: rect.minY + style.baseline)
        }
        for caret in client.editorRemoteCarets where caret.position.line == line.lineIndex {
            if let rect = editorCaretRect(caret.position) {
                context.setFillColor(caret.color)
                context.fill(rect)
            }
        }
        if editing.isFocused, editing.caretVisible {
            context.setFillColor(client.editorCaretColor ?? style.cgColor(style.palette.fg))
            for selection in client.editorSelections {
                let focus = selection.focus
                guard focus.line == line.lineIndex, let rect = editorCaretRect(focus) else { continue }
                context.fill(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height))
            }
        }
        context.restoreGState()
    }

    private func markerColor(_ severity: MarkerSeverity) -> CGColor {
        switch severity {
        case .error: return NSColor.systemRed.cgColor
        case .warning: return NSColor.systemYellow.cgColor
        case .info: return NSColor.systemBlue.cgColor
        case .hint: return NSColor.systemGray.cgColor
        }
    }

    private func drawSquiggle(in context: CGContext, rect: CGRect) {
        let y = rect.maxY - 2
        let path = CGMutablePath()
        var x = rect.minX
        path.move(to: CGPoint(x: x, y: y))
        var up = true
        while x < rect.maxX {
            x += 2
            path.addLine(to: CGPoint(x: min(x, rect.maxX), y: up ? y - 1.5 : y))
            up.toggle()
        }
        context.addPath(path)
        context.strokePath()
    }

    // MARK: Caret blink

    func restartCaretBlink() {
        editing.caretVisible = true
        editing.caretTimer?.invalidate()
        guard editing.isFocused else { return }
        let timer = Timer(timeInterval: 0.53, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.editing.caretVisible.toggle()
                self.invalidateCarets()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        editing.caretTimer = timer
        invalidateCarets()
    }

    func stopCaretBlink() {
        editing.caretTimer?.invalidate()
        editing.caretTimer = nil
    }

    func invalidateCarets() {
        guard let client = editing.client else { return }
        for selection in client.editorSelections {
            if let rect = editorCaretRect(selection.focus) {
                setNeedsDisplay(rect.insetBy(dx: -2, dy: 0))
            }
        }
    }

    /// Scrolls so the primary caret is visible (horizontally within the
    /// grid, vertically via the enclosing scroll view).
    func scrollEditorCaretToVisible() {
        guard let client = editing.client, let primary = client.editorSelections.last,
              let rect = editorCaretRect(primary.focus), let location = editorLocation(ofLine: primary.focus.line)
        else { return }
        if options.overflow == .scroll {
            let geometry = columns[location.column]
            let visibleMin = geometry.contentMinX + contentPaddingStart
            let visibleMax = geometry.contentMinX + geometry.contentWidth - contentPaddingEnd
            if rect.minX < visibleMin {
                setScrollX(scrollX - (visibleMin - rect.minX) - style.ch * 4)
            } else if rect.maxX > visibleMax {
                setScrollX(scrollX + (rect.maxX - visibleMax) + style.ch * 4)
            }
        }
        scrollToVisible(rect.insetBy(dx: 0, dy: -style.lineHeight))
    }
}

// MARK: - Text input

extension CodeGridView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        editing.client?.editorInsertText(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        editing.client?.editorSetMarkedText(text, selectedRange: selectedRange)
    }

    func unmarkText() {
        editing.client?.editorUnmarkText()
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        guard let marked = editing.client?.editorMarkedText else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: marked.text.utf16.count)
    }

    func hasMarkedText() -> Bool {
        editing.client?.editorMarkedText != nil
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let primary = editing.client?.editorSelections.last, let rect = editorCaretRect(primary.focus), let window else { return .zero }
        let windowRect = convert(rect, to: nil)
        return window.convertToScreen(windowRect)
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    override func doCommand(by selector: Selector) {
        if editing.client?.editorDoCommand(selector) != true {
            super.doCommand(by: selector)
        }
    }
}
