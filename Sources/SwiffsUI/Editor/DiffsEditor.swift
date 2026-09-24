// Port of the `Editor` class (`editor/editor.ts`): turns a `FileView` into
// an editable code editor with multiple selections, undo history, keymap
// commands, comment toggling, bracket matching and incremental highlighting.

import AppKit
import SwiffsCore
import SwiffsEditor
import SwiffsHighlight

/// Options for `DiffsEditor` (`EditorOptions`).
public struct DiffsEditorOptions {
    public var historyMaxEntries: Int?
    /// Custom keymap groups checked before the defaults.
    public var keymap: EditorKeymap?
    /// Highlight the bracket pair next to the caret.
    public var matchBrackets = true
    public var autoSurround: AutoSurround = .default
    public var languageCommentConfig: [String: LanguageConfig]?
    /// Inline edit prediction (`editPrediction`).
    public var editPrediction: DiffsEditPredictionOptions?

    public init() {}
}

/// Inline edit prediction configuration.
public struct DiffsEditPredictionOptions {
    public enum Mode: Sendable {
        /// Predictions appear as the user types.
        case eager
        /// Holding Alt shows predictions.
        case subtle
    }

    public var mode: Mode
    public var provider: any EditPredictProvider
    /// Path patterns to include (nil includes every file).
    public var include: [EditPredictionPattern]?
    /// Path patterns to exclude; exclusions win.
    public var exclude: [EditPredictionPattern]?

    public init(provider: any EditPredictProvider, mode: Mode = .eager, include: [EditPredictionPattern]? = nil, exclude: [EditPredictionPattern]? = nil) {
        self.provider = provider
        self.mode = mode
        self.include = include
        self.exclude = exclude
    }
}

/// An externally owned caret or selection shown in the editor
/// (`EditorCaret`), e.g. a collaborator's cursor.
public struct DiffsEditorCaret {
    public var anchor: Position
    public var focus: Position
    public var color: NSColor

    public init(anchor: Position, focus: Position, color: NSColor) {
        self.anchor = anchor
        self.focus = focus
        self.color = color
    }
}

/// What a selection action view can do (`SelectionActionContext`).
@MainActor
public struct DiffsSelectionActionContext {
    public var selection: EditorSelection
    public var getSelectionText: () -> String
    public var replaceSelectionText: (String) -> Void
    public var applyEdits: ([TextEdit]) -> Void
    public var close: () -> Void
}

/// Why an editor detaches (`cleanUp(reason)`).
public enum DiffsEditorCleanupReason: Sendable {
    /// Restore the view's input.
    case discard
    /// Detach but keep the keyed edit state for a later attach.
    case recycle
    /// Offer the result to the view's `onEditComplete`.
    case complete
}

/// A completion handler's decision (`EditCompletionDecision`).
public enum EditCompletionDecision: Sendable {
    case accept, reject
}

/// How a view ends an edit session.
enum EditorDetachResult {
    case discard
    case complete(text: String, annotations: [Any]?)
}

/// Retained edit state per key (`EditStateManager`): the document with its
/// history and the selections, so re-attaching resumes the session.
@MainActor
public final class DiffsEditStateStore {
    public static let shared = DiffsEditStateStore()

    struct Entry {
        var document: AnyObject
        var selections: [EditorSelection]
        var fileName: String
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    public var capacity = 100

    func take(_ key: String) -> Entry? {
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        order.removeAll { $0 == key }
        return entry
    }

    func store(_ key: String, _ entry: Entry) {
        entries[key] = entry
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
    }

    /// Drops retained state for a key.
    public func release(_ key: String) {
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }
}

/// Change notification (`EditorChangeEvent`).
public struct DiffsEditorChangeEvent {
    public var changes: [EditorChange]
    public var file: FileContents
}

/// Where an editor renders: a file or diff view.
@MainActor
protocol EditorHost: AnyObject {
    var editorGrid: CodeGridView { get }
    var editorFile: FileContents? { get }
    /// The rendered theme name and kind for the current appearance.
    var editorTheme: (name: String, kind: ThemeKind) { get }
    var editorTabSize: Int { get }
    var editorWraps: Bool { get }
    /// The host's current (pre-edit) highlighted line.
    func editorOriginalLine(_ index: Int) -> HighlightedLine
    func editorAttach(_ provider: EditorLineSource)
    func editorDetach(result: EditorDetachResult, editor: AnyObject)
    /// Annotations moved by an edit (typed as the host's annotations).
    func editorApplyAnnotations(_ annotations: [Any])
    /// The view that hosts overlays such as the search panel, and the top
    /// offset below its header.
    var editorOverlayContainer: NSView { get }
    var editorOverlayTop: CGFloat { get }
    /// Expands collapsed context hiding a document line.
    func editorRevealLine(_ line: Int)
    /// Fold skipping for vertical moves; nil when every line renders.
    var editorResolveRenderableLine: ((Int, CursorVerticalDirection) -> Int?)? { get }
    /// Rebuild rows after the document changed.
    func editorDocumentChanged(_ change: TextDocumentChange?)
}

/// Supplies the lines an attached editor renders.
@MainActor
protocol EditorLineSource: AnyObject {
    var lineCount: Int { get }
    func highlightedLine(_ index: Int) -> HighlightedLine
    func lineText(_ index: Int) -> String
    func lineTextWithBreak(_ index: Int) -> String
}

@MainActor
public final class DiffsEditor<Annotation: EditorLineAnnotationPosition>: GridEditorClient, EditorLineSource {
    public var options: DiffsEditorOptions
    public var onChange: ((DiffsEditorChangeEvent) -> Void)?
    public var onFocus: (() -> Void)?
    public var onBlur: (() -> Void)?
    /// Renders a floating view after a user-created selection
    /// (`renderSelectionAction` with `enabledSelectionAction`).
    public var renderSelectionAction: ((DiffsSelectionActionContext) -> NSView?)?

    public private(set) var document: TextDocument<Annotation>?
    public private(set) var selections: [EditorSelection] = []
    public private(set) var markers: [Marker] = []

    private weak var host: (any EditorHost)?
    private var tokenizer: EditorTokenizer<Annotation>?
    private var highlighter: DiffsHighlighter?
    private var fileInfo = FileContents(name: "", contents: "")
    private var lineAnnotations: [Annotation]?
    private var lineStore: [LineSlot] = []
    private var bracketMatch: (open: DocumentRange, close: DocumentRange)?
    private var searchMatches: [(start: Int, end: Int)] = []
    private var markedText: (text: String, range: DocumentRange)?
    private var dragAnchor: EditorSelection?
    private var columnDrag: (anchor: Position, startX: CGFloat)?
    private var reservedSelections: [EditorSelection]?
    private var carets: [(caret: DiffsEditorCaret, anchorOffset: Int, focusOffset: Int)] = []
    private var markerPopover: EditorPopoverView?
    private var markerPopoverIndex: Int?
    private var pendingMarkerIndex: Int?
    private var markerShowWork: DispatchWorkItem?
    private var selectionActionView: EditorPopoverView?
    private var canMountSelectionAction = false
    private var predictionHistory: [EditPredictionHistoryRecord] = []
    private var prediction: (version: Int, cursorOffset: Int, edits: [ResolvedTextEdit], response: EditPredictResponse)?
    private var predictionTask: Task<Void, Never>?
    private var predictionGeneration = 0
    private var predictionPreview: EditorPopoverView?
    private var predictionRevealed = false
    private var compiledKeymap: CompiledEditorKeymap?

    private enum LineSlot {
        /// The host's original highlighted line at this index.
        case original(Int)
        /// Re-tokenized (or pending) content.
        case edited(HighlightedLine?)
    }

    /// Retains and resumes edit state under this key (`editStateKey`).
    public let editStateKey: String?
    /// Observes completion events (`onComplete`).
    public var onComplete: ((Any) -> Void)?

    public init(options: DiffsEditorOptions = DiffsEditorOptions(), editStateKey: String? = nil) {
        self.options = options
        self.editStateKey = editStateKey
        compiledKeymap = options.keymap.map(CompiledEditorKeymap.init)
    }

    // MARK: - Attaching

