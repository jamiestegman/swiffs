// SwiftUI wrappers for the AppKit components (the counterpart of the
// upstream React bindings: `FileDiff`, `File`, `PatchDiff`, `MultiFileDiff`
// and `CodeView`).

import AppKit
import SwiftUI
import SwiffsCore
import SwiffsEditor
import SwiffsHighlight

/// Renders a file diff (`<FileDiff />`). Sizes itself to its content height,
/// so place it inside a `ScrollView` for long diffs, or use `DiffsCodeList`
/// for virtualized lists.
public struct DiffsFileDiff<Metadata>: NSViewRepresentable {
    /// What to diff: parsed metadata (`<FileDiff />`), two files
    /// (`<MultiFileDiff />`) or a single-file patch (`<PatchDiff />`).
    public enum Input: Equatable {
        case fileDiff(FileDiffMetadata)
        case files(old: FileContents?, new: FileContents?)
        case patch(String)
    }

    public var input: Input
    public var options: DiffsDiffOptions
    public var annotations: [DiffLineAnnotation<Metadata>]
    public var selectedLines: SelectedLineRange?
    public var renderAnnotation: ((DiffLineAnnotation<Metadata>) -> NSView?)?
    public var renderCustomHeader: ((FileDiffMetadata) -> NSView?)?
    public var renderHeaderPrefix: ((FileDiffMetadata) -> NSView?)?
    public var renderHeaderFilenameSuffix: ((FileDiffMetadata) -> NSView?)?
    public var renderHeaderMetadata: ((FileDiffMetadata) -> NSView?)?
    public var renderGutterUtility: (() -> NSView?)?
    public var onLineClick: ((DiffsLineEvent) -> Void)?
    public var onLineSelected: ((SelectedLineRange?) -> Void)?
    public var onGutterUtilityClick: ((SelectedLineRange) -> Void)?
    /// Makes the new side editable (`edit`).
    public var edit = false
    public var editorOptions = DiffsEditorOptions()
    public var editStateKey: String?
    public var onEditChange: ((DiffsEditorChangeEvent) -> Void)?
    public var onEditComplete: ((FileDiffEditCompleteEvent<Metadata>) -> EditCompletionDecision)?

    /// The diff for `.fileDiff` input.
    public var fileDiff: FileDiffMetadata? {
        if case .fileDiff(let diff) = input { return diff }
        return nil
    }

    public init(
        fileDiff: FileDiffMetadata,
        options: DiffsDiffOptions = DiffsDiffOptions(),
        annotations: [DiffLineAnnotation<Metadata>] = [],
        selectedLines: SelectedLineRange? = nil,
        renderAnnotation: ((DiffLineAnnotation<Metadata>) -> NSView?)? = nil,
        onLineClick: ((DiffsLineEvent) -> Void)? = nil,
        onLineSelected: ((SelectedLineRange?) -> Void)? = nil,
        onGutterUtilityClick: ((SelectedLineRange) -> Void)? = nil,
        edit: Bool = false,
        editorOptions: DiffsEditorOptions = DiffsEditorOptions(),
        editStateKey: String? = nil,
        onEditChange: ((DiffsEditorChangeEvent) -> Void)? = nil,
        onEditComplete: ((FileDiffEditCompleteEvent<Metadata>) -> EditCompletionDecision)? = nil
    ) {
        self.init(
            input: .fileDiff(fileDiff), options: options, annotations: annotations, selectedLines: selectedLines,
            renderAnnotation: renderAnnotation, onLineClick: onLineClick, onLineSelected: onLineSelected,
            onGutterUtilityClick: onGutterUtilityClick, edit: edit, editorOptions: editorOptions, editStateKey: editStateKey,
            onEditChange: onEditChange, onEditComplete: onEditComplete
        )
    }

