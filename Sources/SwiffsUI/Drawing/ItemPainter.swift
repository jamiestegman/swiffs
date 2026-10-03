import AppKit
import CoreText
import SwiffsCore
import SwiffsHighlight

/// What the pointer and selection mean for drawing one item.
struct ItemInteraction {
    /// The hovered line's row and column.
    var hoveredRow: Int?
    var hoveredColumn: Int?
    var hoveredControl: Control?
    /// Rows (with their column) whose line is selected.
    var isSelected: (_ row: Int, _ column: Int) -> Bool = { _, _ in false }
    /// The row and column showing the gutter action button.
    var gutterAction: (row: Int, column: Int)?
    var textSelection: TextSelection?
    var textSelectionColor: CGColor?

    static let none = ItemInteraction()
}

/// A drawn control the pointer can be over.
enum Control: Equatable {
    case expand(itemID: String, hunk: Int, direction: ExpansionDirection)
    case conflictAction(itemID: String, row: Int, conflict: Int, resolution: MergeConflictResolution)
    case gutterAction(itemID: String)
}

/// Draws one item's header and rows with Core Text and Core Graphics.
struct ItemPainter {
    let item: ItemModel
    let geometry: ItemGeometry
    let style: StyleContext
    let configuration: DiffConfiguration
    let interaction: ItemInteraction

    private var palette: DiffsPalette { style.palette }
    private var columns: [Column] { geometry.columns }
    private var bodyTop: CGFloat { item.bodyTop(showsHeaders: configuration.showsHeaders) }

    // MARK: Rows

    /// Draws the rows intersecting `rect` (document coordinates).
    func drawRows(in rect: CGRect, context: CGContext) {
        guard let body = item.body else {
            if !item.isCollapsed {
                fill(CGRect(x: 0, y: bodyTop, width: rect.maxX, height: max(0, item.bottom - bodyTop)), palette.bg, context)
            }
            return
        }
        if let failure = item.failure {
            let line = makeTextLine(failure, font: style.typography.codeFont, color: style.cgColor(palette.deletionBase))
            drawTextLine(line, in: context, x: style.ch, baseline: bodyTop + body.height - geometry.codePaddingBottom - style.lineHeight + style.baseline)
        }
        var row = item.firstRowIndex(atOrBelow: rect.minY, showsHeaders: configuration.showsHeaders)
        while row < body.rows.count, bodyTop + body.rowTops[row] < rect.maxY {
            drawRow(row, body: body, context: context)
            row += 1
        }
    }

    private func drawRow(_ rowIndex: Int, body: ItemBody, context: CGContext) {
        let row = body.rows[rowIndex]
        let top = bodyTop + body.rowTops[rowIndex]
        let height = body.rowHeights[rowIndex]
        if let separator = row.cells.lazy.compactMap({ cell -> SeparatorCell? in
            if case .separator(let separator)? = cell { return separator }
            return nil
        }).first {
            drawSeparatorRow(separator, top: top, height: height, context: context)
            return
        }
        for (columnIndex, column) in columns.enumerated() {
            guard column.cellIndex < row.cells.count, let cell = row.cells[column.cellIndex] else { continue }
            drawCell(cell, row: rowIndex, columnIndex: columnIndex, column: column, top: top, height: height, context: context)
        }
    }

    private func lineState(lineType: LineType?, row: Int, column: Int, numberCell: Bool) -> LineVisualState {
        let hovered: Bool = {
            guard interaction.hoveredRow == row, interaction.hoveredColumn == column || !geometry.isSplitLayout else { return false }
            switch configuration.lineHoverHighlight {
            case .disabled: return false
            case .both: return true
            case .line: return !numberCell
            case .number: return numberCell
            }
        }()
        return LineVisualState(
            lineType: lineType, backgroundEnabled: configuration.showsBackgrounds, selected: interaction.isSelected(row, column),
            hovered: hovered, hasMergeConflict: item.shape.hasConflicts)
    }