    /// Starts editing a file view (`editor.edit(fileInstance)`); returns a
    /// function that detaches.
    @discardableResult
    public func edit<Metadata>(_ view: FileView<Metadata>) -> () -> Void where Annotation == LineAnnotation<Metadata> {
        attach(view, annotations: view.lineAnnotations)
        // Like upstream, the returned disposer completes the session.
        return { [weak self] in self?.cleanUp(.complete) }
    }

    /// Ends the session, offering the result to the view's `onEditComplete`.
    public func complete() {
        cleanUp(.complete)
    }

    /// Starts editing the new side of a diff view.
    @discardableResult
    public func edit<Metadata>(_ view: FileDiffView<Metadata>) -> () -> Void where Annotation == DiffLineAnnotation<Metadata> {
        attach(view, annotations: view.lineAnnotations)
        // Like upstream, the returned disposer completes the session.
        return { [weak self] in self?.cleanUp(.complete) }
    }

    func attach(_ host: any EditorHost, annotations: [Annotation]?) {
        cleanUp()
        guard let file = host.editorFile else { return }
        self.host = host
        fileInfo = FileContents(name: file.name, contents: "", lang: file.lang)
        let lang = file.lang ?? getFiletypeFromFileName(file.name)
        var restoredSelections: [EditorSelection]?
        let document: TextDocument<Annotation>
        if let key = editStateKey, let entry = DiffsEditStateStore.shared.take(key), let retained = entry.document as? TextDocument<Annotation>, entry.fileName == file.name {
            // Resume the retained document and history.
            document = retained
            restoredSelections = entry.selections
        } else {
            document = TextDocument<Annotation>(uri: file.name, text: file.contents, languageId: lang, editStack: EditStack(maxEntries: options.historyMaxEntries))
        }
        self.document = document
        lineAnnotations = annotations
        lineStore = (0 ..< document.lineCount).map { .original($0) }
        let highlighter = DiffsHighlighter()
        try? highlighter.prepare(langs: [lang], themes: [host.editorTheme.name])
        self.highlighter = highlighter
        let tokenizer = EditorTokenizer(highlighter: highlighter, document: document, themeName: host.editorTheme.name, themeType: host.editorTheme.kind, matchBrackets: options.matchBrackets)
        tokenizer.onDeferTokenize = { [weak self] lines, _ in
            MainActor.assumeIsolated { self?.applyTokens(lines) }
        }
        self.tokenizer = tokenizer
        let caret = Position(line: 0, character: 0)
        selections = restoredSelections ?? [EditorSelection(caret: caret)]
        host.editorAttach(self)
        if restoredSelections != nil {
            // The retained document differs from the view's input.
            lineStore = (0 ..< document.lineCount).map { _ in .edited(nil) }
            applyTokens(tokenizer.tokenizeLines(0 ..< document.lineCount))
            host.editorDocumentChanged(nil)
        }
        host.editorGrid.editorClient = self
        host.editorGrid.rebuildEditorLineRows()
        tokenizer.prebuildStateStack()
    }

    /// Ends editing (`cleanUp(reason)`).
    public func cleanUp(_ reason: DiffsEditorCleanupReason = .discard) {
        tokenizer?.cleanUp()
        tokenizer = nil
        if let key = editStateKey, let document, reason != .complete {
            DiffsEditStateStore.shared.store(key, .init(document: document, selections: selections, fileName: fileInfo.name))
        } else if let key = editStateKey {
            DiffsEditStateStore.shared.release(key)
        }
        if let host {
            host.editorGrid.editorClient = nil
            switch reason {
            case .complete:
                host.editorDetach(result: .complete(text: document?.getText() ?? "", annotations: lineAnnotations), editor: self)
            case .discard, .recycle:
                host.editorDetach(result: .discard, editor: self)
            }
        }
        host = nil
        document = nil
        selections = []
        lineStore = []
        bracketMatch = nil
        searchMatches = []
        searchPanel?.removeFromSuperview()
        searchPanel = nil
        markedText = nil
        removeMarkerPopover()
        closeSelectionAction()
        cancelPrediction()
        predictionHistory = []
        carets = []
    }

    // MARK: - Public API

    public var canUndo: Bool { document?.canUndo ?? false }
    public var canRedo: Bool { document?.canRedo ?? false }

    public func getText() -> String {
        document?.getText() ?? ""
    }

    /// The edited file (`getFile`).
    public func getFile() -> FileContents? {
        guard let document else { return nil }
        return FileContents(name: fileInfo.name, contents: document.getText(), lang: fileInfo.lang)
    }

    public func undo() { applyHistory(undo: true) }
    public func redo() { applyHistory(undo: false) }

    /// Applies edits (`editor.applyEdits`), remapping selections.
    public func applyEdits(_ edits: [TextEdit], updateHistory: Bool = true) throws {
        guard let document else { return }
        let offsets = selections.map { (document.offsetAt($0.start), document.offsetAt($0.end)) }
        let resolved = document.resolveEdits(edits).sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        guard let change = try document.applyEdits(edits, updateHistory: updateHistory) else { return }
        let next = remapSelectionsAfterEdits(document, selections, offsets, resolved)
        applyChange(change, next, annotations: applyChangeToLineAnnotations(change))
    }

    public func setSelections(_ selections: [EditorSelection]) {
        guard let document else { return }
        updateSelections(selections.map {
            EditorSelection(start: document.normalizePosition($0.start), end: document.normalizePosition($0.end), direction: $0.direction)
        })
    }

    /// Shows externally owned carets (`setCarets`); they follow edits.
    public func setCarets(_ carets: [DiffsEditorCaret]) {
        guard let document else { return }
        self.carets = carets.map { caret in
            (caret, document.offsetAt(caret.anchor), document.offsetAt(caret.focus))
        }
        host?.editorGrid.needsDisplay = true
    }

    public func setMarkers(_ markers: [Marker]) {
        guard let document else { return }
        self.markers = markers.map {
            var marker = $0
            marker.start = document.normalizePosition(marker.start)
            marker.end = document.normalizePosition(marker.end)
            return marker
        }
        host?.editorGrid.needsDisplay = true
    }

    /// Focuses the editor, optionally placing the caret (`focus`).
    public func focus(line: Int? = nil, character: Int = 0) {
        guard let host else { return }
        if let line, let document {
            let position = document.normalizePosition(Position(line: line, character: character))
            host.editorRevealLine(position.line)
            updateSelections([EditorSelection(caret: position)])
        }
        host.editorGrid.window?.makeFirstResponder(host.editorGrid)
        host.editorGrid.scrollEditorCaretToVisible()
    }

    public func blur() {
        guard let grid = host?.editorGrid, grid.window?.firstResponder === grid else { return }
        grid.window?.makeFirstResponder(nil)
    }

    // MARK: - Lines (EditorLineSource)

    var lineCount: Int { document?.lineCount ?? 0 }

    func lineText(_ index: Int) -> String {
        document?.getLineText(index) ?? ""
    }

    func lineTextWithBreak(_ index: Int) -> String {
        document?.getLineText(index, includeLineBreak: true) ?? ""
    }

    func highlightedLine(_ index: Int) -> HighlightedLine {
        guard index >= 0, index < lineStore.count else { return HighlightedLine(text: "", tokens: []) }
        switch lineStore[index] {
        case .original(let original):
            return host?.editorOriginalLine(original) ?? HighlightedLine(text: lineText(index), tokens: [])
        case .edited(let line?):
            return line
        case .edited(nil):
            return HighlightedLine.plain(lineText(index), slots: slotCount)
        }
    }

    private var slotCount: Int {
        guard let host else { return 1 }
        return host.editorGrid.style.theme.slots.count
    }

    private func makeLine(_ tokens: [EditorLineToken], text: String) -> HighlightedLine {
        let slots = slotCount
        var highlighted: [HighlightedToken] = []
        let length = text.utf16.count
        for (index, token) in tokens.enumerated() {
            let start = token.offset
            let end = index + 1 < tokens.count ? tokens[index + 1].offset : start + token.text.utf16.count
            guard start < end, start < length else { continue }
            let style = TokenStyle(color: token.color.isEmpty ? nil : token.color)
            highlighted.append(HighlightedToken(start: start, end: min(end, length), styles: Array(repeating: style, count: slots)))
        }
        return HighlightedLine(text: text, tokens: highlighted)
    }