    /// Diff of two files (`<MultiFileDiff />`), parsed once per input.
    public init(
        oldFile: FileContents?,
        newFile: FileContents?,
        options: DiffsDiffOptions = DiffsDiffOptions(),
        annotations: [DiffLineAnnotation<Metadata>] = [],
        selectedLines: SelectedLineRange? = nil,
        renderAnnotation: ((DiffLineAnnotation<Metadata>) -> NSView?)? = nil,
        onLineClick: ((DiffsLineEvent) -> Void)? = nil,
        onLineSelected: ((SelectedLineRange?) -> Void)? = nil,
        onGutterUtilityClick: ((SelectedLineRange) -> Void)? = nil,
        edit: Bool = false,
        editorOptions: DiffsEditorOptions = DiffsEditorOptions(),
        editStateKey: String? = nil,
        onEditChange: ((DiffsEditorChangeEvent) -> Void)? = nil,
        onEditComplete: ((FileDiffEditCompleteEvent<Metadata>) -> EditCompletionDecision)? = nil
    ) {
        self.init(
            input: .files(old: oldFile, new: newFile), options: options, annotations: annotations, selectedLines: selectedLines,
            renderAnnotation: renderAnnotation, onLineClick: onLineClick, onLineSelected: onLineSelected,
            onGutterUtilityClick: onGutterUtilityClick, edit: edit, editorOptions: editorOptions, editStateKey: editStateKey,
            onEditChange: onEditChange, onEditComplete: onEditComplete
        )
    }

    /// A single-file patch (`<PatchDiff />`), parsed once per input.
    public init(
        patch: String,
        options: DiffsDiffOptions = DiffsDiffOptions(),
        annotations: [DiffLineAnnotation<Metadata>] = [],
        selectedLines: SelectedLineRange? = nil,
        renderAnnotation: ((DiffLineAnnotation<Metadata>) -> NSView?)? = nil,
        onLineClick: ((DiffsLineEvent) -> Void)? = nil,
        onLineSelected: ((SelectedLineRange?) -> Void)? = nil,
        onGutterUtilityClick: ((SelectedLineRange) -> Void)? = nil,
        edit: Bool = false,
        editorOptions: DiffsEditorOptions = DiffsEditorOptions(),
        editStateKey: String? = nil,
        onEditChange: ((DiffsEditorChangeEvent) -> Void)? = nil,
        onEditComplete: ((FileDiffEditCompleteEvent<Metadata>) -> EditCompletionDecision)? = nil
    ) {
        self.init(
            input: .patch(patch), options: options, annotations: annotations, selectedLines: selectedLines,
            renderAnnotation: renderAnnotation, onLineClick: onLineClick, onLineSelected: onLineSelected,
            onGutterUtilityClick: onGutterUtilityClick, edit: edit, editorOptions: editorOptions, editStateKey: editStateKey,
            onEditChange: onEditChange, onEditComplete: onEditComplete
        )
    }

    public init(
        input: Input,
        options: DiffsDiffOptions = DiffsDiffOptions(),
        annotations: [DiffLineAnnotation<Metadata>] = [],
        selectedLines: SelectedLineRange? = nil,
        renderAnnotation: ((DiffLineAnnotation<Metadata>) -> NSView?)? = nil,
        onLineClick: ((DiffsLineEvent) -> Void)? = nil,
        onLineSelected: ((SelectedLineRange?) -> Void)? = nil,
        onGutterUtilityClick: ((SelectedLineRange) -> Void)? = nil,
        edit: Bool = false,
        editorOptions: DiffsEditorOptions = DiffsEditorOptions(),
        editStateKey: String? = nil,
        onEditChange: ((DiffsEditorChangeEvent) -> Void)? = nil,
        onEditComplete: ((FileDiffEditCompleteEvent<Metadata>) -> EditCompletionDecision)? = nil
    ) {
        self.input = input
        self.options = options
        self.annotations = annotations
        self.selectedLines = selectedLines
        self.renderAnnotation = renderAnnotation
        self.onLineClick = onLineClick
        self.onLineSelected = onLineSelected
        self.onGutterUtilityClick = onGutterUtilityClick
        self.edit = edit
        self.editorOptions = editorOptions
        self.editStateKey = editStateKey
        self.onEditChange = onEditChange
        self.onEditComplete = onEditComplete
    }

