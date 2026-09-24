// Port of the `FileDiff` component: renders a single file diff with header,
// split/unified columns, hunk expansion, annotations and interactions.

import AppKit
import SwiffsCore
import SwiffsHighlight

/// Renders one file diff. `Metadata` is the payload type of line
/// annotations.
public final class FileDiffView<Metadata>: DiffsDocumentView {
    public typealias Annotation = DiffLineAnnotation<Metadata>

    // MARK: Public state

    public private(set) var fileDiff: FileDiffMetadata?

    public var options = DiffsDiffOptions() {
        didSet { if options != oldValue { optionsDidChange(from: oldValue) } }
    }

    public private(set) var lineAnnotations: [Annotation] = []

    // MARK: Rendering callbacks (the `render*` options)

    /// Returns the view for an annotation (`renderAnnotation`).
    public var renderAnnotation: ((Annotation) -> NSView?)? { didSet { rebuildRows() } }
    public var renderHeaderPrefix: ((FileDiffMetadata) -> NSView?)? { didSet { updateHeader() } }
    public var renderHeaderFilenameSuffix: ((FileDiffMetadata) -> NSView?)? { didSet { updateHeader() } }
    public var renderHeaderMetadata: ((FileDiffMetadata) -> NSView?)? { didSet { updateHeader() } }
    public var renderCustomHeader: ((FileDiffMetadata) -> NSView?)? { didSet { updateHeader() } }

    // MARK: Interaction callbacks

    public var onLineClick: ((DiffsLineEvent) -> Void)?
    public var onLineNumberClick: ((DiffsLineEvent) -> Void)?
    public var onLineEnter: ((DiffsLineEvent) -> Void)?
    public var onLineLeave: ((DiffsLineEvent) -> Void)?
    public var onTokenClick: ((DiffsTokenEvent) -> Void)?
    public var onTokenEnter: ((DiffsTokenEvent) -> Void)?
    public var onTokenLeave: ((DiffsTokenEvent) -> Void)?
    /// Setting this enables the gutter utility button.
    public var onGutterUtilityClick: ((SelectedLineRange) -> Void)? { didSet { rebuildGrid() } }
    public var onLineSelected: ((SelectedLineRange?) -> Void)?
    public var onLineSelectionStart: ((SelectedLineRange?) -> Void)?
    public var onLineSelectionChange: ((SelectedLineRange?) -> Void)?
    public var onLineSelectionEnd: ((SelectedLineRange?) -> Void)?
    /// Called after a hunk expands.
    public var onHunkExpand: ((Int, ExpansionDirection) -> Void)?
    /// Called after rendering (`onPostRender`).
    public var onPostRender: ((FileDiffView<Metadata>) -> Void)?

    // MARK: Internal state

    private var expandedHunks: [Int: HunkExpansionRegion] = [:]
    private var rowsResult: DiffRowsResult?
    private var highlightResult: ThemedDiffResult?
    private var highlightKey: HighlightKey?
    private var pendingHighlightKey: HighlightKey?
    private var annotationsByKey: [AnnotationKey: [Annotation]] = [:]
    private var plainLineCache: [AnnotationSide: [Int: HighlightedLine]] = [:]

    private struct HighlightKey: Equatable {
        var diff: FileDiffMetadata
        var options: RenderDiffOptions
        var forcePlainText: Bool
    }

    /// Diffs at or below this many lines highlight synchronously so the first
    /// paint is already highlighted.
    public var synchronousHighlightLineLimit = 600

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    public convenience init(options: DiffsDiffOptions = DiffsDiffOptions()) {
        self.init(frame: .zero)
        self.options = options
        codeOptions = options.code
        refreshStyleIfNeeded()
    }

    // MARK: - Rendering API

    /// Renders a diff (`render({ fileDiff })`).
    public func render(fileDiff: FileDiffMetadata, lineAnnotations: [Annotation]? = nil) {
        let changed = self.fileDiff != fileDiff
        self.fileDiff = fileDiff
        if let lineAnnotations { setAnnotations(lineAnnotations) }
        if changed {
            expandedHunks.removeAll()
            plainLineCache.removeAll()
        }
        codeOptions = options.code
        refreshStyleIfNeeded()
        updateHeader()
        rebuildRows()
        requestHighlight()
    }

    /// Renders a diff between two files (`render({ oldFile, newFile })`).
    public func render(oldFile: FileContents?, newFile: FileContents?, lineAnnotations: [Annotation]? = nil) throws {
        let diff = try parseDiffFromFile(oldFile: oldFile, newFile: newFile, options: options.parseDiffOptions)
        render(fileDiff: diff, lineAnnotations: lineAnnotations)
    }

    /// Renders a single-file patch.
    public func render(patch: String, lineAnnotations: [Annotation]? = nil) throws {
        render(fileDiff: try getSingularPatch(patch), lineAnnotations: lineAnnotations)
    }

    public func setLineAnnotations(_ annotations: [Annotation]) {
        setAnnotations(annotations)
        rebuildRows()
    }

