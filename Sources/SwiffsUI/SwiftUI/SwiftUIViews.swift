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
    public var fileDiff: FileDiffMetadata
    public var options: DiffsDiffOptions
    public var annotations: [DiffLineAnnotation<Metadata>]
    public var selectedLines: SelectedLineRange?
    public var renderAnnotation: ((DiffLineAnnotation<Metadata>) -> NSView?)?
    public var onLineClick: ((DiffsLineEvent) -> Void)?
    public var onLineSelected: ((SelectedLineRange?) -> Void)?
    public var onGutterUtilityClick: ((SelectedLineRange) -> Void)?
    /// Makes the new side editable (`edit`).
    public var edit = false
    public var editorOptions = DiffsEditorOptions()
    public var editStateKey: String?
    public var onEditChange: ((DiffsEditorChangeEvent) -> Void)?
    public var onEditComplete: ((FileDiffEditCompleteEvent<Metadata>) -> EditCompletionDecision)?

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
        self.edit = edit
        self.editorOptions = editorOptions
        self.editStateKey = editStateKey
        self.onEditChange = onEditChange
        self.onEditComplete = onEditComplete
        self.fileDiff = fileDiff
        self.options = options
        self.annotations = annotations
        self.selectedLines = selectedLines
        self.renderAnnotation = renderAnnotation
        self.onLineClick = onLineClick
        self.onLineSelected = onLineSelected
        self.onGutterUtilityClick = onGutterUtilityClick
    }

    @MainActor
    public final class Coordinator {
        var editor: DiffsEditor<DiffLineAnnotation<Metadata>>?
        var dispose: (() -> Void)?
        var accepted: (input: FileDiffMetadata, diff: FileDiffMetadata)?
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> FileDiffView<Metadata> {
        let view = FileDiffView<Metadata>(options: options)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    public func updateNSView(_ view: FileDiffView<Metadata>, context: Context) {
        let coordinator = context.coordinator
        view.renderAnnotation = renderAnnotation
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

extension DiffsFileDiff where Metadata == Void {
    /// Diff of two files (`<MultiFileDiff />`).
    public init(oldFile: FileContents?, newFile: FileContents?, options: DiffsDiffOptions = DiffsDiffOptions()) {
        let diff = (try? parseDiffFromFile(oldFile: oldFile, newFile: newFile, options: options.parseDiffOptions))
            ?? FileDiffMetadata(name: newFile?.name ?? oldFile?.name ?? "", isPartial: false)
        self.init(fileDiff: diff, options: options)
    }

    /// A single-file patch (`<PatchDiff />`).
    public init(patch: String, options: DiffsDiffOptions = DiffsDiffOptions()) {
        let diff = (try? getSingularPatch(patch)) ?? FileDiffMetadata(name: "", isPartial: true)
        self.init(fileDiff: diff, options: options)
    }
}

/// Renders a file (`<File />`).
public struct DiffsFile<Metadata>: NSViewRepresentable {
    public var file: FileContents
    public var options: DiffsCodeOptions
    public var annotations: [LineAnnotation<Metadata>]
    public var selectedLines: SelectedLineRange?
    public var renderAnnotation: ((LineAnnotation<Metadata>) -> NSView?)?
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