    /// Header slots (`renderCustomHeader`, `renderHeaderPrefix`,
    /// `renderHeaderFilenameSuffix`, `renderHeaderMetadata`).
    public func header(
        custom: ((FileDiffMetadata) -> NSView?)? = nil,
        prefix: ((FileDiffMetadata) -> NSView?)? = nil,
        filenameSuffix: ((FileDiffMetadata) -> NSView?)? = nil,
        metadata: ((FileDiffMetadata) -> NSView?)? = nil
    ) -> Self {
        var copy = self
        copy.renderCustomHeader = custom
        copy.renderHeaderPrefix = prefix
        copy.renderHeaderFilenameSuffix = filenameSuffix
        copy.renderHeaderMetadata = metadata
        return copy
    }

    /// Content for the hovered line's gutter button (`renderGutterUtility`).
    public func gutterUtility(_ render: (() -> NSView?)?) -> Self {
        var copy = self
        copy.renderGutterUtility = render
        return copy
    }

    @MainActor
    public final class Coordinator {
        var editor: DiffsEditor<DiffLineAnnotation<Metadata>>?
        var dispose: (() -> Void)?
        var accepted: (input: FileDiffMetadata, diff: FileDiffMetadata)?
        /// The last parsed input (`useFileDiffInstance` memoization).
        var parsed: (input: Input, options: CreatePatchOptions, result: Result<FileDiffMetadata, Error>)?
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> FileDiffView<Metadata> {
        let view = FileDiffView<Metadata>(options: options)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func resolveInput(_ coordinator: Coordinator) -> Result<FileDiffMetadata, Error> {
        if case .fileDiff(let diff) = input { return .success(diff) }
        if let parsed = coordinator.parsed, parsed.input == input, parsed.options == options.parseDiffOptions {
            return parsed.result
        }
        let result = Result<FileDiffMetadata, Error> {
            switch input {
            case .fileDiff(let diff): return diff
            case .files(let old, let new): return try parseDiffFromFile(oldFile: old, newFile: new, options: options.parseDiffOptions)
            case .patch(let patch): return try getSingularPatch(patch)
            }
        }
        coordinator.parsed = (input, options.parseDiffOptions, result)
        return result
    }

    public func updateNSView(_ view: FileDiffView<Metadata>, context: Context) {
        let coordinator = context.coordinator
        view.renderAnnotation = renderAnnotation
        if renderCustomHeader != nil || view.renderCustomHeader != nil { view.renderCustomHeader = renderCustomHeader }
        if renderHeaderPrefix != nil || view.renderHeaderPrefix != nil { view.renderHeaderPrefix = renderHeaderPrefix }
        if renderHeaderFilenameSuffix != nil || view.renderHeaderFilenameSuffix != nil { view.renderHeaderFilenameSuffix = renderHeaderFilenameSuffix }
        if renderHeaderMetadata != nil || view.renderHeaderMetadata != nil { view.renderHeaderMetadata = renderHeaderMetadata }
        if renderGutterUtility != nil || view.renderGutterUtility != nil { view.renderGutterUtility = renderGutterUtility }
        view.onLineClick = onLineClick
        view.onLineSelected = onLineSelected
        view.onGutterUtilityClick = onGutterUtilityClick
        view.onEditComplete = { event in
            let decision = onEditComplete?(event) ?? .reject
            if decision == .accept { coordinator.accepted = (event.originalFileDiff, event.fileDiff) }
            return decision
        }
        view.options = options
        if !edit, let dispose = coordinator.dispose {
            coordinator.dispose = nil
            dispose()
        }
        let fileDiff: FileDiffMetadata
        switch resolveInput(coordinator) {
        case .success(let diff):
            fileDiff = diff
        case .failure(let error):
            view.reportRenderError(error)
            return
        }
        var resolved = fileDiff
        if let accepted = coordinator.accepted {
            if accepted.input == fileDiff { resolved = accepted.diff } else { coordinator.accepted = nil }
        }
        if coordinator.dispose == nil {
            view.render(fileDiff: resolved, lineAnnotations: annotations)
        }
        if view.selectedLines != selectedLines {
            view.setSelectedLines(selectedLines)
        }
        if edit, coordinator.dispose == nil {
            let editor = DiffsEditor<DiffLineAnnotation<Metadata>>(options: editorOptions, editStateKey: editStateKey)
            editor.onChange = onEditChange
            coordinator.editor = editor
            coordinator.dispose = editor.edit(view)
        } else {
            coordinator.editor?.onChange = onEditChange
        }
    }

    public static func dismantleNSView(_ view: FileDiffView<Metadata>, coordinator: Coordinator) {
        coordinator.editor?.cleanUp(.discard)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: FileDiffView<Metadata>, context: Context) -> CGSize? {
        let width = proposal.width ?? 800
        return CGSize(width: width, height: nsView.preferredHeight(forWidth: width))
    }
}

/// Renders a file (`<File />`).
public struct DiffsFile<Metadata>: NSViewRepresentable {
    public var file: FileContents
    public var options: DiffsCodeOptions
    public var annotations: [LineAnnotation<Metadata>]
    public var selectedLines: SelectedLineRange?
    public var renderAnnotation: ((LineAnnotation<Metadata>) -> NSView?)?
    public var renderCustomHeader: ((FileContents) -> NSView?)?
    public var renderHeaderPrefix: ((FileContents) -> NSView?)?
    public var renderHeaderFilenameSuffix: ((FileContents) -> NSView?)?
    public var renderHeaderMetadata: ((FileContents) -> NSView?)?
    public var renderGutterUtility: (() -> NSView?)?
    public var onLineClick: ((DiffsLineEvent) -> Void)?
    public var onLineSelected: ((SelectedLineRange?) -> Void)?
    /// Makes the file editable (`edit`).
    public var edit: Bool
    public var editorOptions: DiffsEditorOptions
    public var editStateKey: String?
    public var onEditChange: ((DiffsEditorChangeEvent) -> Void)?
    public var onEditComplete: ((FileEditCompleteEvent<Metadata>) -> EditCompletionDecision)?

