// Port of the `File` component: renders a single file with syntax
// highlighting, line numbers, annotations and interactions.

import AppKit
import SwiffsCore
import SwiffsEditor
import SwiffsHighlight

/// Renders one file. `Metadata` is the payload type of line annotations.
public final class FileView<Metadata>: DiffsDocumentView {
    public typealias Annotation = LineAnnotation<Metadata>

    public private(set) var file: FileContents?

    public var options = DiffsCodeOptions() {
        didSet { if options != oldValue { optionsDidChange(from: oldValue) } }
    }

    public private(set) var lineAnnotations: [Annotation] = []

    public var renderAnnotation: ((Annotation) -> NSView?)? { didSet { rebuildRows() } }
    public var renderHeaderPrefix: ((FileContents) -> NSView?)? { didSet { updateHeader() } }
    public var renderHeaderFilenameSuffix: ((FileContents) -> NSView?)? { didSet { updateHeader() } }
    public var renderHeaderMetadata: ((FileContents) -> NSView?)? { didSet { updateHeader() } }
    public var renderCustomHeader: ((FileContents) -> NSView?)? { didSet { updateHeader() } }

    public var onLineClick: ((DiffsLineEvent) -> Void)?
    public var onLineNumberClick: ((DiffsLineEvent) -> Void)?
    public var onLineEnter: ((DiffsLineEvent) -> Void)?
    public var onLineLeave: ((DiffsLineEvent) -> Void)?
    public var onTokenClick: ((DiffsTokenEvent) -> Void)?
    public var onTokenEnter: ((DiffsTokenEvent) -> Void)?
    public var onTokenLeave: ((DiffsTokenEvent) -> Void)?
    public var onGutterUtilityClick: ((SelectedLineRange) -> Void)? { didSet { rebuildGrid() } }
    public var onLineSelected: ((SelectedLineRange?) -> Void)?
    public var onLineSelectionStart: ((SelectedLineRange?) -> Void)?
    public var onLineSelectionChange: ((SelectedLineRange?) -> Void)?
    public var onLineSelectionEnd: ((SelectedLineRange?) -> Void)?
    public var onPostRender: ((FileView<Metadata>) -> Void)?

    /// Files at or below this many lines highlight synchronously.
    public var synchronousHighlightLineLimit = 600

    private var lines: [String] = []
    private var rowsResult: FileRowsResult?
    private var highlightResult: ThemedFileResult?
    private var highlightKey: HighlightKey?
    private var pendingHighlightKey: HighlightKey?
    private var annotationsByLine: [Int: [Annotation]] = [:]
    private var plainLineCache: [Int: HighlightedLine] = [:]
    /// The attached editor (`DiffsEditor.edit`); retained until it cleans up.
    private var editorSource: EditorLineSource?

    private struct HighlightKey: Equatable {
        var file: FileContents
        var options: RenderFileOptions
        var forcePlainText: Bool
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    public convenience init(options: DiffsCodeOptions = DiffsCodeOptions()) {
        self.init(frame: .zero)
        self.options = options
        codeOptions = options
        refreshStyleIfNeeded()
    }

    // MARK: - API

    public func render(file: FileContents, lineAnnotations: [Annotation]? = nil) {
        if self.file != file {
            self.file = file
            lines = linesFromFileContents(file.contents)
            plainLineCache.removeAll()
        }
        if let lineAnnotations { setAnnotations(lineAnnotations) }
        codeOptions = options
        refreshStyleIfNeeded()
        updateHeader()
        rebuildRows()
        requestHighlight()
    }

    public func setLineAnnotations(_ annotations: [Annotation]) {
        setAnnotations(annotations)
        rebuildRows()
    }

    private func setAnnotations(_ annotations: [Annotation]) {
        lineAnnotations = annotations
        var byLine: [Int: [Annotation]] = [:]
        for annotation in annotations {
            byLine[annotation.lineNumber, default: []].append(annotation)
        }
        annotationsByLine = byLine
    }

    public func setSelectedLines(_ range: SelectedLineRange?) {
        grid.setSelectedRange(range)
    }

    public var selectedLines: SelectedLineRange? { grid.lineSelectionRange }

    public var hoveredLine: DiffsHoveredLine? {
        guard let row = grid.hoveredRow, row < grid.model.rows.count, case .line(let line)? = grid.model.rows[row].cells.first ?? nil else { return nil }
        return DiffsHoveredLine(lineNumber: line.lineNumber, side: nil)
    }

    // MARK: - Updates

    private func optionsDidChange(from old: DiffsCodeOptions) {
        codeOptions = options
        if !refreshStyleIfNeeded() {
            rebuildRows()
        }
        if old.theme != options.theme || old.tokenizeMaxLineLength != options.tokenizeMaxLineLength || old.tokenizeMaxLength != options.tokenizeMaxLength {
            requestHighlight()
        }
    }

    override func styleDidChange() {
        rebuildRows()
        if highlightResult == nil || highlightResult?.themes != ThemeSlots(options.theme) {
            requestHighlight()
        }
    }

