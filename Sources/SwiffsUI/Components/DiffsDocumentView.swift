// Shared plumbing for `FileView` and `FileDiffView`: theme resolution,
// appearance tracking, header + grid layout.

import AppKit
import SwiffsCore
import SwiffsHighlight

/// Base class for the file and diff views. Not intended to be subclassed
/// outside the module.
public class DiffsDocumentView: NSView, CodeGridDelegate, GridLineProvider {
    let grid: CodeGridView
    let header: FileHeaderView
    var codeOptions = DiffsCodeOptions()
    private(set) var resolvedTheme: ResolvedDiffsTheme
    private var resolvedSelection: ThemeSelection
    private var styleKey: StyleKey?
    var style: DiffsStyleContext

    private struct StyleKey: Equatable {
        var theme: ThemeSelection
        var themeType: ThemeType
        var systemIsDark: Bool
        var typography: DiffsTypography
        var overrides: DiffsColorOverrides
    }

    /// Called when the view's preferred height changes.
    public var onHeightChange: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        let selection = DiffsCodeOptions().theme
        let theme = (try? ResolvedDiffsTheme.resolve(selection)) ?? DiffsDocumentView.fallbackTheme
        resolvedTheme = theme
        resolvedSelection = selection
        style = DiffsStyleContext(
            typography: DiffsTypography(),
            theme: theme,
            themeType: .system,
            systemIsDark: false,
            overrides: DiffsColorOverrides()
        )
        grid = CodeGridView(style: style)
        header = FileHeaderView(style: style)
        super.init(frame: frameRect)
        wantsLayer = true
        grid.delegate = self
        grid.lineProvider = self
        addSubview(grid)
        // The header sits above the code so it can stick over it.
        addSubview(header)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static let fallbackTheme = ResolvedDiffsTheme(
        light: ThemeColorInputs(fg: .black, bg: .white),
        dark: ThemeColorInputs(fg: .white, bg: .black),
        baseThemeType: nil,
        slots: .pair(dark: "pierre-dark", light: "pierre-light")
    )

    public override var isFlipped: Bool { true }

    var systemIsDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua]).map {
            [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua].contains($0)
        } ?? false
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshStyleIfNeeded()
    }

    /// Rebuilds the style context when theme or appearance inputs changed.
    /// Returns true when the style changed.
    @discardableResult
    func refreshStyleIfNeeded() -> Bool {
        let key = StyleKey(
            theme: codeOptions.theme,
            themeType: codeOptions.themeType,
            systemIsDark: systemIsDark,
            typography: codeOptions.typography,
            overrides: codeOptions.colorOverrides
        )
        if key == styleKey { return false }
        if resolvedSelection != codeOptions.theme || styleKey == nil {
            if let theme = try? ResolvedDiffsTheme.resolve(codeOptions.theme) {
                resolvedTheme = theme
            }
            resolvedSelection = codeOptions.theme
        }
        styleKey = key
        style = DiffsStyleContext(
            typography: codeOptions.typography,
            theme: resolvedTheme,
            themeType: codeOptions.themeType,
            systemIsDark: key.systemIsDark,
            overrides: codeOptions.colorOverrides
        )
        header.style = style
        styleDidChange()
        return true
    }

    /// Subclasses rebuild the grid here.
    func styleDidChange() {}

    // MARK: Layout

    var showsHeader: Bool { !codeOptions.disableFileHeader }
    var showsCode: Bool { !codeOptions.collapsed }

    var headerHeight: CGFloat { showsHeader ? FileHeaderView.height : 0 }

    /// Preferred height at a width.
    public func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        headerHeight + (showsCode ? grid.requiredHeight(forWidth: width) : 0)
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight(forWidth: bounds.width > 0 ? bounds.width : 800))
    }

    /// Offsets the header within the view to emulate `position: sticky`
    /// while the view scrolls under the top of a scroll container.
    public var stickyHeaderOffset: CGFloat = 0 {
        didSet {
            if stickyHeaderOffset != oldValue {
                needsLayout = true
            }
        }
    }

    /// Frame (in this view's coordinates) of a rendered line, or nil when
    /// the line is not currently rendered (collapsed or out of range).
    public func frameForLine(_ lineNumber: Int, side: AnnotationSide? = nil) -> CGRect? {
        guard showsCode, let row = grid.row(forLineNumber: lineNumber, side: side), let frame = grid.rowFrame(row) else { return nil }
        return frame.offsetBy(dx: 0, dy: grid.frame.minY)
    }

    public override func layout() {
        super.layout()
        header.isHidden = !showsHeader
        let maxOffset = max(0, bounds.height - headerHeight)
        header.frame = CGRect(x: 0, y: min(max(0, stickyHeaderOffset), maxOffset), width: bounds.width, height: headerHeight)
        grid.isHidden = !showsCode
        let gridHeight = showsCode ? grid.requiredHeight(forWidth: bounds.width) : 0
        grid.frame = CGRect(x: 0, y: headerHeight, width: bounds.width, height: gridHeight)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged {
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(style.cgColor(style.palette.bg))
        context.fill(dirtyRect.intersection(bounds))
    }

    func gridContentChanged() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
        onHeightChange?(preferredHeight(forWidth: bounds.width))
    }

    // MARK: GridLineProvider

    func line(side: AnnotationSide, lineIndex: Int) -> HighlightedLine {
        HighlightedLine(text: "", tokens: [])
    }

    // MARK: CodeGridDelegate (overridden by subclasses)

    func grid(_ grid: CodeGridView, annotationViewFor cell: AnnotationCell, column: Int) -> NSView? { nil }
    func grid(_ grid: CodeGridView, expandHunk hunkIndex: Int, direction: ExpansionDirection, all: Bool) {}
    func grid(_ grid: CodeGridView, lineEvent: DiffsLineEvent, kind: GridLineEventKind) {}
    func grid(_ grid: CodeGridView, tokenEvent: DiffsTokenEvent, kind: GridTokenEventKind) {}
    func grid(_ grid: CodeGridView, selectionEvent range: SelectedLineRange?, phase: GridSelectionPhase) {}
    func grid(_ grid: CodeGridView, gutterUtilityClicked range: SelectedLineRange) {}

    func gridDidChangeHeight(_ grid: CodeGridView) {
        gridContentChanged()
    }

    var gridHandlesLineClicks: Bool { false }
    var gridHandlesLineNumberClicks: Bool { false }
    var gridHandlesGutterUtilityClicks: Bool { false }
    var gridHandlesTokenEvents: Bool { false }
    var gridHandlesLineHoverEvents: Bool { false }
}
