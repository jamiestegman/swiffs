// Port of the `FileDiff` component: renders a single file diff with header,
// split/unified columns, hunk expansion, annotations and interactions.

import AppKit
import SwiffsCore
import SwiffsEditor
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
    /// Decides whether a completed edit session installs its result
    /// (`onEditComplete`).
    public var onEditComplete: ((FileDiffEditCompleteEvent<Metadata>) -> EditCompletionDecision)?

    // MARK: Internal state

    private var expandedHunks: [Int: HunkExpansionRegion] = [:]
    private var rowsResult: DiffRowsResult?
    private var highlightResult: ThemedDiffResult?
    private var highlightKey: HighlightKey?
    private var pendingHighlightKey: HighlightKey?
    private var annotationsByKey: [AnnotationKey: [Annotation]] = [:]
    private var plainLineCache: [AnnotationSide: [Int: HighlightedLine]] = [:]
    /// The attached editor (`DiffsEditor.edit`); retained until it cleans up.
    private var editorSource: EditorLineSource?
    /// Highlighting of the diff when editing started (old-side lines stay
    /// valid for the whole session).
    private var editorOriginalHighlight: ThemedDiffResult?
    private var editorOriginalDiff: FileDiffMetadata?

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
    public func render(fileDiff: FileDiffMetadata, lineAnnotations: [Annotation]? = nil, expandedHunks initialExpandedHunks: [Int: HunkExpansionRegion]? = nil) {
        let changed = self.fileDiff != fileDiff
        self.fileDiff = fileDiff
        if let lineAnnotations { setAnnotations(lineAnnotations) }
        if changed {
            expandedHunks.removeAll()
            plainLineCache.removeAll()
        }
        if let initialExpandedHunks { expandedHunks = initialExpandedHunks }
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

    public var selectedLines: SelectedLineRange? { grid.lineSelectionRange }

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
        loadFilesIfNecessary()
        rebuildRows()
        onHunkExpand?(hunkIndex, direction)
    }

    /// Loads the full files for a partial diff so collapsed context can
    /// expand (`loadDiffFiles`).
    public var loadDiffFiles: ((FileDiffMetadata) async throws -> DiffLoadedFiles)? {
        didSet { rebuildRows() }
    }

    private var pendingFileLoad: FileDiffMetadata?

    /// `loadFilesIfNecessary`.
    private func loadFilesIfNecessary() {
        guard let fileDiff, let loadDiffFiles, canHydrateDiff(fileDiff), pendingFileLoad != fileDiff else { return }
        pendingFileLoad = fileDiff
        Task { [weak self] in
            let files = try? await loadDiffFiles(fileDiff)
            guard let self else { return }
            if self.pendingFileLoad == fileDiff { self.pendingFileLoad = nil }
            guard let files, self.fileDiff == fileDiff, let hydrated = try? hydratePartialDiff(fileDiff, files: files) else { return }
            // Keep the expansion state across hydration.
            let expanded = self.expandedHunks
            self.render(fileDiff: hydrated, expandedHunks: expanded)
        }
    }

    public func expandedRegion(for hunkIndex: Int) -> HunkExpansionRegion {
        expandedHunks[hunkIndex] ?? .default
    }

    /// The whole expansion map (to persist state across view reuse).
    public var expandedHunksMap: [Int: HunkExpansionRegion] {
        get { expandedHunks }
        set {
            expandedHunks = newValue
            rebuildRows()
        }
    }

    // MARK: - Updates

    private func optionsDidChange(from old: DiffsDiffOptions) {
        codeOptions = options.code
        let styleChanged = refreshStyleIfNeeded()
        if !styleChanged {
            rebuildRows()
        }
        if effectiveOptions(old).renderDiffOptions != effectiveOptions.renderDiffOptions || old.code.tokenizeMaxLength != options.code.tokenizeMaxLength {
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

    /// Installs a diff updated by an edit session, keeping expansion and
    /// highlighting state.
    fileprivate func setEditedDiff(_ diff: FileDiffMetadata) {
        fileDiff = diff
        plainLineCache.removeAll()
        updateHeader()
        rebuildRows()
    }

    private func rebuildRows() {
        guard let fileDiff else {
            rowsResult = nil
            grid.update(model: .empty, options: gridOptions, style: style)
            gridContentChanged()
            return
        }
        var rowOptions = effectiveOptions.rowsOptions
        rowOptions.canLoadDiffFiles = loadDiffFiles != nil
        do {
            rowsResult = try buildDiffRows(
                fileDiff: fileDiff,
                options: rowOptions,
                expandedHunks: expandedHunks,
                deletionAnnotationLines: Set(lineAnnotations.filter { $0.side == .deletions }.map(\.lineNumber)),
                additionAnnotationLines: Set(lineAnnotations.filter { $0.side == .additions }.map(\.lineNumber)),
                injectedRows: mergeConflict?.injectedRows(for: fileDiff)
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
        var model = GridModel(diff: rowsResult, style: effectiveOptions.diffStyle)
        if let mergeConflict {
            model.hasMergeConflict = true
            model.mergeConflictActionsType = mergeConflict.actionsType
        }
        grid.update(model: model, options: gridOptions, style: style)
        gridContentChanged()
        onPostRender?(self)
    }

    // MARK: - Merge conflicts

    /// Merge conflict rendering state, set by `UnresolvedFileView`
    /// (`UnresolvedFileHunksRenderer.setConflictState`).
    struct MergeConflictState {
        var actions: [MergeConflictDiffAction?]
        var markerRows: [MergeConflictMarkerRow]
        var actionsType: MergeConflictActionsType

        func injectedRows(for fileDiff: FileDiffMetadata) -> MergeConflictInjectedRows {
            MergeConflictInjectedRows(actions: actionsType == .none ? [] : actions, markerRows: markerRows, fileDiff: fileDiff)
        }
    }

    var mergeConflict: MergeConflictState?

    /// Rebuilds rows after `mergeConflict` changes.
    func reloadRows() {
        rebuildRows()
        requestHighlight()
    }
    var onMergeConflictActionClick: ((Int, MergeConflictResolution) -> Void)?
    var renderMergeConflictActionView: ((Int) -> NSView?)?

    /// Unresolved files always render unified without inline diffs
    /// (`UnresolvedFileHunksRenderer.getOptionsWithDefaults`).
    private var effectiveOptions: DiffsDiffOptions { effectiveOptions(options) }

    private func effectiveOptions(_ options: DiffsDiffOptions) -> DiffsDiffOptions {
        guard mergeConflict != nil else { return options }
        var options = options
        options.diffStyle = .unified
        options.lineDiffType = .none
        return options
    }

    override func grid(_ grid: CodeGridView, mergeConflictActionViewFor conflictIndex: Int) -> NSView? {
        renderMergeConflictActionView?(conflictIndex)
    }

    override func grid(_ grid: CodeGridView, mergeConflictAction resolution: MergeConflictResolution, conflictIndex: Int) {
        onMergeConflictActionClick?(conflictIndex, resolution)
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
        let key = HighlightKey(diff: fileDiff, options: effectiveOptions.renderDiffOptions, forcePlainText: isMassive)
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
        if let editorSource {
            if side == .additions { return editorSource.highlightedLine(lineIndex) }
            if let original = editorOriginalHighlight, lineIndex < original.deletionLines.count, let line = original.deletionLines[lineIndex] {
                return line
            }
            let source = fileDiff?.deletionLines ?? []
            let text = lineIndex < source.count ? cleanLastNewline(source[lineIndex]) : ""
            return HighlightedLine.plain(text, slots: ThemeSlots(options.code.theme).count)
        }
        return originalLine(side: side, lineIndex: lineIndex)
    }

    private func originalLine(side: AnnotationSide, lineIndex: Int) -> HighlightedLine {
        if let original = editorOriginalHighlight, editorOriginalDiff != nil {
            let lines = side == .deletions ? original.deletionLines : original.additionLines
            if lineIndex < lines.count, let line = lines[lineIndex] { return line }
        }
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

// MARK: - Editor host

/// Replaces a line's text, keeping its line break (`applyLineTextWithNewline`).
func applyLineTextWithNewline(_ line: String, _ text: String) -> String {
    let units = Array(line.utf16)
    if units.count >= 2, units[units.count - 2] == 0x0D, units[units.count - 1] == 0x0A { return text + "\r\n" }
    if units.last == 0x0D { return text + "\r" }
    if units.last == 0x0A { return text + "\n" }
    return text
}

extension FileDiffView: EditorHost {
    var editorGrid: CodeGridView { grid }

    /// The new side as a file; deleted files cannot be edited.
    var editorFile: FileContents? {
        guard let fileDiff, fileDiff.type != .deleted else { return nil }
        return FileContents(name: fileDiff.name, contents: fileDiff.additionLines.joined(), lang: fileDiff.lang)
    }

    var editorTabSize: Int { options.code.typography.tabSize }
    var editorWraps: Bool { options.code.overflow == .wrap }

    func editorOriginalLine(_ index: Int) -> HighlightedLine {
        originalLine(side: .additions, lineIndex: index)
    }

    func editorAttach(_ provider: EditorLineSource) {
        editorOriginalHighlight = highlightKey?.diff == fileDiff ? highlightResult : nil
        editorOriginalDiff = fileDiff
        editorSource = provider
        rebuildRows()
    }

    func editorDetach(result: EditorDetachResult, editor: AnyObject) {
        editorSource = nil
        let original = editorOriginalDiff
        editorOriginalHighlight = nil
        editorOriginalDiff = nil
        if case .complete(_, let annotations) = result, var diff = fileDiff, let original {
            finishEditSessionForDiff(&diff, options: options.parseDiffOptions)
            diff.cacheKey = nil
            let event = FileDiffEditCompleteEvent(
                fileDiff: diff,
                editor: editor,
                originalFileDiff: original,
                oldFile: diff.type == .new ? nil : FileContents(name: diff.prevName ?? diff.name, contents: diff.deletionLines.joined(), lang: diff.lang),
                newFile: FileContents(name: diff.name, contents: diff.additionLines.joined(), lang: diff.lang),
                lineAnnotations: annotations as? [Annotation],
                originalLineAnnotations: lineAnnotations
            )
            (editor as? AnyEditorCompletionObserver)?.observeCompletion(event)
            if onEditComplete?(event) == .accept {
                if let annotations = event.lineAnnotations { setLineAnnotations(annotations) }
                render(fileDiff: diff, expandedHunks: expandedHunks)
                grid.invalidateLines()
                return
            }
        }
        // Discard (or rejected completion): restore the input diff.
        if let original {
            fileDiff = nil
            render(fileDiff: original)
        }
        grid.invalidateLines()
    }

    func editorApplyAnnotations(_ annotations: [Any]) {
        guard let annotations = annotations as? [Annotation] else { return }
        setLineAnnotations(annotations)
    }

    var editorResolveRenderableLine: ((Int, CursorVerticalDirection) -> Int?)? {
        { [weak self] line, direction in
            guard let self else { return line }
            let count = self.editorSource?.lineCount ?? 0
            var candidate = line
            while candidate >= 0, candidate < count {
                if self.grid.editorLocation(ofLine: candidate) != nil { return candidate }
                candidate += direction == .up ? -1 : 1
            }
            return nil
        }
    }

    /// Keeps the diff's new side and hunks in sync with the edited document
    /// (`updateRenderCache` / `applyDocumentChange`).
    func editorDocumentChanged(_ change: TextDocumentChange?) {
        guard let change, var diff = fileDiff, let source = editorSource else { return }
        let parseOptions = options.parseDiffOptions
        let sessionType = diff.type
        func preservingType(_ update: (inout FileDiffMetadata) -> Void) {
            update(&diff)
            diff.type = sessionType
            diff.editSessionDirty = true
        }
        let keepsLineCount = change.lineDelta == 0 && change.changedLineChanges.allSatisfy { $0.lineDelta == 0 }
        if keepsLineCount {
            var changed: [Int] = []
            var previous: [Int: String] = [:]
            for range in change.changedLineRanges {
                for line in range where line < diff.additionLines.count {
                    let prevLine = diff.additionLines[line]
                    let text = source.lineText(line)
                    if !cleanLastNewline(prevLine).utf16.elementsEqual(text.utf16) {
                        diff.additionLines[line] = applyLineTextWithNewline(prevLine, text)
                        changed.append(line)
                        previous[line] = prevLine
                    }
                }
            }
            if !changed.isEmpty {
                if diff.additionLines.count <= 1, diff.additionLines.joined().isEmpty {
                    preservingType { recomputeEmptyDocumentDiff(&$0, options: parseOptions) }
                } else if shouldTopAlignAdditionRecompute(diff, additionLines: diff.additionLines) {
                    let lines = diff.additionLines
                    preservingType { recomputeTopAlignedAdditionDiff(&$0, additionLines: lines, options: parseOptions) }
                } else if let regionChange = try? applySessionChangedLines(&diff, changedAdditionLineIndexes: changed, options: parseOptions, previousAdditionLines: previous) {
                    expandedHunks = remapExpandedHunksForRegionChange(expandedHunks, regionChange)
                }
            }
        } else {
            let previousLines = diff.additionLines
            diff.additionLines = (0 ..< source.lineCount).map { source.lineTextWithBreak($0) }
            if diff.additionLines.count <= 1, diff.additionLines.joined().isEmpty {
                preservingType { recomputeEmptyDocumentDiff(&$0, options: parseOptions) }
            } else if shouldTopAlignAdditionRecompute(diff, additionLines: diff.additionLines) {
                let lines = diff.additionLines
                preservingType { recomputeTopAlignedAdditionDiff(&$0, additionLines: lines, options: parseOptions) }
            } else if let regionChange = try? rebuildSessionHunks(&diff, options: parseOptions, getPreviousAdditionLine: { $0 >= 0 && $0 < previousLines.count ? previousLines[$0] : nil }) {
                expandedHunks = remapExpandedHunksForRegionChange(expandedHunks, regionChange)
            }
        }
        setEditedDiff(diff)
    }

}


/// `onEditComplete` argument for diffs (`FileDiffEditCompleteEvent`).
public struct FileDiffEditCompleteEvent<Metadata> {
    /// The recomputed diff of the final contents (no cache key).
    public var fileDiff: FileDiffMetadata
    public var editor: AnyObject
    /// The last diff the view was given; rejecting keeps it.
    public var originalFileDiff: FileDiffMetadata
    /// The completed contents as a file pair; `oldFile` is nil for an added
    /// file.
    public var oldFile: FileContents?
    public var newFile: FileContents?
    public var lineAnnotations: [DiffLineAnnotation<Metadata>]?
    public var originalLineAnnotations: [DiffLineAnnotation<Metadata>]
}