    public init(
        file: FileContents,
        options: DiffsCodeOptions = DiffsCodeOptions(),
        annotations: [LineAnnotation<Metadata>] = [],
        selectedLines: SelectedLineRange? = nil,
        renderAnnotation: ((LineAnnotation<Metadata>) -> NSView?)? = nil,
        onLineClick: ((DiffsLineEvent) -> Void)? = nil,
        onLineSelected: ((SelectedLineRange?) -> Void)? = nil,
        edit: Bool = false,
        editorOptions: DiffsEditorOptions = DiffsEditorOptions(),
        editStateKey: String? = nil,
        onEditChange: ((DiffsEditorChangeEvent) -> Void)? = nil,
        onEditComplete: ((FileEditCompleteEvent<Metadata>) -> EditCompletionDecision)? = nil
    ) {
        self.file = file
        self.options = options
        self.annotations = annotations
        self.selectedLines = selectedLines
        self.renderAnnotation = renderAnnotation
        self.onLineClick = onLineClick
        self.onLineSelected = onLineSelected
        self.edit = edit
        self.editorOptions = editorOptions
        self.editStateKey = editStateKey
        self.onEditChange = onEditChange
        self.onEditComplete = onEditComplete
    }

    /// Header slots (`renderCustomHeader`, `renderHeaderPrefix`,
    /// `renderHeaderFilenameSuffix`, `renderHeaderMetadata`).
    public func header(
        custom: ((FileContents) -> NSView?)? = nil,
        prefix: ((FileContents) -> NSView?)? = nil,
        filenameSuffix: ((FileContents) -> NSView?)? = nil,
        metadata: ((FileContents) -> NSView?)? = nil
    ) -> Self {
        var copy = self
        copy.renderCustomHeader = custom
        copy.renderHeaderPrefix = prefix
        copy.renderHeaderFilenameSuffix = filenameSuffix
        copy.renderHeaderMetadata = metadata
        return copy
    }

    /// Content for the hovered line's gutter button (`renderGutterUtility`).
    public func gutterUtility(_ render: (() -> NSView?)?) -> Self {
        var copy = self
        copy.renderGutterUtility = render
        return copy
    }

    @MainActor
    public final class Coordinator {
        var editor: DiffsEditor<LineAnnotation<Metadata>>?
        var dispose: (() -> Void)?
        /// The input an accepted edit replaced, and the accepted file.
        var accepted: (input: FileContents, file: FileContents)?
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> FileView<Metadata> {
        FileView<Metadata>(options: options)
    }