    private func applyTokens(_ lines: [Int: [EditorLineToken]]) {
        guard !lines.isEmpty else { return }
        for (line, tokens) in lines where line < lineStore.count {
            lineStore[line] = .edited(makeLine(tokens, text: lineText(line)))
        }
        host?.editorGrid.invalidateLines(side: .additions, lineIndexes: lines.keys)
    }

    // MARK: - Changes

    private func applyChangeToLineAnnotations(_ change: TextDocumentChange) -> [Annotation]? {
        guard let lineAnnotations else { return nil }
        return applyDocumentChangeToLineAnnotations(change, lineAnnotations)
    }

    /// Updates line slots, tokens, selections and the view after a change
    /// (`#applyChange`).
    private func applyChange(_ change: TextDocumentChange, _ nextSelections: [EditorSelection]?, annotations: [Annotation]?, refreshSearch shouldRefreshSearch: Bool = true, source: EditPredictionSource = .user) {
        guard let document, let host else { return }
        cancelPrediction()
        // Splice line slots: each per-edit range replaces the old lines it
        // covered with fresh (pending) lines.
        for lineChange in change.changedLineChanges {
            let newCount = lineChange.endLine - lineChange.startLine + 1
            let oldCount = newCount - lineChange.lineDelta
            let start = min(lineChange.startLine, lineStore.count)
            let end = min(start + max(0, oldCount), lineStore.count)
            lineStore.replaceSubrange(start ..< end, with: Array(repeating: LineSlot.edited(nil), count: max(0, newCount)))
        }
        if lineStore.count != document.lineCount {
            // Defensive resync (should not happen).
            if lineStore.count < document.lineCount {
                lineStore.append(contentsOf: Array(repeating: LineSlot.edited(nil), count: document.lineCount - lineStore.count))
            } else {
                lineStore.removeLast(lineStore.count - document.lineCount)
            }
        }
        if let annotations {
            lineAnnotations = annotations
            host.editorApplyAnnotations(annotations)
        }
        for index in carets.indices {
            let anchor = remapOffsetThroughEdits(carets[index].anchorOffset, change.changes.map { ResolvedTextEdit(start: $0.start, end: $0.end, text: $0.text) })
            let focus = remapOffsetThroughEdits(carets[index].focusOffset, change.changes.map { ResolvedTextEdit(start: $0.start, end: $0.end, text: $0.text) })
            carets[index].anchorOffset = anchor
            carets[index].focusOffset = focus
            carets[index].caret.anchor = document.positionAt(anchor)
            carets[index].caret.focus = document.positionAt(focus)
        }
        removeMarkerPopover()
        closeSelectionAction()
        if let dirty = try? tokenizer?.tokenize(change) {
            for (line, tokens) in dirty where line < lineStore.count {
                lineStore[line] = .edited(makeLine(tokens, text: lineText(line)))
            }
        }
        if let nextSelections { selections = nextSelections }
        markedText = nil
        host.editorDocumentChanged(change)
        let invalidateFrom = change.startLine
        host.editorGrid.invalidateLines(side: .additions, lineIndexes: invalidateFrom ..< max(invalidateFrom, document.lineCount))
        if shouldRefreshSearch { refreshSearch() }
        updateBracketMatch()
        host.editorGrid.scrollEditorCaretToVisible()
        host.editorGrid.restartCaretBlink()
        host.editorGrid.needsDisplay = true
        if let file = getFile() {
            onChange?(DiffsEditorChangeEvent(changes: change.changes, file: file))
        }
        recordPredictionHistory(change, source: source)
        if source == .user { schedulePrediction() }
    }

    // MARK: - Edit prediction

    private func includesPredictionPath(_ path: String) -> Bool {
        guard let options = options.editPrediction else { return false }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let included = options.include?.contains { matchesEditPredictionPattern(normalized, $0) } ?? true
        let excluded = options.exclude?.contains { matchesEditPredictionPattern(normalized, $0) } ?? false
        return included && !excluded
    }

    private func recordPredictionHistory(_ change: TextDocumentChange, source: EditPredictionSource) {
        guard let document, options.editPrediction != nil, includesPredictionPath(fileInfo.name) else { return }
        predictionHistory = recordEditPrediction(predictionHistory, path: fileInfo.name, document: document, change: change, source: source)
    }

    private func cancelPrediction() {
        predictionTask?.cancel()
        predictionTask = nil
        predictionGeneration += 1
        prediction = nil
        predictionRevealed = false
        predictionPreview?.removeFromSuperview()
        predictionPreview = nil
        host?.editorGrid.needsDisplay = true
    }

    /// Debounced request to the provider (`#scheduleEditPrediction`).
    private func schedulePrediction() {
        cancelPrediction()
        guard let options = options.editPrediction, let document, selections.count == 1, let selection = selections.first, selection.isCollapsed,
              includesPredictionPath(fileInfo.name)
        else { return }
        let cursorOffset = document.offsetAt(selection.focus)
        let generation = predictionGeneration
        let path = fileInfo.name
        predictionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self, self.predictionGeneration == generation, let document = self.document else { return }
            guard let request = buildEditPredictionRequest(
                path: path,
                document: document,
                cursorOffset: cursorOffset,
                history: self.predictionHistory,
                isLineEditable: { [weak self] line in self?.host?.editorGrid.editorLocation(ofLine: line) != nil }
            ) else { return }
            let response: EditPredictResponse
            do {
                response = try await options.provider.predict(request)
            } catch {
                return
            }
            guard !Task.isCancelled, self.predictionGeneration == generation else { return }
            self.acceptResponse(response, request: request, cursorOffset: cursorOffset)
        }
    }

    /// Validates a response (`#scheduleEditPrediction` response checks).
    private func acceptResponse(_ response: EditPredictResponse, request: EditPredictRequest, cursorOffset: Int) {
        guard let document, document.version == request.version, selections.count == 1, let selection = selections.first,
              selection.isCollapsed, document.offsetAt(selection.focus) == cursorOffset,
              !response.edits.isEmpty, response.edits.count <= 256
        else { return }
        let excerptStart = document.offsetAt(Position(line: request.excerptStartLine, character: 0))
        let editableStart = excerptStart + request.editableRange.start
        let editableEnd = excerptStart + request.editableRange.end
        var bytes = 0
        var resolved: [ResolvedTextEdit] = []
        for edit in response.edits {
            guard isValidPredictionPosition(edit.range.start), isValidPredictionPosition(edit.range.end), edit.range.start <= edit.range.end else { return }
            bytes += edit.newText.utf8.count
            if bytes > 128 * 1024 { return }
            let start = document.offsetAt(edit.range.start)
            let end = document.offsetAt(edit.range.end)
            let resolvedEdit = document.resolveEdits([edit])[0]
            guard resolvedEdit.start == start, resolvedEdit.end == end else { return }
            resolved.append(resolvedEdit)
        }
        resolved.sort { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        for (index, edit) in resolved.enumerated() {
            if edit.start < editableStart || edit.end > editableEnd || (index > 0 && resolved[index - 1].end > edit.start) { return }
        }
        let edits = resolved.filter { !$0.text.utf16.elementsEqual(document.getTextSlice($0.start, $0.end).utf16) }
        guard !edits.isEmpty, response.newCursor.line >= 0, response.newCursor.character >= 0 else { return }
        prediction = (document.version, cursorOffset, edits, response)
        predictionRevealed = options.editPrediction?.mode == .eager
        renderPrediction()
    }

    private func isValidPredictionPosition(_ position: Position) -> Bool {
        guard let document, position.line >= 0, position.line < document.lineCount, position.character >= 0 else { return false }
        return position.character <= document.getLineLength(position.line)
    }

    var editorGhostText: [(position: Position, text: String)] {
        guard predictionRevealed, let prediction, let document, predictionPreview == nil else { return [] }
        return prediction.edits.compactMap { edit in
            guard edit.start == edit.end, !edit.text.contains("\n"), !edit.text.contains("\r") else { return nil }
            let position = document.positionAt(edit.start)
            return position.character == document.getLineLength(position.line) ? (position, edit.text) : nil
        }
    }

    /// Shows the prediction: inline ghost text when it is a line-end
    /// insertion, otherwise a preview of the predicted lines.
    private func renderPrediction() {
        predictionPreview?.removeFromSuperview()
        predictionPreview = nil
        guard predictionRevealed, let prediction, let document, let host else {
            host?.editorGrid.needsDisplay = true
            return
        }
        let inlineOnly = prediction.edits.allSatisfy { edit in
            let position = document.positionAt(edit.start)
            return edit.start == edit.end && !edit.text.contains("\n") && !edit.text.contains("\r") && position.character == document.getLineLength(position.line)
        }
        if !inlineOnly {
            let first = document.positionAt(prediction.edits[0].start)
            let last = document.positionAt(prediction.edits[prediction.edits.count - 1].end)
            let affectedStart = document.offsetAt(Position(line: first.line, character: 0))
            let affectedEnd = document.offsetAt(Position(line: last.line, character: document.getLineLength(last.line)))
            var predicted = ""
            var consumed = affectedStart
            for edit in prediction.edits {
                predicted += document.getTextSlice(consumed, edit.start) + edit.text
                consumed = edit.end
            }
            predicted += document.getTextSlice(consumed, affectedEnd)
            let label = NSTextField(labelWithString: predicted)
            label.font = host.editorGrid.style.regularFont
            label.textColor = NSColor.labelColor.withAlphaComponent(0.7)
            let hint = NSTextField(labelWithString: "Tab to accept, Esc to dismiss")
            hint.font = .systemFont(ofSize: 10)
            hint.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [label, hint])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            if let anchor = host.editorGrid.editorCaretRect(last) {
                let popover = EditorPopoverView(content: stack)
                let container = host.editorOverlayContainer
                popover.place(in: container, anchor: host.editorGrid.convert(anchor, to: container), maxWidth: 640, preferAbove: false)
                container.addSubview(popover)
                predictionPreview = popover
            }
        }
        host.editorGrid.needsDisplay = true
    }

