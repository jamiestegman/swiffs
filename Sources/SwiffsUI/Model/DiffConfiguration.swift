import AppKit
import SwiffsCore
import SwiffsHighlight

/// Fonts and metrics for code and headers.
nonisolated public struct DiffTypography: Equatable {
    /// Code font; SF Mono 13 by default.
    public var codeFont: NSFont
    /// Header and separator font; the system font at 13 by default.
    public var headerFont: NSFont
    /// Height of one code line.
    public var lineHeight: CGFloat
    /// Tab width in characters.
    public var tabSize: Int

    public init(codeFont: NSFont = DiffTypography.defaultCodeFont(size: 13), headerFont: NSFont = .systemFont(ofSize: 13), lineHeight: CGFloat = 20, tabSize: Int = 2) {
        self.codeFont = codeFont
        self.headerFont = headerFont
        self.lineHeight = lineHeight
        self.tabSize = tabSize
    }

    public static func defaultCodeFont(size: CGFloat) -> NSFont {
        NSFont(name: "SFMono-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// Which part of a hovered line is highlighted.
nonisolated public enum LineHoverHighlight: Hashable, Sendable {
    case disabled
    /// The line number and the code.
    case both
    case number
    case line
}

/// How a diff view draws its items and what it lets the user do.
nonisolated public struct DiffConfiguration: Equatable {
    public var style: DiffStyle = .split
    public var theme: ThemeSelection = .pair(DiffsConstants.defaultThemes)
    /// Light, dark, or following the view's appearance.
    public var colorScheme: ThemeType = .system
    public var colorOverrides = DiffsColorOverrides()
    public var typography = DiffTypography()
    /// Scroll long lines horizontally, or wrap them.
    public var overflow: Overflow = .scroll
    /// How changes within a line are emphasised.
    public var lineDiffType: LineDiffType = .wordAlt
    public var indicators: DiffIndicators = .bars
    public var showsBackgrounds = true
    public var showsLineNumbers = true
    public var showsHeaders = true
    /// Keeps the header of the item at the top of the viewport in view.
    public var stickyHeaders = true
    public var hunkSeparators: HunkSeparators = .lineInfo
    /// Partial diffs (from a patch) offer to expand their hidden context,
    /// loading full files from the delegate.
    public var loadsFullFiles = false
    public var expandsUnchanged = false
    public var collapsedContextThreshold = DiffsConstants.defaultCollapsedContextThreshold
    /// Lines revealed by one expansion of a hunk separator.
    public var expansionLineCount = 100
    public var lineHoverHighlight: LineHoverHighlight = .disabled
    /// Lines can be selected by dragging over line numbers.
    public var allowsLineSelection = false
    /// A button beside the hovered line, or the selection's last line, that
    /// reports a gutter action.
    public var showsGutterAction = false
    /// Lines longer than this are not tokenized.
    public var tokenizeMaxLineLength = 1000
    /// Content with more lines than this is shown as plain text.
    public var tokenizeMaxLength = DiffsConstants.defaultTokenizeMaxLength
    /// Content up to this many lines is highlighted before its first frame.
    public var synchronousHighlightLineLimit = 600
    public var padding: CGFloat = 8
    public var itemSpacing: CGFloat = 8
    /// Viewport heights laid out beyond the visible area.
    public var overscan: CGFloat = 1
    /// Viewport heights beyond the overscan highlighted ahead of scrolling.
    public var prefetch: CGFloat = 1
    public var smoothScrolling = DiffsConstants.defaultSmoothScrollSettings

    public init() {}

    var renderDiffOptions: RenderDiffOptions {
        RenderDiffOptions(theme: theme, tokenizeMaxLineLength: tokenizeMaxLineLength, lineDiffType: lineDiffType)
    }

    var renderFileOptions: RenderFileOptions {
        RenderFileOptions(theme: theme, tokenizeMaxLineLength: tokenizeMaxLineLength)
    }

    /// Whether a change requires rebuilding rows, as opposed to redrawing.
    func rowsDiffer(from other: DiffConfiguration) -> Bool {
        style != other.style || hunkSeparators != other.hunkSeparators || expandsUnchanged != other.expandsUnchanged
            || collapsedContextThreshold != other.collapsedContextThreshold || expansionLineCount != other.expansionLineCount
            || showsHeaders != other.showsHeaders || loadsFullFiles != other.loadsFullFiles
    }
}
