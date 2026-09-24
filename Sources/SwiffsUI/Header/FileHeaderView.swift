// Port of `createFileHeaderElement`: change icon, (previous) file name and
// the `-deletions +additions` summary, with slots for custom views.

import AppKit
import SwiffsCore

/// Custom views placed in the header (the upstream header slots).
struct HeaderSlots {
    var prefix: NSView?
    var filenameSuffix: NSView?
    var metadata: NSView?
    /// Replaces the whole header (`renderCustomHeader`).
    var custom: NSView?
}

enum HeaderIconType: Equatable {
    case file
    case change(ChangeType)

    var icon: DiffsIcon {
        switch self {
        case .file: return .fileCode
        case .change(.change): return .symbolModified
        case .change(.new): return .symbolAdded
        case .change(.deleted): return .symbolDeleted
        case .change(.renamePure), .change(.renameChanged): return .symbolMoved
        }
    }
}

struct HeaderContent: Equatable {
    var name: String
    var prevName: String?
    var iconType: HeaderIconType
    /// nil for files (no counts).
    var deletions: Int?
    var additions: Int?

    init(fileDiff: FileDiffMetadata) {
        name = fileDiff.name
        prevName = fileDiff.prevName
        iconType = .change(fileDiff.type)
        var additions = 0
        var deletions = 0
        for hunk in fileDiff.hunks {
            additions += hunk.additionLines
            deletions += hunk.deletionLines
        }
        self.additions = additions
        self.deletions = deletions
    }

    init(file: FileContents) {
        name = file.name
        prevName = nil
        iconType = .file
        additions = nil
        deletions = nil
    }
}

final class FileHeaderView: NSView {
    static let height: CGFloat = 44
    private let paddingInline: CGFloat = 16
    private let gap: CGFloat = 8

    var content: HeaderContent? { didSet { if content != oldValue { needsLayout = true; needsDisplay = true } } }
    var style: DiffsStyleContext { didSet { needsDisplay = true } }
    private(set) var slots = HeaderSlots()
    private var textStart: CGFloat = 0

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

    func setSlots(_ slots: HeaderSlots) {
        for view in [self.slots.prefix, self.slots.filenameSuffix, self.slots.metadata, self.slots.custom].compactMap({ $0 })
            where ![slots.prefix, slots.filenameSuffix, slots.metadata, slots.custom].contains(where: { $0 === view })
        {
            view.removeFromSuperview()
        }
        self.slots = slots
        for view in [slots.prefix, slots.filenameSuffix, slots.metadata, slots.custom].compactMap({ $0 }) where view.superview !== self {
            addSubview(view)
        }
        needsLayout = true
        needsDisplay = true
    }

    private func slotSize(_ view: NSView) -> CGSize {
        let fitting = view.fittingSize
        return CGSize(width: fitting.width > 0 ? fitting.width : view.frame.width, height: fitting.height > 0 ? fitting.height : view.frame.height)
    }