    private var predictionOverlays: [GridEditorOverlay] {
        guard predictionRevealed, let prediction, let document else { return [] }
        return prediction.edits.filter { $0.end > $0.start }.map {
            GridEditorOverlay(range: DocumentRange(start: document.positionAt($0.start), end: document.positionAt($0.end)), kind: .predictionDeletion)
        }
    }

    /// Applies the prediction (`#acceptEditPrediction`).
    private func acceptPrediction() -> Bool {
        guard predictionRevealed, let prediction, let document, document.version == prediction.version,
              selections.count == 1, let selection = selections.first, selection.isCollapsed,
              document.offsetAt(selection.focus) == prediction.cursorOffset
        else { return false }
        cancelPrediction()
        guard let change = try? document.applyResolvedEdits(prediction.edits, selectionsBefore: selections, undoBoundary: true) else { return true }
        let cursor = document.normalizePosition(prediction.response.newCursor)
        let next = [EditorSelection(caret: cursor)]
        document.setLastUndoSelectionsAfter(next)
        applyChange(change, next, annotations: applyChangeToLineAnnotations(change), source: .prediction)
        return true
    }

    /// Subtle mode shows predictions while Alt is held.
    func editorModifiersChanged(_ flags: NSEvent.ModifierFlags) {
        guard options.editPrediction?.mode == .subtle, prediction != nil else { return }
        let reveal = flags.contains(.option)
        if reveal != predictionRevealed {
            predictionRevealed = reveal
            renderPrediction()
        }
    }

    private func updateSelections(_ next: [EditorSelection]) {
        if prediction != nil, next != selections { cancelPrediction() }
        selections = next
        updateBracketMatch()
        host?.editorGrid.restartCaretBlink()
        host?.editorGrid.needsDisplay = true
    }

    private func updateBracketMatch() {
        guard options.matchBrackets, let document, let tokenizer, let primary = selections.last, primary.isCollapsed else {
            bracketMatch = nil
            return
        }
        bracketMatch = findBracketMatchRanges(document, tokenizer, primary.focus)
    }

    private func applyHistory(undo: Bool) {
        guard let document else { return }
        if undo ? !document.canUndo : !document.canRedo { return }
        let offsets = selections.map { (document.offsetAt($0.start), document.offsetAt($0.end)) }
        guard let result = undo ? document.undo() : document.redo() else { return }
        let next = result.selections ?? result.selectionEdits.map { remapSelectionsAfterEdits(document, selections, offsets, $0) }
        let annotations = result.lineAnnotations ?? lineAnnotations.flatMap { applyDocumentChangeToLineAnnotations(result.change, $0) }
        applyChange(result.change, next, annotations: annotations)
    }

    private func replaceSelectionText(_ text: [String], undoBoundary: Bool = false, documentOrder: Bool = false) {
        guard let document, let primary = selections.last else { return }
        let result: AnnotatedSelectionEditResult<Annotation>?
        if text.count == selections.count, text.count > 1 || documentOrder {
            result = try? applyTextReplaceToSelections(document, selections, text, lineAnnotations: lineAnnotations, undoBoundary: undoBoundary, documentOrder: documentOrder)
        } else {
            let edit = ResolvedTextEdit(start: document.offsetAt(primary.start), end: document.offsetAt(primary.end), text: text.joined(separator: document.eol.rawValue))
            result = try? applyTextChangeToSelections(document, selections, edit, lineAnnotations: lineAnnotations, tabSize: tabSize, undoBoundary: undoBoundary)
        }
        guard let result, let change = result.change else { return }
        applyChange(change, result.nextSelections, annotations: result.lineAnnotations)
    }

    private func perform(_ operation: (TextDocument<Annotation>, [EditorSelection], [Annotation]?) throws -> AnnotatedSelectionEditResult<Annotation>) {
        guard let document, !selections.isEmpty else { return }
        guard let result = try? operation(document, selections, lineAnnotations), let change = result.change else { return }
        applyChange(change, result.nextSelections, annotations: result.lineAnnotations)
    }

    private var tabSize: Int { host?.editorTabSize ?? 2 }

    /// One undoable command batch (`#applyCommandEdits`).
    private func applyCommandEdits(_ edits: [TextEdit], nextSelections resolve: ((TextDocument<Annotation>) -> [EditorSelection])? = nil) {
        guard let document, !edits.isEmpty else { return }
        let offsets = selections.map { (document.offsetAt($0.start), document.offsetAt($0.end)) }
        let resolved = edits.map { edit -> ResolvedTextEdit in
            let start = document.offsetAt(edit.range.start)
            let end = document.offsetAt(edit.range.end)
            return ResolvedTextEdit(start: min(start, end), end: max(start, end), text: edit.newText)
        }.sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        guard let change = try? document.applyEdits(edits, selectionsBefore: selections, undoBoundary: true) else { return }
        let next = resolve?(document) ?? remapSelectionsAfterEdits(document, selections, offsets, resolved)
        document.setLastUndoSelectionsAfter(next)
        applyChange(change, next, annotations: applyChangeToLineAnnotations(change))
    }

    // MARK: - Commands

