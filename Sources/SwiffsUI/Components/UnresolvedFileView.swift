// Port of `UnresolvedFile`: renders a file containing merge conflict markers
// as a unified diff between the current and incoming sides, with marker rows
// and "Accept current change | Accept incoming change | Accept both" actions.

import AppKit
import SwiffsCore
import SwiffsHighlight

/// How conflict actions render (`mergeConflictActionsType`).
public enum UnresolvedFileActions<Metadata> {
    case none
    case `default`
    /// A custom view per conflict; return nil to leave the row empty.
    case custom((MergeConflictDiffAction, UnresolvedFileView<Metadata>) -> NSView?)
}

public final class UnresolvedFileView<Metadata>: NSView {
    public typealias Annotation = DiffLineAnnotation<Metadata>

    /// The underlying diff view. Its options, callbacks and annotation
    /// rendering apply as for `FileDiffView`; `diffStyle` and `lineDiffType`
    /// are ignored (always unified, no inline diffs).
    public let diffView: FileDiffView<Metadata>

    public var options: DiffsDiffOptions {
        get { diffView.options }
        set { diffView.options = newValue }
    }

    public var mergeConflictActions: UnresolvedFileActions<Metadata> = .default {
        didSet { applyConflictState() }
    }

    /// Context lines kept around each conflict when parsing a file.
    public var maxContextLines = 6

    /// Controlled mode: called instead of resolving internally. Resolve with
    /// `resolveConflict(_:resolution:fileDiff:)` and pass the result back via
    /// `render(fileDiff:actions:markerRows:)`. Mutually exclusive with
    /// `onMergeConflictResolve`.
    public var onMergeConflictAction: ((MergeConflictActionPayload, UnresolvedFileView<Metadata>) -> Void)?

    /// Uncontrolled mode: called after a conflict was resolved internally with
    /// the updated unresolved file text.
    public var onMergeConflictResolve: ((FileContents, MergeConflictActionPayload) -> Void)?

    public var onHeightChange: ((CGFloat) -> Void)? {
        get { diffView.onHeightChange }
        set { diffView.onHeightChange = newValue }
    }

    public private(set) var file: FileContents?
    public private(set) var fileDiff: FileDiffMetadata?
    public private(set) var conflictActions: [MergeConflictDiffAction?] = []
    public private(set) var markerRows: [MergeConflictMarkerRow] = []

    public init(options: DiffsDiffOptions = DiffsDiffOptions()) {
        diffView = FileDiffView<Metadata>(options: options)
        super.init(frame: .zero)
        diffView.autoresizingMask = [.width, .height]
        addSubview(diffView)
        diffView.onMergeConflictActionClick = { [weak self] conflictIndex, resolution in
            self?.handleMergeConflictActionClick(conflictIndex: conflictIndex, resolution: resolution)
        }
        diffView.renderMergeConflictActionView = { [weak self] conflictIndex in
            guard let self, case .custom(let render) = self.mergeConflictActions,
                  conflictIndex < self.conflictActions.count, let action = self.conflictActions[conflictIndex]
            else { return nil }
            return render(action, self)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        diffView.frame = bounds
    }

    public func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        diffView.preferredHeight(forWidth: width)
    }

    public override var intrinsicContentSize: NSSize {
        diffView.intrinsicContentSize
    }

    // MARK: - Rendering

    /// Renders a file with conflict markers. In uncontrolled mode the file is
    /// parsed once; later updates come from internal resolution.
    public func render(file: FileContents, lineAnnotations: [Annotation]? = nil) throws {
        if onMergeConflictAction == nil, let current = self.file, current != file, fileDiff != nil {
            throw DiffsError("UnresolvedFile.getOrComputeDiff: uncontrolled unresolved files parse the file only once. Later updates must come from the cached diff state.")
        }
        if self.file != file || fileDiff == nil {
            let parsed = try parseMergeConflictDiffFromFile(file, maxContextLines: maxContextLines)
            self.file = file
            fileDiff = parsed.fileDiff
            conflictActions = parsed.actions
            markerRows = parsed.markerRows
        }
        renderCurrentState(lineAnnotations: lineAnnotations)
    }

    /// Controlled rendering from externally held state.
    public func render(
        fileDiff: FileDiffMetadata,
        actions: [MergeConflictDiffAction?],
        markerRows: [MergeConflictMarkerRow],
        file: FileContents? = nil,
        lineAnnotations: [Annotation]? = nil
    ) {
        if let file { self.file = file }
        self.fileDiff = fileDiff
        conflictActions = actions
        self.markerRows = markerRows
        renderCurrentState(lineAnnotations: lineAnnotations)
    }

    /// Resolves one conflict against `fileDiff` (defaults to the current
    /// state) without rendering (`UnresolvedFile.resolveConflict`).
    public func resolveConflict(
        _ conflictIndex: Int,
        resolution: MergeConflictResolution,
        fileDiff: FileDiffMetadata? = nil
    ) throws -> UnresolvedFileState? {
        guard let diff = fileDiff ?? self.fileDiff else { return nil }
        return try resolveUnresolvedConflict(
            fileDiff: diff,
            actions: conflictActions,
            conflictIndex: conflictIndex,
            resolution: resolution,
            previousFile: file
        )
    }

    private func renderCurrentState(lineAnnotations: [Annotation]?) {
        guard let fileDiff else { return }
        applyConflictState(render: false)
        diffView.render(fileDiff: fileDiff, lineAnnotations: lineAnnotations)
    }

    private var actionsType: MergeConflictActionsType {
        switch mergeConflictActions {
        case .none: return .none
        case .default: return .default
        case .custom: return .custom
        }
    }

    private func applyConflictState(render: Bool = true) {
        diffView.mergeConflict = FileDiffView<Metadata>.MergeConflictState(
            actions: conflictActions,
            markerRows: markerRows,
            actionsType: actionsType
        )
        if render, diffView.fileDiff != nil {
            diffView.reloadRows()
        }
    }

    private func handleMergeConflictActionClick(conflictIndex: Int, resolution: MergeConflictResolution) {
        guard conflictIndex < conflictActions.count, let action = conflictActions[conflictIndex] else { return }
        let payload = MergeConflictActionPayload(resolution: resolution, conflict: action.conflict)
        if let onMergeConflictAction {
            onMergeConflictAction(payload, self)
            return
        }
        guard let state = try? resolveConflict(conflictIndex, resolution: resolution) else { return }
        file = state.file
        fileDiff = state.fileDiff
        conflictActions = state.actions
        markerRows = state.markerRows
        renderCurrentState(lineAnnotations: nil)
        onMergeConflictResolve?(state.file, payload)
    }
}