    private func setAnnotations(_ annotations: [Annotation]) {
        lineAnnotations = annotations
        var byKey: [AnnotationKey: [Annotation]] = [:]
        for annotation in annotations {
            byKey[AnnotationKey(side: annotation.side, lineNumber: annotation.lineNumber), default: []].append(annotation)
        }
        annotationsByKey = byKey
    }

    // MARK: Selection

    public func setSelectedLines(_ range: SelectedLineRange?) {
        grid.setSelectedRange(range)
    }

    public var selectedLines: SelectedLineRange? { grid.selectedRange }

    /// The line under the gutter utility / pointer (`getHoveredLine`).
    public var hoveredLine: DiffsHoveredLine? {
        guard let row = grid.hoveredRow, let column = grid.hoveredColumn, row < grid.model.rows.count, column < grid.columns.count else { return nil }
        let index = grid.columns[column].cellIndex
        guard case .line(let line)? = grid.model.rows[row].cells[index] else { return nil }
        return DiffsHoveredLine(lineNumber: line.lineNumber, side: line.side)
    }

    // MARK: Hunk expansion

    /// Expands a collapsed region (`expandHunk`). `lineCount` defaults to
    /// `expansionLineCount`; pass `Int.max` to expand everything.
    public func expandHunk(_ hunkIndex: Int, direction: ExpansionDirection, lineCount: Int? = nil) {
        let count = lineCount ?? options.expansionLineCount
        var region = expandedHunks[hunkIndex] ?? .default
        func add(_ value: Int, _ delta: Int) -> Int { value >= Int.max - delta ? Int.max / 2 : value + delta }
        if direction == .up || direction == .both {
            region.fromStart = add(region.fromStart, count)
        }
        if direction == .down || direction == .both {
            region.fromEnd = add(region.fromEnd, count)
        }
        expandedHunks[hunkIndex] = region
        rebuildRows()
        onHunkExpand?(hunkIndex, direction)
    }

    public func expandedRegion(for hunkIndex: Int) -> HunkExpansionRegion {
        expandedHunks[hunkIndex] ?? .default
    }

    // MARK: - Updates

    private func optionsDidChange(from old: DiffsDiffOptions) {
        codeOptions = options.code
        let styleChanged = refreshStyleIfNeeded()
        if !styleChanged {
            rebuildRows()
        }
        if old.renderDiffOptions != options.renderDiffOptions || old.code.tokenizeMaxLength != options.code.tokenizeMaxLength {
            requestHighlight()
        }
    }

    override func styleDidChange() {
        rebuildRows()
        if highlightResult == nil || highlightResult?.themes != ThemeSlots(options.code.theme) {
            requestHighlight()
        }
    }

    private func updateHeader() {
        guard let fileDiff else {
            header.content = nil
            return
        }
        header.content = HeaderContent(fileDiff: fileDiff)
        header.setSlots(HeaderSlots(
            prefix: renderHeaderPrefix?(fileDiff),
            filenameSuffix: renderHeaderFilenameSuffix?(fileDiff),
            metadata: renderHeaderMetadata?(fileDiff),
            custom: renderCustomHeader?(fileDiff)
        ))
        needsLayout = true
    }

    private var gridOptions: GridOptions {
        GridOptions(
            overflow: options.code.overflow,
            diffIndicators: options.diffIndicators,
            disableBackground: options.disableBackground,
            disableLineNumbers: options.code.disableLineNumbers,
            hunkSeparators: options.hunkSeparators,
            lineHoverHighlight: options.code.lineHoverHighlight,
            enableGutterUtility: options.code.enableGutterUtility || onGutterUtilityClick != nil,
            enableLineSelection: options.code.enableLineSelection,
            enableTokenInteractionsOnWhitespace: options.code.enableTokenInteractionsOnWhitespace,
            hasHeader: showsHeader
        )
    }

    private func rebuildRows() {
        guard let fileDiff else {
            rowsResult = nil
            grid.update(model: .empty, options: gridOptions, style: style)
            gridContentChanged()
            return
        }
        var rowOptions = options.rowsOptions
        rowOptions.canLoadDiffFiles = false
        do {
            rowsResult = try buildDiffRows(
                fileDiff: fileDiff,
                options: rowOptions,
                expandedHunks: expandedHunks,
                deletionAnnotationLines: Set(lineAnnotations.filter { $0.side == .deletions }.map(\.lineNumber)),
                additionAnnotationLines: Set(lineAnnotations.filter { $0.side == .additions }.map(\.lineNumber))
            )
        } catch {
            rowsResult = nil
        }
        rebuildGrid()
    }

    private func rebuildGrid() {
        guard let rowsResult else {
            grid.update(model: .empty, options: gridOptions, style: style)
            gridContentChanged()
            return
        }
        grid.controlledSelection = options.code.controlledSelection
        grid.lineIndexResolver = { [weak self] lineNumber, side in
            guard let diff = self?.fileDiff else { return nil }
            return getLineIndexForDiff(diff, lineNumber: lineNumber, side: side ?? .additions)
        }
        grid.update(model: GridModel(diff: rowsResult, style: options.diffStyle), options: gridOptions, style: style)
        gridContentChanged()
        onPostRender?(self)
    }

