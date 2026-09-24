// Native equivalents of `BaseCodeOptions`, `BaseDiffOptions` and
// `InteractionManagerBaseOptions`.

import AppKit
import SwiffsCore
import SwiffsHighlight

public enum LineHoverHighlight: String, Hashable, Sendable {
    case disabled, both, number, line
}

/// Typography (the `--diffs-font-*` / `--diffs-line-height` variables).
public struct DiffsTypography: Equatable, @unchecked Sendable {
    /// Code font (`--diffs-font-family`, default SF Mono 13px).
    public var codeFont: NSFont
    /// Header/separator font (`--diffs-header-font-family`, system 13px).
    public var headerFont: NSFont
    /// Row height (`--diffs-line-height`, default 20px).
    public var lineHeight: CGFloat
    /// Tab width in characters (`--diffs-tab-size`, default 2).
    public var tabSize: Int

    public init(
        codeFont: NSFont = DiffsTypography.defaultCodeFont(size: 13),
        headerFont: NSFont = NSFont.systemFont(ofSize: 13),
        lineHeight: CGFloat = 20,
        tabSize: Int = 2
    ) {
        self.codeFont = codeFont
        self.headerFont = headerFont
        self.lineHeight = lineHeight
        self.tabSize = tabSize
    }

    /// `'SF Mono', Monaco, ...` fallback chain.
    public static func defaultCodeFont(size: CGFloat) -> NSFont {
        if let sfMono = NSFont(name: "SFMono-Regular", size: size) { return sfMono }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// Options shared by `FileView` and `FileDiffView` (`BaseCodeOptions`).
public struct DiffsCodeOptions: Equatable, @unchecked Sendable {
    public var theme: ThemeSelection = .pair(DiffsConstants.defaultThemes)
    public var themeType: ThemeType = .system
    public var disableLineNumbers = false
    public var overflow: Overflow = .scroll
    public var collapsed = false
    public var disableFileHeader = false
    public var stickyHeader = false
    public var tokenizeMaxLineLength = 1000
    public var tokenizeMaxLength = DiffsConstants.defaultTokenizeMaxLength
    public var typography = DiffsTypography()
    public var colorOverrides = DiffsColorOverrides()
    /// Leave render errors to `onRenderError` instead of showing them in the
    /// view (`disableErrorHandling`).
    public var disableErrorHandling = false

    // Interaction (InteractionManagerBaseOptions)
    public var lineHoverHighlight: LineHoverHighlight = .disabled
    public var enableTokenInteractionsOnWhitespace = false
    public var enableGutterUtility = false
    public var enableLineSelection = false
    public var controlledSelection = false

    public init() {}
}

/// Options for `FileDiffView` (`FileDiffOptions`).
public struct DiffsDiffOptions: Equatable, @unchecked Sendable {
    public var code = DiffsCodeOptions()
    public var diffStyle: DiffStyle = .split
    public var diffIndicators: DiffIndicators = .bars
    public var disableBackground = false
    public var hunkSeparators: HunkSeparators = .lineInfo
    public var expandUnchanged = false
    public var collapsedContextThreshold = DiffsConstants.defaultCollapsedContextThreshold
    public var lineDiffType: LineDiffType = .wordAlt
    public var maxLineDiffLength = 1000
    public var expansionLineCount = 100
    public var parseDiffOptions = CreatePatchOptions()

    public init() {}

    var rowsOptions: DiffRowsOptions {
        DiffRowsOptions(
            diffStyle: diffStyle,
            hunkSeparators: hunkSeparators,
            expandUnchanged: expandUnchanged,
            collapsedContextThreshold: collapsedContextThreshold,
            expansionLineCount: expansionLineCount,
            canLoadDiffFiles: false
        )
    }

    var renderDiffOptions: RenderDiffOptions {
        RenderDiffOptions(
            theme: code.theme,
            tokenizeMaxLineLength: code.tokenizeMaxLineLength,
            lineDiffType: lineDiffType,
            maxLineDiffLength: maxLineDiffLength
        )
    }
}

// MARK: - Events

/// A hovered or clicked line (`LineEventBaseProps` /
/// `DiffLineEventBaseProps`).
public struct DiffsLineEvent: Hashable, Sendable {
    public var lineNumber: Int
    /// Side for diffs; nil for files.
    public var side: AnnotationSide?
    public var lineType: LineType
    /// True when the pointer is over the line number column.
    public var numberColumn: Bool
}

/// A hovered or clicked token (`TokenEventBase`).
public struct DiffsTokenEvent: Hashable, Sendable {
    public var lineNumber: Int
    public var side: AnnotationSide?
    /// UTF-16 offsets within the line.
    public var lineCharStart: Int
    public var lineCharEnd: Int
    public var tokenText: String
}

/// The line under the gutter utility (`GetHoveredLineResult`).
public struct DiffsHoveredLine: Hashable, Sendable {
    public var lineNumber: Int
    public var side: AnnotationSide?
}