    private func drawCell(_ cell: RenderCell, row: Int, columnIndex: Int, column: Column, top: CGFloat, height: CGFloat, context: CGContext) {
        let gutter = column.gutterRect
        let gutterRect = CGRect(x: gutter.minX, y: top, width: gutter.width, height: height)
        let contentRect = CGRect(x: column.contentMinX, y: top, width: column.contentWidth, height: height)
        switch cell {
        case .line(let line):
            // Conflicted files draw their changes as context tinted by side.
            var visualType = line.lineType
            var tint: MergeConflictLineTint?
            if item.shape.hasConflicts, line.lineType == .changeDeletion || line.lineType == .changeAddition {
                tint = line.lineType == .changeDeletion ? .current : .incoming
                visualType = .context
            }
            var contentState = lineState(lineType: visualType, row: row, column: columnIndex, numberCell: false)
            var numberState = lineState(lineType: visualType, row: row, column: columnIndex, numberCell: true)
            contentState.mergeConflict = tint
            numberState.mergeConflict = tint
            fill(contentRect, palette.background(for: .line, state: contentState), context)
            drawTextSelection(row: row, column: columnIndex, line: line, top: top, contentRect: contentRect, context: context)
            drawLineText(line, column: column, top: top, contentRect: contentRect, context: context)
            fill(gutterRect, palette.background(for: .lineNumber, state: numberState), context)
            drawIndicator(for: visualType, gutterRect: gutterRect, contentRect: contentRect, context: context)
            if configuration.showsLineNumbers {
                drawLineNumber(line.lineNumber, color: palette.lineNumberColor(state: numberState), gutterRect: gutterRect, top: top, context: context)
            }
            if let action = interaction.gutterAction, action.row == row, action.column == columnIndex {
                drawGutterAction(gutterActionRect(column: column, top: top), context: context)
            }
        case .annotation:
            let state = LineVisualState(lineType: nil, backgroundEnabled: configuration.showsBackgrounds, selected: interaction.isSelected(row, columnIndex), hasMergeConflict: item.shape.hasConflicts)
            fill(contentRect, palette.background(for: .annotation, state: state), context)
            fill(gutterRect, palette.background(for: .gutterBuffer(.annotation), state: state), context)
        case .noNewline(let lineType):
            let state = LineVisualState(lineType: lineType, backgroundEnabled: configuration.showsBackgrounds)
            fill(contentRect, palette.background(for: .noNewline, state: state), context)
            fill(gutterRect, palette.background(for: .gutterBuffer(.metadata), state: state), context)
            drawIndicator(for: lineType, gutterRect: nil, contentRect: contentRect, context: context)
            let color = style.cgColor(palette.fg.withAlpha(palette.fg.a * 0.6))
            let text = makeTextLine("No newline at end of file", font: style.typography.codeFont, color: color)
            context.saveGState()
            context.clip(to: contentRect)
            drawTextLine(text, in: context, x: column.contentMinX + geometry.contentPaddingStart - item.scrollX, baseline: top + style.baseline)
            context.restoreGState()
        case .buffer:
            fill(gutterRect, palette.bgContextGutter, context)
            drawHatch(contentRect, column: column, context: context)
        case .separator:
            break
        case .injected(let injected):
            drawInjected(injected, row: row, column: column, gutterRect: gutterRect, contentRect: contentRect, context: context)
        }
    }

    private func fill(_ rect: CGRect, _ color: RGBAColor, _ context: CGContext) {
        context.setFillColor(style.cgColor(color))
        context.fill(rect)
    }

    /// The x where a column's code starts, after horizontal scrolling.
    func textOriginX(for column: Column) -> CGFloat {
        column.contentMinX + geometry.contentPaddingStart - (configuration.overflow == .scroll ? item.scrollX : 0)
    }

    private func drawLineText(_ line: RenderedLine, column: Column, top: CGFloat, contentRect: CGRect, context: CGContext) {
        let layout = item.layout(for: line, column: column, geometry: geometry, configuration: configuration, style: style)
        context.saveGState()
        context.clip(to: contentRect)
        let spanColor = palette.diffSpanBackground(lineType: line.lineType).map(style.cgColor)
        layout.draw(in: context, origin: CGPoint(x: textOriginX(for: column), y: top), style: style, spanColor: item.shape.hasConflicts ? nil : spanColor)
        context.restoreGState()
    }

