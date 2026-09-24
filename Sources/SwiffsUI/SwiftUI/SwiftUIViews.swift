// SwiftUI wrappers for the AppKit components (the counterpart of the
// upstream React bindings: `FileDiff`, `File`, `PatchDiff`, `MultiFileDiff`
// and `CodeView`).

import AppKit
import SwiftUI
import SwiffsCore
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

    public init(
        fileDiff: FileDiffMetadata,
        options: DiffsDiffOptions = DiffsDiffOptions(),
        annotations: [DiffLineAnnotation<Metadata>] = [],
        selectedLines: SelectedLineRange? = nil,
        renderAnnotation: ((DiffLineAnnotation<Metadata>) -> NSView?)? = nil,
        onLineClick: ((DiffsLineEvent) -> Void)? = nil,
        onLineSelected: ((SelectedLineRange?) -> Void)? = nil,
        onGutterUtilityClick: ((SelectedLineRange) -> Void)? = nil
    ) {
        self.fileDiff = fileDiff
        self.options = options
        self.annotations = annotations
        self.selectedLines = selectedLines
        self.renderAnnotation = renderAnnotation
        self.onLineClick = onLineClick
        self.onLineSelected = onLineSelected
        self.onGutterUtilityClick = onGutterUtilityClick
    }

    public func makeNSView(context: Context) -> FileDiffView<Metadata> {
        let view = FileDiffView<Metadata>(options: options)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    public func updateNSView(_ view: FileDiffView<Metadata>, context: Context) {
        view.renderAnnotation = renderAnnotation
        view.onLineClick = onLineClick
        view.onLineSelected = onLineSelected
        view.onGutterUtilityClick = onGutterUtilityClick
        view.options = options
        view.render(fileDiff: fileDiff, lineAnnotations: annotations)
        if view.selectedLines != selectedLines {
            view.setSelectedLines(selectedLines)
        }
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

    public init(
        file: FileContents,
        options: DiffsCodeOptions = DiffsCodeOptions(),
        annotations: [LineAnnotation<Metadata>] = [],
        selectedLines: SelectedLineRange? = nil,
        renderAnnotation: ((LineAnnotation<Metadata>) -> NSView?)? = nil,
        onLineClick: ((DiffsLineEvent) -> Void)? = nil,
        onLineSelected: ((SelectedLineRange?) -> Void)? = nil
    ) {
        self.file = file
        self.options = options
        self.annotations = annotations
        self.selectedLines = selectedLines
        self.renderAnnotation = renderAnnotation
        self.onLineClick = onLineClick
        self.onLineSelected = onLineSelected
    }

    public func makeNSView(context: Context) -> FileView<Metadata> {
        FileView<Metadata>(options: options)
    }

    public func updateNSView(_ view: FileView<Metadata>, context: Context) {
        view.renderAnnotation = renderAnnotation
        view.onLineClick = onLineClick
        view.onLineSelected = onLineSelected
        view.options = options
        view.render(file: file, lineAnnotations: annotations)
        if view.selectedLines != selectedLines {
            view.setSelectedLines(selectedLines)
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: FileView<Metadata>, context: Context) -> CGSize? {
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
