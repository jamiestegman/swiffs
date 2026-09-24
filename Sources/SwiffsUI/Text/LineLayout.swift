// Core Text layout of highlighted lines: token colors and font styles, tab
// stops (`tab-size`), intra-line change span boxes and wrapping
// (`white-space: pre-wrap; word-break: break-word`).

import AppKit
import CoreText
import SwiffsCore
import SwiffsHighlight

/// A laid out code line, possibly wrapped into several visual lines.
final class LineLayout {
    let text: String
    let utf16Count: Int
    let lines: [CTLine]
    /// UTF-16 start offset of each visual line.
    let lineStarts: [Int]
    let diffSpans: [LineRange]
    let tokens: [HighlightedToken]
    /// Width of the widest visual line.
    let width: CGFloat

    init(text: String, lines: [CTLine], lineStarts: [Int], diffSpans: [LineRange], tokens: [HighlightedToken]) {
        self.text = text
        utf16Count = text.utf16.count
        self.lines = lines
        self.lineStarts = lineStarts
        self.diffSpans = diffSpans
        self.tokens = tokens
        width = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
    }

    var visualLineCount: Int { max(1, lines.count) }

    /// Builds the attributed string for a highlighted line.
    static func attributedString(_ line: HighlightedLine, style: DiffsStyleContext, dimmed: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString(string: line.text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = CGFloat(style.typography.tabSize) * style.ch
        paragraph.tabStops = []
        paragraph.lineBreakMode = .byCharWrapping
        let fullRange = NSRange(location: 0, length: result.length)
        result.addAttributes([
            .font: style.regularFont,
            .foregroundColor: style.cgColor(style.palette.fg),
            .paragraphStyle: paragraph,
            .ligature: 0,
        ], range: fullRange)
        let index = min(style.styleIndex, max(0, (line.tokens.first?.styles.count ?? 1) - 1))
        for token in line.tokens {
            guard token.start < token.end, token.end <= result.length else { continue }
            let range = NSRange(location: token.start, length: token.end - token.start)
            let tokenStyle = index < token.styles.count ? token.styles[index] : TokenStyle()
            var color = style.tokenColor(tokenStyle.color)
            if dimmed { color = color.copy(alpha: color.alpha * 0.6) ?? color }
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if !tokenStyle.fontStyle.isEmpty {
                attributes[.font] = style.font(for: tokenStyle.fontStyle)
                if tokenStyle.fontStyle.contains(.underline) {
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.underlineColor] = color
                }
                if tokenStyle.fontStyle.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.strikethroughColor] = color
                }
            }
            result.addAttributes(attributes, range: range)
        }
        return result
    }

    /// Lays out a line; `wrapWidth` enables wrapping.
    static func make(_ line: HighlightedLine, style: DiffsStyleContext, wrapWidth: CGFloat?, dimmed: Bool = false) -> LineLayout {
        let attributed = attributedString(line, style: style, dimmed: dimmed)
        guard let wrapWidth, wrapWidth > style.ch, attributed.length > 0 else {
            let ctLine = CTLineCreateWithAttributedString(attributed)
            return LineLayout(text: line.text, lines: [ctLine], lineStarts: [0], diffSpans: line.diffSpans, tokens: line.tokens)
        }
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var lines: [CTLine] = []
        var starts: [Int] = []
        var start = 0
        let length = attributed.length
        while start < length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(wrapWidth))
            if count <= 0 {
                count = max(1, CTTypesetterSuggestClusterBreak(typesetter, start, Double(wrapWidth)))
            }
            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            lines.append(ctLine)
            starts.append(start)
            start += count
        }
        return LineLayout(text: line.text, lines: lines, lineStarts: starts, diffSpans: line.diffSpans, tokens: line.tokens)
    }

    /// Visual line and x offset of a UTF-16 index.
    func position(of index: Int) -> (line: Int, x: CGFloat) {
        var lineIndex = 0
        for (i, start) in lineStarts.enumerated() where start <= index {
            lineIndex = i
        }
        guard lineIndex < lines.count else { return (0, 0) }
        let x = CTLineGetOffsetForStringIndex(lines[lineIndex], index, nil)
        return (lineIndex, x)
    }

    /// UTF-16 index nearest to a point (x relative to the text origin,
    /// visual line index).
    func index(at x: CGFloat, visualLine: Int) -> Int {
        guard !lines.isEmpty else { return 0 }
        let lineIndex = max(0, min(visualLine, lines.count - 1))
        let line = lines[lineIndex]
        let index = CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0))
        if index == kCFNotFound { return lineStarts[lineIndex] }
        return max(0, min(index, utf16Count))
    }

    /// Draws the line with its top-left at `origin` (flipped coordinates).
    func draw(in context: CGContext, origin: CGPoint, style: DiffsStyleContext, spanColor: CGColor?) {
        let lineHeight = style.lineHeight
        if let spanColor, !diffSpans.isEmpty {
            context.setFillColor(spanColor)
            for span in diffSpans where span.end > span.start {
                for (i, line) in lines.enumerated() {
                    let lineStart = lineStarts[i]
                    let lineEnd = i + 1 < lineStarts.count ? lineStarts[i + 1] : utf16Count
                    let s = max(span.start, lineStart)
                    let e = min(span.end, lineEnd)
                    if e <= s { continue }
                    let x0 = CTLineGetOffsetForStringIndex(line, s, nil)
                    let x1 = CTLineGetOffsetForStringIndex(line, e, nil)
                    let top = origin.y + CGFloat(i) * lineHeight + (lineHeight - style.contentHeight) / 2
                    let rect = CGRect(x: origin.x + x0, y: top, width: max(0, x1 - x0), height: style.contentHeight)
                    let path = CGPath(roundedRect: rect, cornerWidth: min(3, rect.width / 2), cornerHeight: min(3, rect.height / 2), transform: nil)
                    context.addPath(path)
                    context.fillPath()
                }
            }
        }
        for (i, line) in lines.enumerated() {
            context.saveGState()
            // Core Text draws in a y-up space; flip around the baseline.
            context.textMatrix = .identity
            context.translateBy(x: origin.x, y: origin.y + CGFloat(i) * lineHeight + style.baseline)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
}

/// Lays out plain text in the header or separator font.
func makeTextLine(_ text: String, font: NSFont, color: CGColor) -> CTLine {
    let attributed = NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: color,
    ])
    return CTLineCreateWithAttributedString(attributed)
}

func drawTextLine(_ line: CTLine, in context: CGContext, x: CGFloat, baseline: CGFloat) {
    context.saveGState()
    context.textMatrix = .identity
    context.translateBy(x: x, y: baseline)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()
}

func textLineWidth(_ line: CTLine) -> CGFloat {
    CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}