    private func runCommand(_ command: EditorCommand) {
        guard let document else { return }
        switch command {
        case .openSearchPanel, .openSearchReplacePanel:
            openSearchPanel(command == .openSearchReplacePanel ? .replace : .find)
        case .findNextMatch:
            if selections.contains(where: \.isCollapsed) {
                updateSelections(selections.map { $0.isCollapsed ? expandCollapsedSelectionToWord(document, $0) : $0 })
            } else if let next = findNextMatch(document, selections) {
                if let primary = next.last { host?.editorRevealLine(primary.focus.line) }
                updateSelections(next)
                host?.editorGrid.scrollEditorCaretToVisible()
            }
        case .moveLineUp, .moveLineDown:
            moveSelectedLines(command == .moveLineUp ? -1 : 1)
        case .copyLineUp, .copyLineDown:
            copySelectedLines(command == .copyLineUp ? -1 : 1)
        case .simplifySelection:
            searchPanel?.closePanel()
            guard let primary = selections.last else { break }
            if selections.count > 1 {
                updateSelections([primary])
            } else if !primary.isCollapsed {
                updateSelections([EditorSelection(caret: primary.focus)])
            }
        case .insertBlankLine:
            insertBlankLine()
        case .deleteHardLineForward:
            perform { try applyDeleteHardLineForwardToSelections($0, $1, lineAnnotations: $2) }
        case .toggleComment, .toggleBlockComment:
            let config = resolveCommentConfig(document.languageId, overrides: options.languageCommentConfig)
            if command == .toggleComment, let token = config.lineComment {
                applyCommandEdits(resolveLineCommentEdits(document, selections, token: token))
                break
            }
            let linewise = command == .toggleComment
            if let result = resolveBlockCommentEdits(document, selections, open: config.blockComment.open, close: config.blockComment.close, linewise: linewise) {
                applyCommandEdits(result.edits, nextSelections: linewise ? nil : { document in
                    result.nextSelectionOffsets.map {
                        EditorSelection(start: document.positionAt($0.start), end: document.positionAt($0.end), direction: $0.direction)
                    }
                })
            }
        case .indent, .outdent, .indentLess, .indentMore:
            indent(command)
        case .selectAll:
            updateSelections([getDocumentFullSelection(document)])
        case .moveCursorToDocStart, .moveCursorToDocEnd:
            let boundary = getDocumentBoundarySelection(document, atEnd: command == .moveCursorToDocEnd)
            host?.editorRevealLine(boundary.focus.line)
            updateSelections([boundary])
            host?.editorGrid.scrollEditorCaretToVisible()
        case .expandSelectionDocStart, .expandSelectionDocEnd:
            let boundary = getDocumentBoundarySelection(document, atEnd: command == .expandSelectionDocEnd)
            host?.editorRevealLine(boundary.focus.line)
            updateSelections(extendSelections(selections, boundary))
            host?.editorGrid.scrollEditorCaretToVisible()
        case .undo:
            undo()
        case .redo:
            redo()
        }
    }


    private func indent(_ command: EditorCommand) {
        guard let document else { return }
        var edits: [TextEdit] = []
        var nextSelections: [EditorSelection] = []
        var editedLines = Set<Int>()
        var sameLine: [(line: Int, startCharacter: Int, addedLength: Int, index: Int)] = []
        let outdent = command == .outdent || command == .indentLess
        let lineBased = command == .indentLess || command == .indentMore
        for selection in selections {
            if selection.start.line != selection.end.line || outdent || lineBased {
                let result = resolveIndentEdits(document, selection, tabSize: tabSize, outdent: outdent)
                for edit in result.edits where !editedLines.contains(edit.range.start.line) {
                    editedLines.insert(edit.range.start.line)
                    edits.append(edit)
                }
                nextSelections.append(result.nextSelection)
            } else {
                let text = document.charAt(Position(line: selection.start.line, character: 0)) == "\t" ? "\t" : String(repeating: " ", count: tabSize)
                edits.append(TextEdit(range: selection.range, newText: text))
                sameLine.append((selection.start.line, selection.start.character, text.utf16.count - (selection.end.character - selection.start.character), nextSelections.count))
                let position = Position(line: selection.start.line, character: selection.start.character + text.utf16.count)
                nextSelections.append(EditorSelection(caret: position))
            }
        }
        for entry in sameLine {
            let shift = sameLine.filter { $0.line == entry.line && $0.startCharacter < entry.startCharacter }.reduce(0) { $0 + $1.addedLength }
            if shift != 0 {
                let current = nextSelections[entry.index]
                nextSelections[entry.index] = EditorSelection(caret: Position(line: entry.line, character: current.start.character + shift))
            }
        }
        guard let change = try? document.applyEdits(edits, selectionsBefore: selections, selectionsAfter: nextSelections) else { return }
        applyChange(change, nextSelections, annotations: applyChangeToLineAnnotations(change))
    }

    private func insertBlankLine() {
        guard let document else { return }
        let caretLines = selections.map { $0.focus.line }
        let targets = Array(Set(caretLines)).sorted()
        var targetIndex: [Int: Int] = [:]
        var indents: [Int: String] = [:]
        var edits: [TextEdit] = []
        for (index, line) in targets.enumerated() {
            let units = document.getLineUnits(line)
            var indentLength = 0
            while indentLength < units.count, let scalar = Unicode.Scalar(units[indentLength]), scalar.properties.isWhitespace { indentLength += 1 }
            let indent = String(decoding: units[0 ..< indentLength], as: UTF16.self)
            targetIndex[line] = index
            indents[line] = indent
            let position = Position(line: line, character: document.getLineLength(line))
            edits.append(TextEdit(range: DocumentRange(start: position, end: position), newText: document.eol.rawValue + indent))
        }
        let next = caretLines.map { line in
            EditorSelection(caret: Position(line: line + 1 + targetIndex[line]!, character: indents[line]!.utf16.count))
        }
        applyCommandEdits(edits, nextSelections: { _ in next })
    }

    private func moveSelectedLines(_ direction: Int) {
        guard let document else { return }
        let blocks = getSelectedLineBlocks(selections)
        guard let first = blocks.first, let last = blocks.last,
              !(direction < 0 && first.startLine == 0), !(direction > 0 && last.endLine >= document.lineCount - 1)
        else { return }
        let lineCount = document.lineCount
        func lineRangeEnd(_ line: Int) -> Position {
            line < lineCount - 1 ? Position(line: line + 1, character: 0) : Position(line: line, character: document.getLineLength(line))
        }
        func linesText(_ lines: [Int], _ appendBreak: Bool) -> String {
            let text = lines.map { document.getLineText($0) }.joined(separator: document.eol.rawValue)
            return appendBreak ? text + document.eol.rawValue : text
        }
        var edits: [TextEdit] = []
        if direction < 0 {
            for block in blocks {
                let previous = block.startLine - 1
                edits.append(TextEdit(
                    range: DocumentRange(start: Position(line: previous, character: 0), end: lineRangeEnd(block.endLine)),
                    newText: linesText(Array(block.startLine ... block.endLine) + [previous], block.endLine < lineCount - 1)
                ))
            }
        } else {
            for block in blocks.reversed() {
                let next = block.endLine + 1
                edits.append(TextEdit(
                    range: DocumentRange(start: Position(line: block.startLine, character: 0), end: lineRangeEnd(next)),
                    newText: linesText([next] + Array(block.startLine ... block.endLine), next < lineCount - 1)
                ))
            }
        }
        let lastLineLengthAfterMove = direction > 0 && last.endLine == lineCount - 2
            ? document.getLineLength(last.endLine)
            : document.getLineLength(lineCount - 1)
        let next = selections.map { selection in
            shiftSelectionLines(selection, direction: direction, lineCount: lineCount) { line in
                line == lineCount - 1 ? lastLineLengthAfterMove : document.getLineLength(line)
            }
        }
        applyCommandEdits(edits, nextSelections: { _ in next })
    }

    private func copySelectedLines(_ direction: Int) {
        guard let document else { return }
        let blocks = getSelectedLineBlocks(selections)
        guard !blocks.isEmpty else { return }
        var edits: [TextEdit] = []
        var copiedBefore: [Int] = []
        var copied = 0
        for block in blocks {
            copiedBefore.append(copied)
            copied += block.endLine - block.startLine + 1
            let text = document.getText(DocumentRange(start: Position(line: block.startLine, character: 0), end: Position(line: block.endLine, character: document.getLineLength(block.endLine))))
            let position = Position(line: block.endLine, character: document.getLineLength(block.endLine))
            edits.append(TextEdit(range: DocumentRange(start: position, end: position), newText: document.eol.rawValue + text))
        }
        let next = selections.map { selection -> EditorSelection in
            let blockIndex = blocks.lastIndex { $0.startLine <= selection.start.line } ?? 0
            let block = blocks[blockIndex]
            let offset = copiedBefore[blockIndex] + (direction > 0 ? block.endLine - block.startLine + 1 : 0)
            return EditorSelection(
                start: Position(line: selection.start.line + offset, character: selection.start.character),
                end: Position(line: selection.end.line + offset, character: selection.end.character),
                direction: selection.direction
            )
        }
        applyCommandEdits(edits, nextSelections: { _ in next })
    }

    // MARK: - Search

    private var searchPanel: EditorSearchPanel?

