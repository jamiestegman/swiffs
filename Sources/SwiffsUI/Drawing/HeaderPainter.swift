import AppKit
import CoreText
import SwiffsCore

/// What an item's header shows.
struct HeaderContent: Equatable {
    enum Icon: Equatable {
        case file
        case change(ChangeType)
    }

    var name: String
    var previousName: String?
    var icon: Icon
    /// Line counts; nil for files.
    var deletions: Int?
    var additions: Int?

    init(_ item: ItemModel) {
        if let diff = item.diff {
            name = diff.name
            previousName = diff.prevName
            icon = .change(diff.type)
            var additions = 0
            var deletions = 0
            for hunk in diff.hunks {
                additions += hunk.additionLines
                deletions += hunk.deletionLines
            }
            self.additions = additions
            self.deletions = deletions
        } else {
            name = item.item.name
            icon = .file
        }
    }
}

/// Draws an item's header: change icon, names and line counts, leaving
/// room for the accessory at the trailing edge.
struct HeaderPainter {
    static let paddingInline: CGFloat = 16
    static let gap: CGFloat = 8

    let content: HeaderContent
    let style: StyleContext

    private var palette: DiffsPalette { style.palette }

    /// Draws into `rect`; `accessoryWidth` is reserved at the trailing edge.
    func draw(in rect: CGRect, accessoryWidth: CGFloat, context: CGContext) {
        context.setFillColor(style.cgColor(palette.bg))
        context.fill(rect)
        let font = style.headerFont
        let baseline = rect.minY + ((rect.height - (font.ascender - font.descender)) / 2 + font.ascender).rounded()
        let iconY = rect.minY + (rect.height - Metrics.iconSize) / 2

        var right = rect.maxX - Self.paddingInline
        if accessoryWidth > 0 { right -= accessoryWidth + style.ch }
        let counts = countLines()
        let countsWidth = counts.isEmpty ? 0 : counts.reduce(0) { $0 + $1.1 } + CGFloat(counts.count - 1) * style.ch
        var countsX = right - countsWidth
        let countsStart = countsX
        let codeFont = style.typography.codeFont
        let codeBaseline = rect.minY + ((rect.height - (codeFont.ascender - codeFont.descender)) / 2 + codeFont.ascender).rounded()
        for (line, width) in counts {
            drawTextLine(line, in: context, x: countsX, baseline: codeBaseline)
            countsX += width + style.ch
        }

        var x = rect.minX + Self.paddingInline
        let iconColor: RGBAColor
        let icon: DiffsIcon
        switch content.icon {
        case .file:
            iconColor = palette.fg.withAlpha(palette.fg.a * 0.6)
            icon = .fileCode
        case .change(.new):
            iconColor = palette.additionBase
            icon = .symbolAdded
        case .change(.deleted):
            iconColor = palette.deletionBase
            icon = .symbolDeleted
        case .change(.renamePure), .change(.renameChanged):
            iconColor = palette.modifiedBase
            icon = .symbolMoved
        case .change(.change):
            iconColor = palette.modifiedBase
            icon = .symbolModified
        }
        icon.draw(in: context, rect: CGRect(x: x, y: iconY, width: Metrics.iconSize, height: Metrics.iconSize), color: style.cgColor(iconColor))
        x += Metrics.iconSize + Self.gap
        let available = max(0, countsStart - Self.gap - x)
        let fg = style.cgColor(palette.fg)
        if let previousName = content.previousName {
            let previousColor = style.cgColor(palette.fg.withAlpha(palette.fg.a * 0.7))
            let previousWidth = min(textLineWidth(makeTextLine(previousName, font: font, color: previousColor)), available / 2)
            drawTruncatingStart(previousName, font: font, color: previousColor, x: x, width: previousWidth, baseline: baseline, context: context)
            x += previousWidth + Self.gap
            DiffsIcon.arrowRightShort.draw(in: context, rect: CGRect(x: x, y: iconY, width: Metrics.iconSize, height: Metrics.iconSize), color: fg)
            x += Metrics.iconSize + Self.gap
        }
        drawTruncatingStart(content.name, font: font, color: fg, x: x, width: max(0, countsStart - Self.gap - x), baseline: baseline, context: context)
    }

    private func countLines() -> [(CTLine, CGFloat)] {
        guard let additions = content.additions, let deletions = content.deletions else { return [] }
        var lines: [CTLine] = []
        if deletions > 0 || additions == 0 {
            lines.append(makeTextLine("-\(deletions)", font: style.typography.codeFont, color: style.cgColor(palette.deletionBase)))
        }
        if additions > 0 || deletions == 0 {
            lines.append(makeTextLine("+\(additions)", font: style.typography.codeFont, color: style.cgColor(palette.additionBase)))
        }
        return lines.map { ($0, textLineWidth($0)) }
    }

    /// Paths truncate at their start, keeping the file name.
    private func drawTruncatingStart(_ text: String, font: NSFont, color: CGColor, x: CGFloat, width: CGFloat, baseline: CGFloat, context: CGContext) {
        let line = makeTextLine(text, font: font, color: color)
        if textLineWidth(line) <= width {
            drawTextLine(line, in: context, x: x, baseline: baseline)
            return
        }
        let truncated = CTLineCreateTruncatedLine(line, Double(width), .start, makeTextLine("…", font: font, color: color)) ?? line
        drawTextLine(truncated, in: context, x: x, baseline: baseline)
    }
}