    public func updateNSView(_ view: FileView<Metadata>, context: Context) {
        let coordinator = context.coordinator
        view.renderAnnotation = renderAnnotation
        if renderCustomHeader != nil || view.renderCustomHeader != nil { view.renderCustomHeader = renderCustomHeader }
        if renderHeaderPrefix != nil || view.renderHeaderPrefix != nil { view.renderHeaderPrefix = renderHeaderPrefix }
        if renderHeaderFilenameSuffix != nil || view.renderHeaderFilenameSuffix != nil { view.renderHeaderFilenameSuffix = renderHeaderFilenameSuffix }
        if renderHeaderMetadata != nil || view.renderHeaderMetadata != nil { view.renderHeaderMetadata = renderHeaderMetadata }
        if renderGutterUtility != nil || view.renderGutterUtility != nil { view.renderGutterUtility = renderGutterUtility }
        view.onLineClick = onLineClick
        view.onLineSelected = onLineSelected
        view.onEditComplete = { event in
            let decision = onEditComplete?(event) ?? .reject
            if decision == .accept { coordinator.accepted = (event.originalFile, event.file) }
            return decision
        }
        view.options = options
        if !edit, let dispose = coordinator.dispose {
            coordinator.dispose = nil
            dispose()
        }
        // Keep an accepted edit until the owner passes a different file.
        var resolved = file
        if let accepted = coordinator.accepted {
            if accepted.input == file { resolved = accepted.file } else { coordinator.accepted = nil }
        }
        if coordinator.dispose == nil {
            view.render(file: resolved, lineAnnotations: annotations)
        }
        if view.selectedLines != selectedLines {
            view.setSelectedLines(selectedLines)
        }
        if edit, coordinator.dispose == nil {
            let editor = DiffsEditor<LineAnnotation<Metadata>>(options: editorOptions, editStateKey: editStateKey)
            editor.onChange = onEditChange
            coordinator.editor = editor
            coordinator.dispose = editor.edit(view)
        } else {
            coordinator.editor?.onChange = onEditChange
        }
    }

    public static func dismantleNSView(_ view: FileView<Metadata>, coordinator: Coordinator) {
        coordinator.editor?.cleanUp(.discard)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: FileView<Metadata>, context: Context) -> CGSize? {
        let width = proposal.width ?? 800
        return CGSize(width: width, height: nsView.preferredHeight(forWidth: width))
    }
}

/// Renders a file with merge conflict markers (`<UnresolvedFile />`).
/// Uncontrolled: the file is parsed once and conflicts resolve internally,
/// reporting the updated text through `onResolve`.
public struct DiffsUnresolvedFile: NSViewRepresentable {
    public var file: FileContents
    public var options: DiffsDiffOptions
    public var maxContextLines: Int
    public var onResolve: ((FileContents, MergeConflictActionPayload) -> Void)?

    public init(
        file: FileContents,
        options: DiffsDiffOptions = DiffsDiffOptions(),
        maxContextLines: Int = 6,
        onResolve: ((FileContents, MergeConflictActionPayload) -> Void)? = nil
    ) {
        self.file = file
        self.options = options
        self.maxContextLines = maxContextLines
        self.onResolve = onResolve
    }