    /// Opens (or switches the mode of) the find panel (`#openSearchPanel`).
    private func openSearchPanel(_ mode: EditorSearchPanel.Mode) {
        guard let document, let host else { return }
        if let searchPanel {
            searchPanel.applyMode(mode)
            searchPanel.focusSearchField()
            return
        }
        var defaultQuery = ""
        if var primary = selections.last {
            if primary.isCollapsed {
                primary = expandCollapsedSelectionToWord(document, primary)
                updateSelections(Array(selections.dropLast()) + [primary])
            }
            let text = document.getText(primary.range)
            if !text.isEmpty, !text.contains("\n") { defaultQuery = text }
        }
        let hooks = EditorSearchHooks(
            search: { [weak self] params in self?.document?.search(params) ?? [] },
            scrollToMatch: { [weak self] match, _ in self?.scrollToSearchMatch(match) },
            applyReplace: { [weak self] edits in self?.applySearchReplace(edits) },
            replacementText: { [weak self] params, start, end in
                guard let document = self?.document else { return params.replaceText }
                return buildSearchReplacementText(
                    positionAt: { document.positionAt($0) },
                    offsetAt: { document.offsetAt($0) },
                    getLineText: { document.getLineText($0) },
                    searchParams: params,
                    matchStart: start,
                    matchEnd: end
                )
            },
            onUpdate: { [weak self] matches, sync in self?.searchPanelDidUpdate(matches, syncSelection: sync) },
            onClose: { [weak self] in
                guard let self else { return }
                self.searchPanel = nil
                self.searchMatches = []
                self.host?.editorGrid.needsDisplay = true
                self.host?.editorGrid.window?.makeFirstResponder(self.host?.editorGrid)
            }
        )
        let panel = EditorSearchPanel(defaultQuery: defaultQuery, mode: mode, hooks: hooks)
        let container = host.editorOverlayContainer
        let width = min(EditorSearchPanel.width, container.bounds.width - 24)
        panel.frame = CGRect(x: container.bounds.width - width - 12, y: host.editorOverlayTop + 6, width: width, height: panel.preferredHeight)
        panel.autoresizingMask = [.minXMargin]
        container.addSubview(panel)
        searchPanel = panel
        panel.focusSearchField()
    }

    private func scrollToSearchMatch(_ match: (start: Int, end: Int)) {
        guard let document else { return }
        let selection = createSelectionFromAnchorAndFocusOffsets(document, match.start, match.end)
        host?.editorRevealLine(selection.focus.line)
        updateSelections([selection])
        host?.editorGrid.scrollEditorCaretToVisible()
    }

    private func applySearchReplace(_ edits: [ResolvedTextEdit]) {
        guard let document, !edits.isEmpty else { return }
        let textEdits = edits.map { TextEdit(range: DocumentRange(start: document.positionAt($0.start), end: document.positionAt($0.end)), newText: $0.text) }
        guard let change = try? document.applyEdits(textEdits, selectionsBefore: selections) else { return }
        applyChange(change, nil, annotations: applyChangeToLineAnnotations(change), refreshSearch: false)
    }

    /// Records matches and resolves the current one (`onUpdate`).
    private func searchPanelDidUpdate(_ matches: [(start: Int, end: Int)], syncSelection: Bool) -> (start: Int, end: Int)? {
        guard let document else { return nil }
        searchMatches = matches
        host?.editorGrid.needsDisplay = true
        if matches.isEmpty { return nil }
        let primary = selections.last
        if !syncSelection {
            guard let primary else { return nil }
            let start = document.offsetAt(primary.start)
            let end = document.offsetAt(primary.end)
            return matches.first { $0.start == start && $0.end == end }
        }
        let offset = primary.map { document.offsetAt($0.start) } ?? 0
        guard let next = matches.first(where: { $0.start >= offset }) else { return nil }
        scrollToSearchMatch(next)
        return next
    }

    private func refreshSearch() {
        searchPanel?.updateMatches(syncSelection: false)
    }

    // MARK: - GridEditorClient

    var editorSide: AnnotationSide { .additions }
    var editorSelections: [EditorSelection] { selections }
    var editorMarkedText: (text: String, range: DocumentRange)? { markedText }

    var editorOverlays: [GridEditorOverlay] {
        var overlays: [GridEditorOverlay] = []
        if let document {
            for match in searchMatches {
                overlays.append(GridEditorOverlay(
                    range: DocumentRange(start: document.positionAt(match.start), end: document.positionAt(match.end)),
                    kind: .searchMatch
                ))
            }
        }
        if let bracketMatch {
            overlays.append(GridEditorOverlay(range: bracketMatch.open, kind: .bracketMatch))
            overlays.append(GridEditorOverlay(range: bracketMatch.close, kind: .bracketMatch))
        }
        for marker in markers {
            overlays.append(GridEditorOverlay(range: marker.range, kind: .marker(marker.severity)))
        }
        overlays.append(contentsOf: predictionOverlays)
        for entry in carets where entry.caret.anchor != entry.caret.focus {
            let start = min(entry.caret.anchor, entry.caret.focus)
            let end = max(entry.caret.anchor, entry.caret.focus)
            overlays.append(GridEditorOverlay(range: DocumentRange(start: start, end: end), kind: .remoteSelection(entry.caret.color.cgColor)))
        }
        return overlays
    }

    var editorRemoteCarets: [(position: Position, color: CGColor)] {
        carets.map { ($0.caret.focus, $0.caret.color.cgColor) }
    }

    var editorSelectionColor: CGColor? {
        tokenizer?.themeColors?.selectionBackground.flatMap { RGBAColor(css: $0) }.map { host!.editorGrid.style.cgColor($0) }
    }

    private func themeColor(_ value: String?) -> CGColor? {
        guard let value, let color = RGBAColor(css: value), let host else { return nil }
        return host.editorGrid.style.cgColor(color)
    }

    var editorSearchMatchColor: CGColor? { themeColor(tokenizer?.themeColors?.findMatchHighlightBackground) }
    var editorBracketMatchColor: CGColor? { themeColor(tokenizer?.themeColors?.bracketMatchBackground) }

    var editorCaretColor: CGColor? {
        tokenizer?.themeColors?.cursorForeground.flatMap { RGBAColor(css: $0) }.map { host!.editorGrid.style.cgColor($0) }
    }

    func editorKeyDown(_ event: NSEvent) -> Bool {
        guard let document else { return false }
        let keyEvent = editorKeyEvent(from: event)
        if keyEvent.key == "Tab", !keyEvent.shiftKey, !keyEvent.ctrlKey, !keyEvent.metaKey,
           !keyEvent.altKey || options.editPrediction?.mode == .subtle, prediction != nil, predictionRevealed
        {
            // Visible prediction owns Tab even when acceptance fails.
            _ = acceptPrediction()
            return true
        }
        if keyEvent.key == "Escape", prediction != nil {
            cancelPrediction()
            return true
        }
        if let searchPanel, let direction = resolveFindAgainShortcut(keyEvent) {
            searchPanel.navigate(previous: direction == .previous)
            return true
        }
        if let command = resolveEditorCommand(keyEvent, keymap: compiledKeymap) {
            runCommand(command)
            return true
        }
        if let move = moveCursorShortcut(keyEvent) {
            let wrap = host?.editorWraps == true
            let moveOptions = CursorMoveOptions(
                getSoftLineOffsets: wrap ? { [weak self] line in self?.softLineOffsets(line) } : nil,
                resolveRenderableLine: host?.editorResolveRenderableLine
            )
            updateSelections(keyEvent.shiftKey
                ? mapSelectionShift(document, selections, move, options: moveOptions)
                : mapCursorMove(document, selections, move, options: moveOptions))
            canMountSelectionAction = true
            if keyEvent.shiftKey { showSelectionActionIfNeeded() } else { closeSelectionAction() }
            host?.editorGrid.scrollEditorCaretToVisible()
            return true
        }
        return false
    }

    /// `isMoveCursorShortcut`.
    private func moveCursorShortcut(_ event: EditorKeyEvent) -> CursorMove? {
        if currentEditorPlatform == .mac, event.ctrlKey, !event.altKey, !event.metaKey {
            switch event.key {
            case "a": return .start
            case "e": return .end
            case "p": return .up
            case "n": return .down
            case "f": return .right
            case "b": return .left
            default: break
            }
        }
        if !event.altKey, !event.ctrlKey, !event.metaKey {
            switch event.key {
            case "ArrowUp": return .up
            case "ArrowDown": return .down
            case "ArrowLeft": return .left
            case "ArrowRight": return .right
            case "Home": return .start
            case "End": return .end
            default: break
            }
        }
        if isPrimaryModifier(metaKey: event.metaKey, ctrlKey: event.ctrlKey) {
            if event.key == "ArrowLeft" { return .textStart }
            if event.key == "ArrowRight" { return .end }
        }
        return nil
    }