    override func layout() {
        super.layout()
        let midY = bounds.height / 2
        if let custom = slots.custom {
            custom.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
            return
        }
        var x = paddingInline
        if let prefix = slots.prefix {
            let size = slotSize(prefix)
            prefix.frame = CGRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height)
            x += size.width + gap
        }
        textStart = x
        var right = bounds.width - paddingInline
        if let metadata = slots.metadata {
            let size = slotSize(metadata)
            metadata.frame = CGRect(x: right - size.width, y: midY - size.height / 2, width: size.width, height: size.height)
            right -= size.width + style.ch
        }
        if let suffix = slots.filenameSuffix {
            let size = slotSize(suffix)
            let titleEnd = min(titleLayout().end, right - countsWidth() - gap - size.width)
            suffix.frame = CGRect(x: titleEnd + gap, y: midY - size.height / 2, width: size.width, height: size.height)
        }
    }

    private func countsLines() -> [(CTLine, CGFloat)] {
        guard let content, let additions = content.additions, let deletions = content.deletions else { return [] }
        let palette = style.palette
        var lines: [CTLine] = []
        if deletions > 0 || additions == 0 {
            lines.append(makeTextLine("-\(deletions)", font: style.typography.codeFont, color: style.cgColor(palette.deletionBase)))
        }
        if additions > 0 || deletions == 0 {
            lines.append(makeTextLine("+\(additions)", font: style.typography.codeFont, color: style.cgColor(palette.additionBase)))
        }
        return lines.map { ($0, textLineWidth($0)) }
    }

    private func countsWidth() -> CGFloat {
        let lines = countsLines()
        guard !lines.isEmpty else { return 0 }
        return lines.reduce(0) { $0 + $1.1 } + CGFloat(lines.count - 1) * style.ch
    }

    /// Returns where the title ends (for the filename suffix slot).
    private func titleLayout() -> (start: CGFloat, end: CGFloat) {
        guard let content else { return (textStart, textStart) }
        let font = style.headerFont
        var x = textStart + 16 + gap
        if let prevName = content.prevName {
            x += textLineWidth(makeTextLine(prevName, font: font, color: .black)) + gap + 16 + gap
        }
        x += textLineWidth(makeTextLine(content.name, font: font, color: .black))
        return (textStart, x)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let palette = style.palette
        context.setFillColor(style.cgColor(palette.bg))
        context.fill(bounds)
        guard slots.custom == nil, let content else { return }
        let font = style.headerFont
        let baseline = ((bounds.height - (font.ascender - font.descender)) / 2 + font.ascender).rounded()
        let iconY = (bounds.height - 16) / 2

        // Right side: counts (and the metadata slot).
        var right = bounds.width - paddingInline
        if let metadata = slots.metadata {
            right = metadata.frame.minX - style.ch
        }
        let counts = countsLines()
        var countsX = right - countsWidth()
        let countsStart = countsX
        let codeFont = style.typography.codeFont
        let codeBaseline = ((bounds.height - (codeFont.ascender - codeFont.descender)) / 2 + codeFont.ascender).rounded()
        for (line, width) in counts {
            drawTextLine(line, in: context, x: countsX, baseline: codeBaseline)
            countsX += width + style.ch
        }

        // Left side: icon, names.
        var x = textStart
        let iconColor: RGBAColor
        var iconAlpha: CGFloat = 1
        switch content.iconType {
        case .file:
            iconColor = palette.fg
            iconAlpha = 0.6
        case .change(.new): iconColor = palette.additionBase
        case .change(.deleted): iconColor = palette.deletionBase
        case .change: iconColor = palette.modifiedBase
        }
        let cgIconColor = style.cgColor(iconColor.withAlpha(iconColor.a * Double(iconAlpha)))
        content.iconType.icon.draw(in: context, rect: CGRect(x: x, y: iconY, width: 16, height: 16), color: cgIconColor)
        x += 16 + gap
        let available = max(0, countsStart - gap - x - (slots.filenameSuffix.map { $0.frame.width + gap } ?? 0))
        let fg = style.cgColor(palette.fg)
        if let prevName = content.prevName {
            let prevColor = style.cgColor(palette.fg.withAlpha(palette.fg.a * 0.7))
            let prevWidth = min(textLineWidth(makeTextLine(prevName, font: font, color: prevColor)), available / 2)
            drawTruncatedStart(prevName, font: font, color: prevColor, x: x, width: prevWidth, baseline: baseline, context: context)
            x += prevWidth + gap
            DiffsIcon.arrowRightShort.draw(in: context, rect: CGRect(x: x, y: iconY, width: 16, height: 16), color: fg)
            x += 16 + gap
        }
        let remaining = max(0, countsStart - gap - x - (slots.filenameSuffix.map { $0.frame.width + gap } ?? 0))
        drawTruncatedStart(content.name, font: font, color: fg, x: x, width: remaining, baseline: baseline, context: context)
    }

    /// `direction: rtl; text-overflow: ellipsis` truncates at the start.
    private func drawTruncatedStart(_ text: String, font: NSFont, color: CGColor, x: CGFloat, width: CGFloat, baseline: CGFloat, context: CGContext) {
        let line = makeTextLine(text, font: font, color: color)
        if textLineWidth(line) <= width {
            drawTextLine(line, in: context, x: x, baseline: baseline)
            return
        }
        let token = makeTextLine("…", font: font, color: color)
        let truncated = CTLineCreateTruncatedLine(line, Double(width), .start, token) ?? line
        drawTextLine(truncated, in: context, x: x, baseline: baseline)
    }
}