    private func drawTextSelection(row: Int, column: Int, line: RenderedLine, top: CGFloat, contentRect: CGRect, context: CGContext) {
        guard let selection = interaction.textSelection, let color = interaction.textSelectionColor, selection.column == column, !selection.isEmpty else { return }
        let start = selection.start
        let end = selection.end
        guard row >= start.row, row <= end.row else { return }
        let geometryColumn = columns[column]
        let layout = item.layout(for: line, column: geometryColumn, geometry: geometry, configuration: configuration, style: style)
        let lower = row == start.row ? start.offset : 0
        let upper = row == end.row ? end.offset : layout.utf16Count
        let originX = textOriginX(for: geometryColumn)
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
            // A selected line break shows as one space.
            if continues { x1 += style.ch }
            rects.append(CGRect(x: originX + x0, y: top + CGFloat(index) * lineHeight, width: max(0, x1 - x0), height: lineHeight))
        }
        guard !rects.isEmpty else { return }
        context.saveGState()
        context.clip(to: contentRect)
        context.setFillColor(color)
        context.fill(rects)
        context.restoreGState()
    }

    private func drawLineNumber(_ number: Int, color: RGBAColor, gutterRect: CGRect, top: CGFloat, context: CGContext) {
        let text = makeTextLine(String(number), font: style.typography.codeFont, color: style.cgColor(color))
        drawTextLine(text, in: context, x: gutterRect.maxX - style.ch - textLineWidth(text), baseline: top + style.baseline)
    }

    private func drawIndicator(for lineType: LineType, gutterRect: CGRect?, contentRect: CGRect, context: CGContext) {
        guard item.shape.kind == .diff, lineType == .changeAddition || lineType == .changeDeletion else { return }
        switch configuration.indicators {
        case .bars:
            guard let gutterRect else { return }
            let bar = CGRect(x: gutterRect.minX, y: gutterRect.minY, width: Metrics.barWidth, height: gutterRect.height)
            if lineType == .changeAddition {
                fill(bar, palette.additionBase, context)
            } else {
                // Deletions stripe the bar every other point.
                fill(bar, palette.bgDeletion, context)
                context.setFillColor(style.cgColor(palette.deletionBase))
                var y = bar.minY
                while y < bar.maxY {
                    context.fill(CGRect(x: bar.minX, y: y, width: bar.width, height: min(1, bar.maxY - y)))
                    y += 2
                }
            }
        case .classic:
            let addition = lineType == .changeAddition
            let text = makeTextLine(addition ? "+" : "-", font: style.typography.codeFont, color: style.cgColor(addition ? palette.additionBase : palette.deletionBase))
            context.saveGState()
            context.clip(to: contentRect)
            drawTextLine(text, in: context, x: contentRect.minX - (configuration.overflow == .scroll ? item.scrollX : 0), baseline: contentRect.minY + style.baseline)
            context.restoreGState()
        case .none:
            break
        }
    }

    /// Diagonal stripes filling a split column's empty side.
    private func drawHatch(_ rect: CGRect, column: Column, context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        context.setStrokeColor(style.cgColor(palette.bgBuffer))
        context.setLineWidth(1.414)
        let period: CGFloat = 8
        // Lines x + y = c, anchored to the column so stripes continue across rows.
        let phase = column.contentMinX + 9.95
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

    func separatorFrames(_ separator: SeparatorCell, top: CGFloat, height rowHeight: CGFloat) -> SeparatorFrames {
        guard let column = columns.first else { return SeparatorFrames(pill: nil, buttons: [], content: nil, textX: 0) }
        let marginTop: CGFloat = separator.type == .lineInfo || separator.type == .custom ? (separator.isFirstHunk ? 0 : Metrics.gap) : 0
        let height = min(Metrics.separatorHeight, rowHeight)
        let y = top + marginTop
        let buttons = separator.expandButtons
        let gutterRight = column.minX + column.gutterWidth
        switch separator.type {
        case .lineInfo, .custom:
            let leftInset = column.minX + Metrics.gap
            var buttonFrames: [(ExpansionDirection, CGRect)] = []
            var contentMinX = leftInset
            if !buttons.isEmpty {
                buttonFrames = splitButtons(buttons, in: CGRect(x: leftInset, y: y, width: max(0, gutterRight - Metrics.gutterBorder - leftInset), height: height))
                contentMinX = gutterRight
            }
            let contentMaxX = geometry.isSplitLayout ? column.maxX : column.maxX - Metrics.gap
            let content = CGRect(x: contentMinX, y: y, width: max(0, contentMaxX - contentMinX), height: height)
            return SeparatorFrames(pill: CGRect(x: leftInset, y: y, width: max(0, contentMaxX - leftInset), height: height), buttons: buttonFrames, content: content, textX: content.minX + style.ch)
        case .lineInfoBasic:
            var buttonFrames: [(ExpansionDirection, CGRect)] = []
            var contentMinX = column.minX
            if !buttons.isEmpty {
                buttonFrames = splitButtons(buttons, in: CGRect(x: column.minX, y: y, width: max(0, gutterRight - Metrics.gutterBorder - column.minX), height: height))
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
        guard buttons.count > 1 else { return buttons.map { ($0, rect) } }
        // Two buttons stack with a one point divider between.
        let half = rect.height / 2
        return [
            (buttons[0], CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: half - 1)),
            (buttons[1], CGRect(x: rect.minX, y: rect.minY + half + 1, width: rect.width, height: half - 1)),
        ]
    }

    private func drawSeparatorRow(_ separator: SeparatorCell, top: CGFloat, height: CGFloat, context: CGContext) {
        let separatorColor = style.cgColor(palette.bgSeparator)
        let frames = separatorFrames(separator, top: top, height: height)
        switch separator.type {
        case .simple:
            context.setFillColor(separatorColor)
            for column in columns {
                context.fill(CGRect(x: column.minX, y: top, width: column.width, height: min(height, Metrics.simpleSeparatorHeight)))
            }
        case .metadata:
            context.setFillColor(separatorColor)
            for column in columns { context.fill(CGRect(x: column.minX, y: top, width: column.width, height: height)) }
            let label = (separator.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            drawSeparatorLabel(label, x: frames.textX, top: frames.content?.minY ?? top, height: Metrics.separatorHeight, clip: nil, context: context)
        case .lineInfoBasic:
            context.setFillColor(separatorColor)
            for column in columns { context.fill(CGRect(x: column.minX, y: top, width: column.width, height: height)) }
            drawButtonBorders(frames.buttons, context: context)
            drawButtons(frames.buttons, separator: separator, context: context)
            drawSeparatorLabel(separator.label, x: frames.textX, top: top, height: height, clip: frames.content, context: context)
        case .lineInfo, .custom:
            let radius = Metrics.separatorRadius
            context.setFillColor(separatorColor)
            if let pill = frames.pill, !geometry.isSplitLayout {
                context.addPath(CGPath(roundedRect: pill, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            } else if let pill = frames.pill {
                // Split: the left half rounds on the left, the right half on the right.
                fillRoundedRect(pill, radius: radius, left: true, right: false, context: context)
                if columns.count > 1 {
                    let second = columns[1]
                    fillRoundedRect(CGRect(x: second.minX, y: pill.minY, width: max(0, second.maxX - Metrics.gap - second.minX), height: pill.height), radius: radius, left: false, right: true, context: context)
                }
            }
            drawButtonBorders(frames.buttons, context: context)
            drawButtons(frames.buttons, separator: separator, context: context)
            drawSeparatorLabel(separator.label, x: frames.textX, top: frames.content?.minY ?? top, height: Metrics.separatorHeight, clip: frames.content, context: context)
        }
    }

    private func drawButtonBorders(_ buttons: [(ExpansionDirection, CGRect)], context: CGContext) {
        guard let first = buttons.first?.1 else { return }
        context.setFillColor(style.cgColor(palette.bg))
        let height = buttons.count > 1 ? buttons[1].1.maxY - first.minY : first.height
        context.fill(CGRect(x: first.maxX, y: first.minY, width: Metrics.gutterBorder, height: height))
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
        for (direction, rect) in buttons {
            let hovered = interaction.hoveredControl == .expand(itemID: item.id, hunk: separator.hunkIndex, direction: direction)
            let color = style.cgColor(hovered ? palette.fg : palette.fgNumber)
            let icon: DiffsIcon = direction == .both ? .expandAll : .expand
            let iconRect = CGRect(x: rect.midX - 8, y: rect.midY - 8, width: 16, height: 16)
            if direction == .down {
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
        let font = style.headerFont
        let text = makeTextLine(label, font: font, color: style.cgColor(palette.fgNumber))
        let baseline = top + ((height - (font.ascender - font.descender)) / 2 + font.ascender).rounded()
        context.saveGState()
        if let clip { context.clip(to: clip) }
        drawTextLine(text, in: context, x: x, baseline: baseline)
        context.restoreGState()
    }

    // MARK: Conflicts

    private var actionFont: NSFont { NSFont(descriptor: style.headerFont.fontDescriptor, size: 12) ?? style.headerFont }

    private func drawInjected(_ injected: InjectedCell, row: Int, column: Column, gutterRect: CGRect, contentRect: CGRect, context: CGContext) {
        let state = LineVisualState(backgroundEnabled: configuration.showsBackgrounds, hasMergeConflict: true)
        switch injected.kind {
        case .mergeConflictMarker(let type, let text):
            fill(contentRect, palette.background(for: .mergeConflictMarker(type), state: state), context)
            fill(gutterRect, palette.background(for: .gutterBuffer(.mergeConflictMarker(type)), state: state), context)
            let line = makeTextLine(text, font: style.typography.codeFont, color: style.cgColor(palette.fg))
            context.saveGState()
            context.clip(to: contentRect)
            let x = column.contentMinX + style.ch - item.scrollX
            drawTextLine(line, in: context, x: x, baseline: contentRect.minY + style.baseline)
            let suffix: String? = type == .markerStart ? "(Current Change)" : type == .markerEnd ? "(Incoming Change)" : nil
            if let suffix {
                let suffixLine = makeTextLine(suffix, font: actionFont, color: style.cgColor(palette.fgConflictMarker))
                drawTextLine(suffixLine, in: context, x: x + textLineWidth(line) + style.ch, baseline: contentRect.minY + style.baseline)
            }
            context.restoreGState()
        case .mergeConflictActions(let conflictIndex):
            fill(contentRect, palette.background(for: .mergeConflictActions, state: state), context)
            fill(gutterRect, palette.background(for: .gutterBuffer(.mergeConflictAction), state: state), context)
            drawConflictActions(row: row, conflict: conflictIndex, contentRect: contentRect, context: context)
        }
    }

    func conflictActionFrames(contentRect: CGRect) -> [(MergeConflictResolution, CGRect, String)] {
        let font = actionFont
        var x = contentRect.minX + 8
        var frames: [(MergeConflictResolution, CGRect, String)] = []
        let actions: [(MergeConflictResolution, String)] = [(.current, "Accept current change"), (.incoming, "Accept incoming change"), (.both, "Accept both")]
        let separatorWidth = textLineWidth(makeTextLine("|", font: font, color: .black))
        for (index, action) in actions.enumerated() {
            let width = textLineWidth(makeTextLine(action.1, font: font, color: .black))
            frames.append((action.0, CGRect(x: x, y: contentRect.minY, width: width, height: contentRect.height), action.1))
            x += width
            if index < actions.count - 1 { x += 8 + separatorWidth }
        }
        return frames
    }

    private func drawConflictActions(row: Int, conflict: Int, contentRect: CGRect, context: CGContext) {
        let font = actionFont
        let baseline = contentRect.minY + ((contentRect.height - (font.ascender - font.descender)) / 2 + font.ascender).rounded()
        let frames = conflictActionFrames(contentRect: contentRect)
        for (index, frame) in frames.enumerated() {
            var color = palette.fgNumber
            if interaction.hoveredControl == .conflictAction(itemID: item.id, row: row, conflict: conflict, resolution: frame.0) {
                switch frame.0 {
                case .current: color = palette.additionBase
                case .incoming: color = palette.modifiedBase
                case .both: color = palette.fg
                }
            }
            drawTextLine(makeTextLine(frame.2, font: font, color: style.cgColor(color)), in: context, x: frame.1.minX, baseline: baseline)
            if index < frames.count - 1 {
                let separator = makeTextLine("|", font: font, color: style.cgColor(palette.fgNumber.withAlpha(palette.fgNumber.a * 0.6)))
                drawTextLine(separator, in: context, x: frame.1.maxX + 4, baseline: baseline)
            }
        }
    }

    // MARK: Gutter action

    /// The gutter action button beside a line: one line high, its right edge
    /// past the number column by a line height less a character.
    func gutterActionRect(column: Column, top: CGFloat) -> CGRect {
        let lineHeight = style.lineHeight
        let maxX = column.minX + column.gutterWidth - Metrics.gutterBorder + (lineHeight - style.ch)
        return CGRect(x: maxX - lineHeight, y: top, width: lineHeight, height: lineHeight)
    }

    private func drawGutterAction(_ rect: CGRect, context: CGContext) {
        context.setFillColor(style.cgColor(palette.modifiedBase))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.fillPath()
        DiffsIcon.plus.draw(in: context, rect: CGRect(x: rect.midX - 8, y: rect.midY - 8, width: 16, height: 16), color: style.cgColor(palette.bg))
    }
}

extension ItemGeometry {
    /// Two columns side by side.
    var isSplitLayout: Bool { columns.count == 2 }
}