    private func softLineOffsets(_ line: Int) -> [Int]? {
        guard let host, let location = host.editorGrid.editorLocation(ofLine: line), let rendered = host.editorGrid.textLine(row: location.row, column: location.column) else { return nil }
        let layout = host.editorGrid.layout(for: rendered, column: host.editorGrid.columns[location.column])
        guard layout.lineStarts.count > 1 else { return nil }
        return layout.lineStarts + [layout.utf16Count]
    }

    func editorInsertText(_ text: String) {
        guard let document else { return }
        markedText = nil
        let normalized = text.utf16.count == 1 ? text : text
        let surround = getAutoSurroundReplacementTexts(document, selections, normalized, autoSurround: options.autoSurround)
        replaceSelectionText(surround ?? [normalized])
    }

    func editorSetMarkedText(_ text: String, selectedRange: NSRange) {
        // Composition renders underlined at the caret without editing the
        // document until committed.
        guard let primary = selections.last else { return }
        if text.isEmpty {
            markedText = nil
        } else {
            let start = primary.start
            markedText = (text, DocumentRange(start: start, end: Position(line: start.line, character: start.character + text.utf16.count)))
        }
        host?.editorGrid.needsDisplay = true
    }

    func editorUnmarkText() {
        markedText = nil
        host?.editorGrid.needsDisplay = true
    }

    func editorDoCommand(_ selector: Selector) -> Bool {
        guard let document else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            replaceSelectionText([document.eol.rawValue])
        case #selector(NSResponder.insertTab(_:)):
            runCommand(.indent)
        case #selector(NSResponder.insertBacktab(_:)):
            runCommand(.outdent)
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:)):
            perform { try applyDeleteCharacterToSelections($0, $1, forward: false, lineAnnotations: $2, tabSize: self.tabSize) }
        case #selector(NSResponder.deleteForward(_:)):
            perform { try applyDeleteCharacterToSelections($0, $1, forward: true, lineAnnotations: $2, tabSize: self.tabSize) }
        case #selector(NSResponder.deleteWordBackward(_:)):
            perform { try applyDeleteWordBackwardToSelections($0, $1, lineAnnotations: $2) }
        case #selector(NSResponder.deleteToBeginningOfLine(_:)):
            perform { try applyDeleteSoftLineBackwardToSelections($0, $1, lineAnnotations: $2) }
        case #selector(NSResponder.deleteToEndOfLine(_:)), #selector(NSResponder.deleteToEndOfParagraph(_:)):
            perform { try applyDeleteHardLineForwardToSelections($0, $1, lineAnnotations: $2) }
        case #selector(NSResponder.transpose(_:)):
            perform { try applyTransposeToSelections($0, $1, lineAnnotations: $2) }
        case #selector(NSResponder.moveWordLeft(_:)), #selector(NSResponder.moveWordRight(_:)),
             #selector(NSResponder.moveWordLeftAndModifySelection(_:)), #selector(NSResponder.moveWordRightAndModifySelection(_:)):
            let forward = selector == #selector(NSResponder.moveWordRight(_:)) || selector == #selector(NSResponder.moveWordRightAndModifySelection(_:))
            let extend = selector == #selector(NSResponder.moveWordLeftAndModifySelection(_:)) || selector == #selector(NSResponder.moveWordRightAndModifySelection(_:))
            moveByWord(forward: forward, extend: extend)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.pageUp(_:)),
             #selector(NSResponder.pageDownAndModifySelection(_:)), #selector(NSResponder.pageUpAndModifySelection(_:)):
            let down = selector == #selector(NSResponder.pageDown(_:)) || selector == #selector(NSResponder.pageDownAndModifySelection(_:))
            let extend = selector == #selector(NSResponder.pageDownAndModifySelection(_:)) || selector == #selector(NSResponder.pageUpAndModifySelection(_:))
            movePage(down: down, extend: extend)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)):
            runCommand(.moveCursorToDocStart)
        case #selector(NSResponder.moveToEndOfDocument(_:)):
            runCommand(.moveCursorToDocEnd)
        case #selector(NSResponder.cancelOperation(_:)):
            runCommand(.simplifySelection)
        default:
            return false
        }
        return true
    }

    /// Word motion like a browser's Alt+Arrow.
    private func moveByWord(forward: Bool, extend: Bool) {
        guard let document else { return }
        let moved = selections.map { selection -> EditorSelection in
            var focus = selection.focus
            let units = document.getLineUnits(focus.line)
            let words = wordBoundaryTargets(units)
            if forward {
                if let target = words.ends.first(where: { $0 > focus.character }) {
                    focus.character = target
                } else if focus.line < document.lineCount - 1, focus.character >= units.count {
                    focus = Position(line: focus.line + 1, character: 0)
                } else {
                    focus.character = units.count
                }
            } else {
                if let target = words.starts.last(where: { $0 < focus.character }) {
                    focus.character = target
                } else if focus.line > 0, focus.character == 0 {
                    focus = Position(line: focus.line - 1, character: document.getLineLength(focus.line - 1))
                } else {
                    focus.character = 0
                }
            }
            let caret = EditorSelection(caret: focus)
            return extend ? createSelectionFrom(selection, caret) : caret
        }
        updateSelections(mergeOverlappingSelections(moved))
        host?.editorGrid.scrollEditorCaretToVisible()
    }

    private func wordBoundaryTargets(_ units: [UInt16]) -> (starts: [Int], ends: [Int]) {
        let string = String(decoding: units, as: UTF16.self) as NSString
        var starts: [Int] = []
        var ends: [Int] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            starts.append(range.location)
            ends.append(range.location + range.length)
        }
        return (starts, ends)
    }

    private func movePage(down: Bool, extend: Bool) {
        guard let document, let grid = host?.editorGrid else { return }
        let visibleLines = max(1, Int((grid.visibleRect.height / grid.style.lineHeight).rounded(.down)) - 1)
        let moved = selections.map { selection -> EditorSelection in
            let focus = selection.focus
            let line = max(0, min(document.lineCount - 1, focus.line + (down ? visibleLines : -visibleLines)))
            let caret = EditorSelection(caret: document.normalizePosition(Position(line: line, character: focus.character)))
            return extend ? createSelectionFrom(selection, caret) : caret
        }
        updateSelections(moved)
        grid.scrollEditorCaretToVisible()
    }

    func editorMouseDown(at position: Position, clickCount: Int, modifiers: NSEvent.ModifierFlags, point: CGPoint) {
        guard let document else { return }
        columnDrag = nil
        if modifiers.contains(.option), !modifiers.contains(.command), !modifiers.contains(.control), !modifiers.contains(.shift) {
            // Alt+drag selects a column (`#updateAltColumnSelections`).
            columnDrag = (position, point.x)
            updateSelections([EditorSelection(caret: position)])
            return
        }
        let caret = EditorSelection(caret: position)
        let primaryModifier = isPrimaryModifier(metaKey: modifiers.contains(.command), ctrlKey: modifiers.contains(.control))
        if modifiers.contains(.shift), !selections.isEmpty {
            let next = extendSelections(selections, caret)
            dragAnchor = next.last
            updateSelections(next)
            return
        }
        reservedSelections = primaryModifier ? selections : nil
        var selection = caret
        if clickCount == 2 {
            selection = expandCollapsedSelectionToWord(document, caret)
        } else if clickCount >= 3 {
            let end = position.line + 1 < document.lineCount ? Position(line: position.line + 1, character: 0) : Position(line: position.line, character: document.getLineLength(position.line))
            selection = EditorSelection(start: Position(line: position.line, character: 0), end: end, direction: .forward)
        }
        dragAnchor = selection
        updateSelections(mergeOverlappingSelections((reservedSelections ?? []) + [selection]))
    }

    func editorMouseDragged(to position: Position, point: CGPoint) {
        if let columnDrag, let document, let host {
            let raw = (point.x - columnDrag.startX) / host.editorGrid.style.ch
            let delta = raw < 0 ? -Int((-raw).rounded()) : Int(raw.rounded())
            let anchor = columnDrag.anchor
            let focusCharacter = max(0, anchor.character + delta)
            var next: [EditorSelection] = []
            let step = position.line < anchor.line ? -1 : 1
            var line = anchor.line
            while true {
                if host.editorGrid.editorLocation(ofLine: line) != nil {
                    let units = document.getLineUnits(line)
                    let anchorOffset = min(anchor.character, units.count)
                    let focusOffset = min(focusCharacter, units.count)
                    let anchorCharacter = snapCharacterToGraphemeBoundary(String(decoding: units, as: UTF16.self), anchorOffset)
                    let lineFocus = focusOffset == anchorOffset ? anchorCharacter : snapCharacterToGraphemeBoundary(String(decoding: units, as: UTF16.self), focusOffset)
                    next.append(EditorSelection(
                        start: Position(line: line, character: min(anchorCharacter, lineFocus)),
                        end: Position(line: line, character: max(anchorCharacter, lineFocus)),
                        direction: anchorCharacter == lineFocus ? .none : anchorCharacter < lineFocus ? .forward : .backward
                    ))
                }
                if line == position.line { break }
                line += step
            }
            updateSelections(next)
            return
        }
        guard let anchor = dragAnchor else { return }
        let next = createSelectionFrom(anchor, EditorSelection(caret: position))
        updateSelections(mergeOverlappingSelections((reservedSelections ?? []) + [next]))
        host?.editorGrid.scrollEditorCaretToVisible()
    }

    func editorMouseUp() {
        columnDrag = nil
        dragAnchor = nil
        reservedSelections = nil
        canMountSelectionAction = true
        showSelectionActionIfNeeded()
    }

    // MARK: - Popovers

    func editorMouseMoved(to position: Position?, point: CGPoint) {
        guard dragAnchor == nil else { return }
        let index = position.flatMap { position in
            markers.firstIndex { marker in
                marker.start <= position && position <= marker.end && !(marker.start == marker.end)
            }
        }
        if index == markerPopoverIndex { return }
        markerShowWork?.cancel()
        guard let index else {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.removeMarkerPopover() } }
            markerShowWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
            return
        }
        pendingMarkerIndex = index
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.showMarkerPopover(index) } }
        markerShowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func showMarkerPopover(_ index: Int) {
        guard let host, index < markers.count, let anchor = host.editorGrid.editorCaretRect(markers[index].start) else { return }
        removeMarkerPopover()
        let marker = markers[index]
        let popover = EditorPopoverView(content: makeMarkerMessageView(marker.message, source: marker.source))
        let container = host.editorOverlayContainer
        popover.place(in: container, anchor: host.editorGrid.convert(anchor, to: container))
        container.addSubview(popover)
        markerPopover = popover
        markerPopoverIndex = index
    }

    private func removeMarkerPopover() {
        markerShowWork?.cancel()
        markerPopover?.removeFromSuperview()
        markerPopover = nil
        markerPopoverIndex = nil
    }

    private func showSelectionActionIfNeeded() {
        closeSelectionAction()
        guard canMountSelectionAction, let renderSelectionAction, let host, let document,
              let primary = selections.last, !primary.isCollapsed
        else { return }
        let context = DiffsSelectionActionContext(
            selection: primary,
            getSelectionText: { [weak self] in
                guard let self, let document = self.document else { return "" }
                return getSelectionText(document, self.selections)
            },
            replaceSelectionText: { [weak self] text in self?.replaceSelectionText([text]) },
            applyEdits: { [weak self] edits in try? self?.applyEdits(edits) },
            close: { [weak self] in self?.closeSelectionAction() }
        )
        guard let content = renderSelectionAction(context), let anchor = host.editorGrid.editorCaretRect(document.normalizePosition(primary.start)) else { return }
        let popover = EditorPopoverView(content: content)
        let container = host.editorOverlayContainer
        popover.place(in: container, anchor: host.editorGrid.convert(anchor, to: container))
        container.addSubview(popover)
        selectionActionView = popover
    }

    private func closeSelectionAction() {
        selectionActionView?.removeFromSuperview()
        selectionActionView = nil
    }

    func editorFocusChanged(_ focused: Bool) {
        if focused { onFocus?() } else { onBlur?() }
    }

    private static var multiSelectionType: NSPasteboard.PasteboardType { NSPasteboard.PasteboardType("application/vnd.pierre.diffs-selections+json") }

    func editorPerform(_ action: GridEditorAction) {
        guard let document else { return }
        let pasteboard = NSPasteboard.general
        switch action {
        case .copy, .cut:
            let texts = getSelectionClipboardTexts(document, selections)
            let text: String
            if action == .cut {
                let cut = resolveSelectionCut(document, selections)
                text = cut.text
                if !cut.edits.isEmpty, let change = try? document.applyResolvedEdits(cut.edits, selectionsBefore: selections) {
                    let next = cut.nextSelectionOffsets.map { EditorSelection(caret: document.positionAt($0)) }
                    document.setLastUndoSelectionsAfter(next)
                    applyChange(change, next, annotations: applyChangeToLineAnnotations(change))
                }
            } else {
                text = getSelectionText(document, selections)
            }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            if texts.count > 1, let data = try? JSONEncoder().encode(texts) {
                pasteboard.setData(data, forType: Self.multiSelectionType)
            }
        case .paste:
            guard let text = pasteboard.string(forType: .string) else { return }
            if selections.count > 1, let data = pasteboard.data(forType: Self.multiSelectionType),
               let texts = try? JSONDecoder().decode([String].self, from: data), texts.count == selections.count
            {
                replaceSelectionText(texts.map(document.normalizeEol), undoBoundary: true, documentOrder: true)
            } else {
                replaceSelectionText([document.normalizeEol(text)], undoBoundary: true, documentOrder: false)
            }
        case .selectAll:
            runCommand(.selectAll)
        case .undo:
            undo()
        case .redo:
            redo()
        }
    }

    func editorCanPerform(_ action: GridEditorAction) -> Bool {
        switch action {
        case .undo: return canUndo
        case .redo: return canRedo
        case .paste: return NSPasteboard.general.string(forType: .string) != nil
        default: return document != nil
        }
    }
}