    // MARK: - Highlighting

    private var isMassive: Bool {
        guard let fileDiff else { return false }
        return max(fileDiff.additionLines.count, fileDiff.deletionLines.count) > options.code.tokenizeMaxLength
    }

    private func requestHighlight() {
        guard let fileDiff else { return }
        let hasContent = !fileDiff.additionLines.isEmpty || !fileDiff.deletionLines.isEmpty
        guard hasContent else { return }
        let key = HighlightKey(diff: fileDiff, options: options.renderDiffOptions, forcePlainText: isMassive)
        if key == highlightKey || key == pendingHighlightKey { return }
        pendingHighlightKey = key
        let lineCount = max(fileDiff.additionLines.count, fileDiff.deletionLines.count)
        if lineCount <= synchronousHighlightLineLimit, !key.forcePlainText {
            let highlighter = MainThreadHighlighter.shared
            if let result = try? highlighter.renderDiff(fileDiff, options: key.options) {
                applyHighlight(result, key: key)
                return
            }
        }
        HighlightWorkerPool.shared.highlightDiff(fileDiff, options: key.options, forcePlainText: key.forcePlainText) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.pendingHighlightKey == key, case .success(let value) = result else { return }
                self.applyHighlight(value, key: key)
            }
        }
    }

    private func applyHighlight(_ result: ThemedDiffResult, key: HighlightKey) {
        highlightResult = result
        highlightKey = key
        pendingHighlightKey = nil
        grid.invalidateLines()
        gridContentChanged()
    }

    override func line(side: AnnotationSide, lineIndex: Int) -> HighlightedLine {
        if let highlightResult, highlightKey?.diff == fileDiff {
            let lines = side == .deletions ? highlightResult.deletionLines : highlightResult.additionLines
            if lineIndex < lines.count, let line = lines[lineIndex] {
                return line
            }
        }
        if let cached = plainLineCache[side]?[lineIndex] { return cached }
        guard let fileDiff else { return HighlightedLine(text: "", tokens: []) }
        let source = side == .deletions ? fileDiff.deletionLines : fileDiff.additionLines
        let text = lineIndex < source.count ? cleanLastNewline(source[lineIndex]) : ""
        let line = HighlightedLine.plain(text, slots: ThemeSlots(options.code.theme).count)
        plainLineCache[side, default: [:]][lineIndex] = line
        return line
    }

    // MARK: - Grid delegate

    override func grid(_ grid: CodeGridView, annotationViewFor cell: AnnotationCell, column: Int) -> NSView? {
        guard let renderAnnotation else { return nil }
        let views = cell.keys.flatMap { annotationsByKey[$0] ?? [] }.compactMap(renderAnnotation)
        if views.isEmpty { return nil }
        if views.count == 1 { return views[0] }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        return stack
    }

    override func grid(_ grid: CodeGridView, expandHunk hunkIndex: Int, direction: ExpansionDirection, all: Bool) {
        expandHunk(hunkIndex, direction: direction, lineCount: all ? Int.max : nil)
    }

    override func grid(_ grid: CodeGridView, lineEvent: DiffsLineEvent, kind: GridLineEventKind) {
        switch kind {
        case .click: onLineClick?(lineEvent)
        case .numberClick: onLineNumberClick?(lineEvent)
        case .enter: onLineEnter?(lineEvent)
        case .leave: onLineLeave?(lineEvent)
        }
    }

    override func grid(_ grid: CodeGridView, tokenEvent: DiffsTokenEvent, kind: GridTokenEventKind) {
        switch kind {
        case .click: onTokenClick?(tokenEvent)
        case .enter: onTokenEnter?(tokenEvent)
        case .leave: onTokenLeave?(tokenEvent)
        }
    }

    override func grid(_ grid: CodeGridView, selectionEvent range: SelectedLineRange?, phase: GridSelectionPhase) {
        switch phase {
        case .start: onLineSelectionStart?(range)
        case .change: onLineSelectionChange?(range)
        case .end: onLineSelectionEnd?(range)
        case .committed: onLineSelected?(range)
        }
    }

    override func grid(_ grid: CodeGridView, gutterUtilityClicked range: SelectedLineRange) {
        onGutterUtilityClick?(range)
    }

    override var gridHandlesLineClicks: Bool { onLineClick != nil }
    override var gridHandlesLineNumberClicks: Bool { onLineNumberClick != nil }
    override var gridHandlesGutterUtilityClicks: Bool { onGutterUtilityClick != nil }
    override var gridHandlesTokenEvents: Bool { onTokenClick != nil || onTokenEnter != nil || onTokenLeave != nil }
    override var gridHandlesLineHoverEvents: Bool { onLineEnter != nil || onLineLeave != nil }
}

/// A highlighter confined to the main thread, used for small synchronous
/// renders.
@MainActor
final class MainThreadHighlighter {
    static let shared = DiffsHighlighter()
}