    public func makeNSView(context: Context) -> UnresolvedFileView<Void> {
        let view = UnresolvedFileView<Void>(options: options)
        view.maxContextLines = maxContextLines
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    public func updateNSView(_ view: UnresolvedFileView<Void>, context: Context) {
        view.onMergeConflictResolve = onResolve
        view.options = options
        // Only the first file is parsed; later text comes from resolutions.
        if view.fileDiff == nil {
            try? view.render(file: file)
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: UnresolvedFileView<Void>, context: Context) -> CGSize? {
        let width = proposal.width ?? 800
        return CGSize(width: width, height: nsView.preferredHeight(forWidth: width))
    }
}

/// Renders code as it streams in (`FileStream`). A new `id` restarts the
/// stream from `source`.
public struct DiffsFileStream<Source: AsyncSequence & Sendable>: NSViewRepresentable where Source.Element == String {
    public var id: AnyHashable
    public var source: Source
    public var options: FileStreamOptions
    public var onStreamClose: (() -> Void)?

    public init(id: AnyHashable, source: Source, options: FileStreamOptions = FileStreamOptions(), onStreamClose: (() -> Void)? = nil) {
        self.id = id
        self.source = source
        self.options = options
        self.onStreamClose = onStreamClose
    }

    public final class Coordinator {
        var streamID: AnyHashable?
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> FileStreamView {
        let view = FileStreamView(options: options)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    public func updateNSView(_ view: FileStreamView, context: Context) {
        view.onStreamClose = onStreamClose
        if view.options != options { view.setOptions(options) }
        if context.coordinator.streamID != id {
            context.coordinator.streamID = id
            view.setup(source)
        }
    }

    public static func dismantleNSView(_ view: FileStreamView, coordinator: Coordinator) {
        view.cleanUp()
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: FileStreamView, context: Context) -> CGSize? {
        let width = proposal.width ?? 800
        return CGSize(width: width, height: nsView.preferredHeight(forWidth: width))
    }
}

/// A virtualized list of files and diffs (`<CodeView />`).
public struct DiffsCodeList<Metadata>: NSViewRepresentable {
    public var items: [CodeViewItem<Metadata>]
    public var options: CodeViewOptions
    public var selectedLines: CodeViewLineSelection?
    public var scrollTarget: CodeViewScrollTarget?
    public var renderDiffAnnotation: ((DiffLineAnnotation<Metadata>, CodeViewItemContext) -> NSView?)?
    public var renderFileAnnotation: ((LineAnnotation<Metadata>, CodeViewItemContext) -> NSView?)?
    public var onSelectedLinesChange: ((CodeViewLineSelection?) -> Void)?
    public var onLineClick: ((DiffsLineEvent, CodeViewItemContext) -> Void)?
    public var onGutterUtilityClick: ((SelectedLineRange, CodeViewItemContext) -> Void)?

    public init(
        items: [CodeViewItem<Metadata>],
        options: CodeViewOptions = CodeViewOptions(),
        selectedLines: CodeViewLineSelection? = nil,
        scrollTarget: CodeViewScrollTarget? = nil,
        renderDiffAnnotation: ((DiffLineAnnotation<Metadata>, CodeViewItemContext) -> NSView?)? = nil,
        renderFileAnnotation: ((LineAnnotation<Metadata>, CodeViewItemContext) -> NSView?)? = nil,
        onSelectedLinesChange: ((CodeViewLineSelection?) -> Void)? = nil,
        onLineClick: ((DiffsLineEvent, CodeViewItemContext) -> Void)? = nil,
        onGutterUtilityClick: ((SelectedLineRange, CodeViewItemContext) -> Void)? = nil
    ) {
        self.items = items
        self.options = options
        self.selectedLines = selectedLines
        self.scrollTarget = scrollTarget
        self.renderDiffAnnotation = renderDiffAnnotation
        self.renderFileAnnotation = renderFileAnnotation
        self.onSelectedLinesChange = onSelectedLinesChange
        self.onLineClick = onLineClick
        self.onGutterUtilityClick = onGutterUtilityClick
    }

    public final class Coordinator {
        var lastScrollTargetDescription: String?
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> CodeView<Metadata> {
        CodeView<Metadata>(options: options)
    }

    public func updateNSView(_ view: CodeView<Metadata>, context: Context) {
        view.renderDiffAnnotation = renderDiffAnnotation
        view.renderFileAnnotation = renderFileAnnotation
        view.onSelectedLinesChange = onSelectedLinesChange
        view.onLineClick = onLineClick
        view.onGutterUtilityClick = onGutterUtilityClick
        view.options = options
        view.setItems(items)
        if view.selectedLines != selectedLines {
            view.setSelectedLines(selectedLines)
        }
        if let scrollTarget {
            let description = String(describing: scrollTarget)
            if description != context.coordinator.lastScrollTargetDescription {
                context.coordinator.lastScrollTargetDescription = description
                DispatchQueue.main.async { view.scrollTo(scrollTarget) }
            }
        }
    }
}