/// Converts an AppKit key event to the DOM-like event the keymap expects.
func editorKeyEvent(from event: NSEvent) -> EditorKeyEvent {
    let special: [UInt16: String] = [
        123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        48: "Tab", 36: "Enter", 76: "Enter", 53: "Escape", 51: "Backspace", 117: "Delete",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    let codes: [UInt16: String] = [
        0: "KeyA", 11: "KeyB", 8: "KeyC", 2: "KeyD", 14: "KeyE", 3: "KeyF", 5: "KeyG", 4: "KeyH", 34: "KeyI", 38: "KeyJ",
        40: "KeyK", 37: "KeyL", 46: "KeyM", 45: "KeyN", 31: "KeyO", 35: "KeyP", 12: "KeyQ", 15: "KeyR", 1: "KeyS", 17: "KeyT",
        32: "KeyU", 9: "KeyV", 13: "KeyW", 7: "KeyX", 16: "KeyY", 6: "KeyZ",
        29: "Digit0", 18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4", 23: "Digit5", 22: "Digit6", 26: "Digit7", 28: "Digit8", 25: "Digit9",
        50: "Backquote", 27: "Minus", 24: "Equal", 43: "Comma", 47: "Period", 44: "Slash", 41: "Semicolon", 39: "Quote",
        33: "BracketLeft", 30: "BracketRight", 42: "Backslash", 49: "Space",
    ]
    let flags = event.modifierFlags
    let key: String
    if let name = special[event.keyCode] {
        key = name
    } else if event.keyCode == 49 {
        key = " "
    } else {
        key = event.charactersIgnoringModifiers ?? ""
    }
    return EditorKeyEvent(
        key: key,
        code: codes[event.keyCode] ?? special[event.keyCode],
        altKey: flags.contains(.option),
        ctrlKey: flags.contains(.control),
        metaKey: flags.contains(.command),
        shiftKey: flags.contains(.shift)
    )
}

extension DiffsEditor: AnyEditorCompletionObserver {
    func observeCompletion(_ event: Any) {
        onComplete?(event)
    }
}