    private func updateHeader() {
        guard let file else {
            header.content = nil
            return
        }
        header.content = HeaderContent(file: file)
        header.setSlots(HeaderSlots(
            prefix: renderHeaderPrefix?(file),
            filenameSuffix: renderHeaderFilenameSuffix?(file),
            metadata: renderHeaderMetadata?(file),
            custom: renderCustomHeader?(file)
        ))
        needsLayout = true
    }

    private var gridOptions: GridOptions {
        GridOptions(
            overflow: options.overflow,
            diffIndicators: .none,
            disableBackground: false,
            disableLineNumbers: options.disableLineNumbers,
            hunkSeparators: .lineInfo,
            lineHoverHighlight: options.lineHoverHighlight,
            enableGutterUtility: options.enableGutterUtility || onGutterUtilityClick != nil,
            enableLineSelection: options.enableLineSelection,
            enableTokenInteractionsOnWhitespace: options.enableTokenInteractionsOnWhitespace,
            hasHeader: showsHeader
        )
    }

    private func rebuildRows() {
        guard file != nil else {
            rowsResult = nil
            grid.update(model: .empty, options: gridOptions, style: style)
            gridContentChanged()
            return
        }
        rowsResult = buildFileRows(lineCount: editorSource?.lineCount ?? lines.count, annotationLines: Set(annotationsByLine.keys))
        rebuildGrid()
    }

    private func rebuildGrid() {
        guard let rowsResult else { return }
        grid.controlledSelection = options.controlledSelection
        grid.update(model: GridModel(file: rowsResult), options: gridOptions, style: style)
        gridContentChanged()
        onPostRender?(self)
    }

    // MARK: - Highlighting

    private func requestHighlight() {
        guard let file else { return }
        let renderOptions = RenderFileOptions(theme: options.theme, tokenizeMaxLineLength: options.tokenizeMaxLineLength)
        let key = HighlightKey(file: file, options: renderOptions, forcePlainText: lines.count > options.tokenizeMaxLength)
        if key == highlightKey || key == pendingHighlightKey { return }
        pendingHighlightKey = key
        if lines.count <= synchronousHighlightLineLimit, !key.forcePlainText,
           let result = try? MainThreadHighlighter.shared.renderFile(file, options: renderOptions)
        {
            applyHighlight(result, key: key)
            return
        }
        HighlightWorkerPool.shared.highlightFile(file, options: renderOptions, forcePlainText: key.forcePlainText) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.pendingHighlightKey == key, case .success(let value) = result else { return }
                self.applyHighlight(value, key: key)
            }
        }
    }

    private func applyHighlight(_ result: ThemedFileResult, key: HighlightKey) {
        highlightResult = result
        highlightKey = key
        pendingHighlightKey = nil
        grid.invalidateLines()
        gridContentChanged()
    }

    override func line(side: AnnotationSide, lineIndex: Int) -> HighlightedLine {
        if let editorSource { return editorSource.highlightedLine(lineIndex) }
        return originalLine(lineIndex)
    }

    private func originalLine(_ lineIndex: Int) -> HighlightedLine {
        if let highlightResult, highlightKey?.file == file, lineIndex < highlightResult.lines.count, let line = highlightResult.lines[lineIndex] {
            return line
        }
        if let cached = plainLineCache[lineIndex] { return cached }
        let text = lineIndex < lines.count ? cleanLastNewline(lines[lineIndex]) : ""
        let line = HighlightedLine.plain(text, slots: ThemeSlots(options.theme).count)
        plainLineCache[lineIndex] = line
        return line
    }

    // MARK: - Grid delegate

    override func grid(_ grid: CodeGridView, annotationViewFor cell: AnnotationCell, column: Int) -> NSView? {
        guard let renderAnnotation else { return nil }
        let views = cell.keys.flatMap { annotationsByLine[$0.lineNumber] ?? [] }.compactMap(renderAnnotation)
        if views.isEmpty { return nil }
        if views.count == 1 { return views[0] }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        return stack
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

// MARK: - Editor host

extension FileView: EditorHost {
    var editorGrid: CodeGridView { grid }
    var editorFile: FileContents? { file }


    var editorTabSize: Int { options.typography.tabSize }
    var editorWraps: Bool { options.overflow == .wrap }

    func editorOriginalLine(_ index: Int) -> HighlightedLine {
        originalLine(index)
    }

    func editorAttach(_ provider: EditorLineSource) {
        editorSource = provider
        rebuildRows()
    }

    func editorDetach(finalText: String?) {
        editorSource = nil
        if let finalText, let file {
            // Keep showing the edited contents.
            render(file: FileContents(name: file.name, contents: finalText, lang: file.lang, cacheKey: nil))
        } else {
            rebuildRows()
        }
        grid.invalidateLines()
    }

    func editorApplyAnnotations(_ annotations: [Any]) {
        guard let annotations = annotations as? [Annotation] else { return }
        applyEditorAnnotations(annotations)
    }

    var editorResolveRenderableLine: ((Int, CursorVerticalDirection) -> Int?)? { nil }

    func editorDocumentChanged(_ change: TextDocumentChange?) {
        rebuildRows()
    }

    /// Annotations moved by an edit.
    func applyEditorAnnotations(_ annotations: [Annotation]) {
        setAnnotations(annotations)
        rebuildRows()
    }
}
