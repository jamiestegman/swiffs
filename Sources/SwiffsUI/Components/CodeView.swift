// Port of the `CodeView` component: a virtualized, scrollable list of files
// and diffs with sticky headers, estimated/measured item heights, view
// recycling, scroll-to targets (with the spring-based smooth scroll) and
// per-item state.

import AppKit
import QuartzCore
import SwiffsCore
import SwiffsHighlight

/// An item rendered by `CodeView` (`CodeViewItem`).
public struct CodeViewItem<Metadata> {
    public enum Content {
        case file(FileContents, annotations: [LineAnnotation<Metadata>])
        case diff(FileDiffMetadata, annotations: [DiffLineAnnotation<Metadata>])
    }

    public var id: String
    public var content: Content
    /// Bump to force a re-render when content changes in place.
    public var version: Int
    public var collapsed: Bool

    public init(id: String, content: Content, version: Int = 0, collapsed: Bool = false) {
        self.id = id
        self.content = content
        self.version = version
        self.collapsed = collapsed
    }

    public static func file(id: String, _ file: FileContents, annotations: [LineAnnotation<Metadata>] = [], version: Int = 0, collapsed: Bool = false) -> CodeViewItem {
        CodeViewItem(id: id, content: .file(file, annotations: annotations), version: version, collapsed: collapsed)
    }

    public static func diff(id: String, _ fileDiff: FileDiffMetadata, annotations: [DiffLineAnnotation<Metadata>] = [], version: Int = 0, collapsed: Bool = false) -> CodeViewItem {
        CodeViewItem(id: id, content: .diff(fileDiff, annotations: annotations), version: version, collapsed: collapsed)
    }

    var isDiff: Bool {
        if case .diff = content { return true }
        return false
    }
}

public enum CodeViewScrollBehavior: String, Sendable {
    case instant
    case smooth
    /// Smooth for short distances, instant for long jumps.
    case smoothAuto = "smooth-auto"
}

public enum CodeViewScrollAlignment: String, Sendable {
    case start, center, end, nearest
}

/// Where to scroll (`CodeViewScrollTarget`).
public enum CodeViewScrollTarget: Sendable {
    case position(CGFloat, behavior: CodeViewScrollBehavior = .instant)
    case item(id: String, align: CodeViewScrollAlignment = .start, offset: CGFloat = 0, behavior: CodeViewScrollBehavior = .instant)
    case line(id: String, lineNumber: Int, side: AnnotationSide? = nil, align: CodeViewScrollAlignment = .start, offset: CGFloat = 0, behavior: CodeViewScrollBehavior = .instant)
    case range(id: String, range: SelectedLineRange, align: CodeViewScrollAlignment = .start, offset: CGFloat = 0, behavior: CodeViewScrollBehavior = .instant)
}

/// Selected lines in a code view (`CodeViewLineSelection`).
public struct CodeViewLineSelection: Hashable, Sendable {
    public var id: String
    public var range: SelectedLineRange

    public init(id: String, range: SelectedLineRange) {
        self.id = id
        self.range = range
    }
}

/// Options for `CodeView` (`CodeViewOptions`).
public struct CodeViewOptions: Equatable, @unchecked Sendable {
    /// Options applied to every diff item.
    public var diff = DiffsDiffOptions()
    /// Options applied to every file item (defaults to the diff's code
    /// options).
    public var file: DiffsCodeOptions?
    public var stickyHeaders = true
    public var layout = DiffsConstants.defaultCodeViewLayout
    public var itemMetrics = DiffsConstants.defaultCodeViewFileMetrics
    public var smoothScrollSettings = DiffsConstants.defaultSmoothScrollSettings
    /// Extra viewport heights rendered above/below the visible area.
    public var overscan: CGFloat = 0.5

    public init() {}

    var fileOptions: DiffsCodeOptions { file ?? diff.code }
}

/// Identifies the item an event came from.
public struct CodeViewItemContext: Hashable, Sendable {
    public var id: String
    public var isDiff: Bool
}

public final class CodeView<Metadata>: NSView {
    public typealias Item = CodeViewItem<Metadata>

    // MARK: Public configuration

    public var options = CodeViewOptions() {
        didSet { if options != oldValue { optionsDidChange() } }
    }

    // Rendering callbacks (receive the item context).
    public var renderDiffAnnotation: ((DiffLineAnnotation<Metadata>, CodeViewItemContext) -> NSView?)?
    public var renderFileAnnotation: ((LineAnnotation<Metadata>, CodeViewItemContext) -> NSView?)?
    public var renderHeaderPrefix: ((CodeViewItemContext) -> NSView?)?
    public var renderHeaderFilenameSuffix: ((CodeViewItemContext) -> NSView?)?
    public var renderHeaderMetadata: ((CodeViewItemContext) -> NSView?)?
    public var renderCustomHeader: ((CodeViewItemContext) -> NSView?)?
    /// View shown above the first item (`renderCodeViewHeader`).
    public var headerView: NSView? { didSet { replaceChrome(old: oldValue, new: headerView) } }
    /// View shown after the last item (`renderCodeViewFooter`).
    public var footerView: NSView? { didSet { replaceChrome(old: oldValue, new: footerView) } }

    // Interaction callbacks.
    public var onLineClick: ((DiffsLineEvent, CodeViewItemContext) -> Void)?
    public var onLineNumberClick: ((DiffsLineEvent, CodeViewItemContext) -> Void)?
    public var onLineEnter: ((DiffsLineEvent, CodeViewItemContext) -> Void)?
    public var onLineLeave: ((DiffsLineEvent, CodeViewItemContext) -> Void)?
    public var onTokenClick: ((DiffsTokenEvent, CodeViewItemContext) -> Void)?
    public var onTokenEnter: ((DiffsTokenEvent, CodeViewItemContext) -> Void)?
    public var onTokenLeave: ((DiffsTokenEvent, CodeViewItemContext) -> Void)?
    public var onGutterUtilityClick: ((SelectedLineRange, CodeViewItemContext) -> Void)?
    public var onLineSelected: ((SelectedLineRange?, CodeViewItemContext) -> Void)?
    public var onSelectedLinesChange: ((CodeViewLineSelection?) -> Void)?
    public var onPostRender: ((NSView, CodeViewItemContext) -> Void)?
    /// Called when the scroll position changes.
    public var onScroll: ((CGFloat) -> Void)?

    // MARK: Internal state

    private final class ItemState {
        var item: Item
        var estimatedHeight: CGFloat = 0
        var measuredHeight: CGFloat?
        var measuredWidth: CGFloat = 0
        var top: CGFloat = 0
        var expandedHunks: [Int: HunkExpansionRegion] = [:]
        var renderedVersion: Int?

        init(item: Item) {
            self.item = item
        }

        var height: CGFloat { measuredHeight ?? estimatedHeight }
    }

    private let scrollView = NSScrollView()
    private let documentView = CodeViewDocumentView()
    private var states: [ItemState] = []
    private var indexByID: [String: Int] = [:]
    private var mountedDiffViews: [String: FileDiffView<Metadata>] = [:]
    private var mountedFileViews: [String: FileView<Metadata>] = [:]
    private var diffViewPool: [FileDiffView<Metadata>] = []
    private var fileViewPool: [FileView<Metadata>] = []
    private var selection: CodeViewLineSelection?
    private var layoutWidth: CGFloat = 0
    private var isUpdating = false
    private var scrollAnimation: (position: CGFloat, velocity: CGFloat, lastTimestamp: CFTimeInterval)?
    private var pendingScrollTarget: CodeViewScrollTarget?
    private var displayTimer: Timer?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public convenience init(options: CodeViewOptions = CodeViewOptions()) {
        self.init(frame: .zero)
        self.options = options
    }

    public override var isFlipped: Bool { true }

    // MARK: - Items API

    public var items: [Item] { states.map(\.item) }

    public func getItem(_ id: String) -> Item? {
        indexByID[id].map { states[$0].item }
    }

    /// Replaces all items (`setItems`). Item state (expansions, measured
    /// heights) is kept for ids that remain.
    public func setItems(_ items: [Item]) {
        let previous = Dictionary(uniqueKeysWithValues: states.map { ($0.item.id, $0) })
        states = items.map { item in
            if let existing = previous[item.id] {
                if !itemsEquivalent(existing.item, item) {
                    existing.measuredHeight = nil
                    existing.renderedVersion = nil
                }
                existing.item = item
                return existing
            }
            return ItemState(item: item)
        }
        rebuildIndex()
        for (id, _) in previous where indexByID[id] == nil {
            unmount(id)
        }
        recomputeEstimates()
        relayoutItems()
    }

    public func addItem(_ item: Item) {
        addItems([item])
    }

    public func addItems(_ items: [Item]) {
        for item in items {
            if let index = indexByID[item.id] {
                states[index].item = item
            } else {
                states.append(ItemState(item: item))
                indexByID[item.id] = states.count - 1
            }
        }
        recomputeEstimates()
        relayoutItems()
    }

    /// Updates an item in place (`updateItem`); returns false for unknown ids.
    @discardableResult
    public func updateItem(_ item: Item) -> Bool {
        guard let index = indexByID[item.id] else { return false }
        let state = states[index]
        if !itemsEquivalent(state.item, item) {
            state.measuredHeight = nil
            state.renderedVersion = nil
        }
        state.item = item
        state.estimatedHeight = estimateHeight(state)
        relayoutItems()
        return true
    }

    /// Renames an item (`updateItemId`).
    @discardableResult
    public func updateItemId(_ oldID: String, to newID: String) -> Bool {
        guard let index = indexByID[oldID], indexByID[newID] == nil else { return false }
        states[index].item.id = newID
        if let view = mountedDiffViews.removeValue(forKey: oldID) { mountedDiffViews[newID] = view }
        if let view = mountedFileViews.removeValue(forKey: oldID) { mountedFileViews[newID] = view }
        if selection?.id == oldID { selection?.id = newID }
        rebuildIndex()
        return true
    }

    @discardableResult
    public func removeItem(_ id: String) -> Bool {
        guard let index = indexByID[id] else { return false }
        states.remove(at: index)
        unmount(id)
        rebuildIndex()
        relayoutItems()
        return true
    }

    private func itemsEquivalent(_ a: Item, _ b: Item) -> Bool {
        guard a.version == b.version, a.collapsed == b.collapsed else { return false }
        switch (a.content, b.content) {
        case (.diff(let x, _), .diff(let y, _)): return x == y
        case (.file(let x, _), .file(let y, _)): return x == y
        default: return false
        }
    }

    private func rebuildIndex() {
        indexByID = Dictionary(uniqueKeysWithValues: states.enumerated().map { ($1.item.id, $0) })
    }

    // MARK: - Selection

    public func setSelectedLines(_ selection: CodeViewLineSelection?) {
        let previousID = self.selection?.id
        self.selection = selection
        if let previousID, previousID != selection?.id {
            mountedDiffViews[previousID]?.setSelectedLines(nil)
            mountedFileViews[previousID]?.setSelectedLines(nil)
        }
        if let selection {
            mountedDiffViews[selection.id]?.setSelectedLines(selection.range)
            mountedFileViews[selection.id]?.setSelectedLines(selection.range)
        }
    }

    public var selectedLines: CodeViewLineSelection? { selection }

    public func clearSelectedLines() {
        setSelectedLines(nil)
    }

    // MARK: - Scrolling

    public var scrollTop: CGFloat { scrollView.contentView.bounds.minY }
    public var viewportHeight: CGFloat { scrollView.contentView.bounds.height }
    public var scrollHeight: CGFloat { documentView.frame.height }

    /// Top offset of an item in scroll coordinates (`getTopForItem`).
    public func topForItem(_ id: String) -> CGFloat? {
        indexByID[id].map { states[$0].top }
    }

    public func scrollTo(_ target: CodeViewScrollTarget) {
        guard let normalized = normalize(target) else { return }
        guard let destination = resolveTop(normalized) else { return }
        let behavior = behaviorOf(normalized)
        let distance = abs(destination - scrollTop)
        let smooth = behavior == .smooth || (behavior == .smoothAuto && distance < viewportHeight * 2)
        if !smooth {
            scrollAnimation = nil
            pendingScrollTarget = nil
            setScrollTop(destination)
            return
        }
        pendingScrollTarget = normalized
        if scrollAnimation == nil {
            scrollAnimation = (scrollTop, 0, CACurrentMediaTime() * 1000)
        }
        startAnimationTimer()
    }

    private func behaviorOf(_ target: CodeViewScrollTarget) -> CodeViewScrollBehavior {
        switch target {
        case .position(_, let behavior), .item(_, _, _, let behavior), .line(_, _, _, _, _, let behavior), .range(_, _, _, _, let behavior):
            return behavior
        }
    }

    private var stickyHeaderOffset: CGFloat {
        options.stickyHeaders && !options.diff.code.disableFileHeader ? FileHeaderView.height : 0
    }

    private func clampScrollTop(_ value: CGFloat) -> CGFloat {
        max(0, min(value, max(0, scrollHeight - viewportHeight)))
    }

    /// Rect of a target in scroll coordinates.
    private func targetRect(_ target: CodeViewScrollTarget) -> CGRect? {
        switch target {
        case .position(let position, _):
            return CGRect(x: 0, y: position, width: 0, height: 0)
        case .item(let id, _, _, _):
            guard let index = indexByID[id] else { return nil }
            return CGRect(x: 0, y: states[index].top, width: 0, height: states[index].height)
        case .line(let id, let lineNumber, let side, _, _, _):
            return lineRect(id: id, lineNumber: lineNumber, side: side)
        case .range(let id, let range, _, _, _):
            guard let start = lineRect(id: id, lineNumber: range.start, side: range.side),
                  let end = lineRect(id: id, lineNumber: range.end, side: range.endSide ?? range.side)
            else { return nil }
            return start.union(end)
        }
    }

    private func lineRect(id: String, lineNumber: Int, side: AnnotationSide?) -> CGRect? {
        guard let index = indexByID[id] else { return nil }
        let state = states[index]
        if let view = mountedDiffViews[id] ?? nil, let frame = view.frameForLine(lineNumber, side: side) {
            return frame.offsetBy(dx: 0, dy: state.top)
        }
        if let view = mountedFileViews[id], let frame = view.frameForLine(lineNumber) {
            return frame.offsetBy(dx: 0, dy: state.top)
        }
        // Estimate from line indexes for unmounted items.
        let metrics = options.itemMetrics
        var rowIndex = lineNumber - 1
        if case .diff(let diff, _) = state.item.content,
           let indexes = getLineIndexForDiff(diff, lineNumber: lineNumber, side: side ?? .additions)
        {
            rowIndex = options.diff.diffStyle == .split ? indexes.split : indexes.unified
        }
        let top = state.top + getVirtualFileHeaderRegion(metrics, disableFileHeader: options.diff.code.disableFileHeader)
            + CGFloat(rowIndex) * metrics.lineHeight
        return CGRect(x: 0, y: top, width: 0, height: metrics.lineHeight)
    }

    private func normalize(_ target: CodeViewScrollTarget) -> CodeViewScrollTarget? {
        let align: CodeViewScrollAlignment
        let offset: CGFloat
        switch target {
        case .position: return target
        case .item(_, let a, let o, _), .line(_, _, _, let a, let o, _), .range(_, _, let a, let o, _):
            align = a
            offset = o
        }
        guard align == .nearest else { return target }
        guard let rect = targetRect(target) else { return nil }
        let isLineTarget: Bool = {
            if case .item = target { return false }
            return true
        }()
        let visibleTop = scrollTop + (isLineTarget ? stickyHeaderOffset : 0)
        let visibleBottom = scrollTop + viewportHeight
        if rect.minY - offset <= visibleTop, rect.maxY + offset >= visibleBottom { return nil }
        let newAlign: CodeViewScrollAlignment
        if rect.minY - offset < visibleTop {
            newAlign = .start
        } else if rect.maxY + offset > visibleBottom {
            newAlign = .end
        } else {
            return nil
        }
        switch target {
        case .item(let id, _, let offset, let behavior): return .item(id: id, align: newAlign, offset: offset, behavior: behavior)
        case .line(let id, let line, let side, _, let offset, let behavior): return .line(id: id, lineNumber: line, side: side, align: newAlign, offset: offset, behavior: behavior)
        case .range(let id, let range, _, let offset, let behavior): return .range(id: id, range: range, align: newAlign, offset: offset, behavior: behavior)
        case .position: return target
        }
    }

    private func resolveTop(_ target: CodeViewScrollTarget) -> CGFloat? {
        switch target {
        case .position(let position, _):
            let clamped = clampScrollTop(position)
            return clamped != position ? clamped : clampScrollTop(position - stickyHeaderOffset)
        case .item(_, let align, let offset, _):
            guard let rect = targetRect(target) else { return nil }
            return clampScrollTop(aligned(rect, align, offset, sticky: 0))
        case .line(_, _, _, let align, let offset, _), .range(_, _, let align, let offset, _):
            guard let rect = targetRect(target) else { return nil }
            return clampScrollTop(aligned(rect, align, offset, sticky: stickyHeaderOffset))
        }
    }

    private func aligned(_ rect: CGRect, _ align: CodeViewScrollAlignment, _ offset: CGFloat, sticky: CGFloat) -> CGFloat {
        let viewport = viewportHeight
        if align == .center, rect.height + offset < viewport {
            return rect.minY - (viewport - rect.height) / 2 + offset
        }
        if align == .end {
            return rect.minY - (viewport - rect.height) + offset
        }
        return rect.minY - sticky - offset
    }

    private func setScrollTop(_ value: CGFloat) {
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: clampScrollTop(value)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func startAnimationTimer() {
        guard displayTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepAnimation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopAnimation() {
        displayTimer?.invalidate()
        displayTimer = nil
        scrollAnimation = nil
        pendingScrollTarget = nil
    }

    /// Closed-form critically damped spring step (`computeSpringStep`).
    private func stepAnimation() {
        guard let target = pendingScrollTarget, var animation = scrollAnimation, let destination = resolveTop(target) else {
            stopAnimation()
            return
        }
        let now = CACurrentMediaTime() * 1000
        let dt = max(0, now - animation.lastTimestamp)
        let omega = options.smoothScrollSettings.omega
        let decay = exp(-omega * dt)
        let displacement = Double(animation.position - destination)
        let springCoeff = Double(animation.velocity) + omega * displacement
        let position = Double(destination) + (displacement + springCoeff * dt) * decay
        let velocity = (springCoeff * (1 - omega * dt) - omega * displacement) * decay
        animation = (CGFloat(position), CGFloat(velocity), now)
        let settings = options.smoothScrollSettings
        if abs(position - Double(destination)) < settings.positionEpsilon, abs(velocity) < settings.velocityEpsilon {
            setScrollTop(destination)
            stopAnimation()
            return
        }
        scrollAnimation = animation
        setScrollTop(CGFloat(position))
    }

    public override func scrollWheel(with event: NSEvent) {
        // User scrolling cancels programmatic smooth scrolling.
        if displayTimer != nil { stopAnimation() }
        super.scrollWheel(with: event)
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        let width = scrollView.contentSize.width
        if width != layoutWidth {
            layoutWidth = width
            for state in states where state.measuredWidth != width {
                state.measuredHeight = nil
            }
            recomputeEstimates()
            relayoutItems()
        }
    }

    private func optionsDidChange() {
        for state in states {
            state.measuredHeight = nil
            state.renderedVersion = nil
        }
        recomputeEstimates()
        relayoutItems()
    }

    private func estimateHeight(_ state: ItemState) -> CGFloat {
        let metrics = options.itemMetrics
        let disableHeader = options.diff.code.disableFileHeader
        if state.item.collapsed {
            return disableHeader ? 0 : FileHeaderView.height
        }
        switch state.item.content {
        case .diff(let diff, _):
            let heights = try? computeEstimatedDiffHeights(
                fileDiff: diff,
                metrics: metrics,
                disableFileHeader: disableHeader,
                hunkSeparators: options.diff.hunkSeparators,
                expandUnchanged: options.diff.expandUnchanged,
                expandedHunks: .regions(state.expandedHunks),
                collapsedContextThreshold: options.diff.collapsedContextThreshold,
                canHydratePartialDiff: false
            )
            guard let heights else { return metrics.diffHeaderHeight }
            return options.diff.diffStyle == .split ? heights.splitHeight : heights.unifiedHeight
        case .file(let file, _):
            let lines = CGFloat(linesFromFileContents(file.contents).count)
            return getVirtualFileHeaderRegion(metrics, disableFileHeader: disableHeader) + lines * metrics.lineHeight + getVirtualFilePaddingBottom(metrics)
        }
    }

    private func recomputeEstimates() {
        for state in states {
            state.estimatedHeight = estimateHeight(state)
        }
    }

    private var chromeHeaderHeight: CGFloat {
        headerView.map { $0.fittingSize.height > 0 ? $0.fittingSize.height : $0.frame.height } ?? 0
    }

    private var chromeFooterHeight: CGFloat {
        footerView.map { $0.fittingSize.height > 0 ? $0.fittingSize.height : $0.frame.height } ?? 0
    }

    private func replaceChrome(old: NSView?, new: NSView?) {
        old?.removeFromSuperview()
        if let new { documentView.addSubview(new) }
        relayoutItems()
    }

    /// Recomputes item offsets and document height, keeping the first
    /// visible item anchored.
    private func relayoutItems() {
        let anchor = anchorItem()
        var y = chromeHeaderHeight + options.layout.paddingTop
        for (index, state) in states.enumerated() {
            if index > 0 { y += options.layout.gap }
            state.top = y
            y += state.height
        }
        y += options.layout.paddingBottom
        let footerTop = y
        y += chromeFooterHeight
        let width = max(scrollView.contentSize.width, 1)
        documentView.frame = CGRect(x: 0, y: 0, width: width, height: max(y, scrollView.contentSize.height))
        headerView?.frame = CGRect(x: 0, y: 0, width: width, height: chromeHeaderHeight)
        footerView?.frame = CGRect(x: 0, y: footerTop, width: width, height: chromeFooterHeight)
        if let anchor, let index = indexByID[anchor.id] {
            let delta = states[index].top - anchor.top
            if delta != 0 {
                isUpdating = true
                setScrollTop(scrollTop + delta)
                isUpdating = false
            }
        }
        updateVisibleItems()
    }

    private func anchorItem() -> (id: String, top: CGFloat)? {
        guard scrollTop > 0 else { return nil }
        for state in states where state.top + state.height > scrollTop {
            return (state.item.id, state.top)
        }
        return nil
    }

    @objc private func boundsDidChange() {
        updateVisibleItems()
        onScroll?(scrollTop)
    }

    /// Mounts views for items intersecting the viewport (plus overscan) and
    /// recycles the rest.
    private func updateVisibleItems() {
        guard !states.isEmpty else {
            for id in Array(mountedDiffViews.keys) + Array(mountedFileViews.keys) { unmount(id) }
            return
        }
        let overscan = viewportHeight * options.overscan
        let minY = scrollTop - overscan
        let maxY = scrollTop + viewportHeight + overscan
        var visibleIDs: Set<String> = []
        var heightChanged = false
        for state in states where state.top + state.height >= minY && state.top <= maxY {
            visibleIDs.insert(state.item.id)
            if mount(state) { heightChanged = true }
        }
        for id in Array(mountedDiffViews.keys) where !visibleIDs.contains(id) { unmount(id) }
        for id in Array(mountedFileViews.keys) where !visibleIDs.contains(id) { unmount(id) }
        if heightChanged {
            relayoutItems()
            return
        }
        updateStickyHeaders()
    }

    private func updateStickyHeaders() {
        let top = scrollTop
        for (id, view) in mountedDiffViews {
            guard let index = indexByID[id] else { continue }
            view.stickyHeaderOffset = options.stickyHeaders ? max(0, top - states[index].top) : 0
        }
        for (id, view) in mountedFileViews {
            guard let index = indexByID[id] else { continue }
            view.stickyHeaderOffset = options.stickyHeaders ? max(0, top - states[index].top) : 0
        }
    }

    /// Mounts or refreshes an item's view. Returns true when its measured
    /// height changed.
    private func mount(_ state: ItemState) -> Bool {
        let width = scrollView.contentSize.width
        let context = CodeViewItemContext(id: state.item.id, isDiff: state.item.isDiff)
        let view: DiffsDocumentView
        switch state.item.content {
        case .diff(let diff, let annotations):
            let diffView: FileDiffView<Metadata>
            if let existing = mountedDiffViews[state.item.id] {
                diffView = existing
            } else {
                diffView = diffViewPool.popLast() ?? FileDiffView<Metadata>(options: options.diff)
                configure(diffView, context: context, state: state)
                mountedDiffViews[state.item.id] = diffView
                documentView.addSubview(diffView)
                state.renderedVersion = nil
            }
            if state.renderedVersion != state.item.version || diffView.fileDiff != diff {
                var itemOptions = options.diff
                itemOptions.code.collapsed = state.item.collapsed
                diffView.options = itemOptions
                diffView.render(fileDiff: diff, lineAnnotations: annotations, expandedHunks: state.expandedHunks)
                diffView.setSelectedLines(selection?.id == state.item.id ? selection?.range : nil)
                state.renderedVersion = state.item.version
            }
            view = diffView
        case .file(let file, let annotations):
            let fileView: FileView<Metadata>
            if let existing = mountedFileViews[state.item.id] {
                fileView = existing
            } else {
                fileView = fileViewPool.popLast() ?? FileView<Metadata>(options: options.fileOptions)
                configure(fileView, context: context)
                mountedFileViews[state.item.id] = fileView
                documentView.addSubview(fileView)
                state.renderedVersion = nil
            }
            if state.renderedVersion != state.item.version || fileView.file != file {
                var itemOptions = options.fileOptions
                itemOptions.collapsed = state.item.collapsed
                fileView.options = itemOptions
                fileView.render(file: file, lineAnnotations: annotations)
                fileView.setSelectedLines(selection?.id == state.item.id ? selection?.range : nil)
                state.renderedVersion = state.item.version
            }
            view = fileView
        }
        let height = view.preferredHeight(forWidth: width)
        let changed = state.measuredHeight != height
        state.measuredHeight = height
        state.measuredWidth = width
        view.frame = CGRect(x: 0, y: state.top, width: width, height: height)
        return changed
    }

    private func configure(_ view: FileDiffView<Metadata>, context: CodeViewItemContext, state: ItemState) {
        let id = context.id
        view.renderAnnotation = renderDiffAnnotation.map { render in { render($0, context) } }
        view.renderHeaderPrefix = renderHeaderPrefix.map { render in { _ in render(context) } }
        view.renderHeaderFilenameSuffix = renderHeaderFilenameSuffix.map { render in { _ in render(context) } }
        view.renderHeaderMetadata = renderHeaderMetadata.map { render in { _ in render(context) } }
        view.renderCustomHeader = renderCustomHeader.map { render in { _ in render(context) } }
        view.onLineClick = onLineClick.map { handler in { handler($0, context) } }
        view.onLineNumberClick = onLineNumberClick.map { handler in { handler($0, context) } }
        view.onLineEnter = onLineEnter.map { handler in { handler($0, context) } }
        view.onLineLeave = onLineLeave.map { handler in { handler($0, context) } }
        view.onTokenClick = onTokenClick.map { handler in { handler($0, context) } }
        view.onTokenEnter = onTokenEnter.map { handler in { handler($0, context) } }
        view.onTokenLeave = onTokenLeave.map { handler in { handler($0, context) } }
        view.onGutterUtilityClick = onGutterUtilityClick.map { handler in { handler($0, context) } }
        view.onLineSelected = { [weak self] range in
            guard let self else { return }
            self.handleSelection(range, id: id)
            self.onLineSelected?(range, context)
        }
        view.onHunkExpand = { [weak self, weak view] _, _ in
            guard let self, let view, let index = self.indexByID[id] else { return }
            self.states[index].expandedHunks = view.expandedHunksMap
        }
        view.onHeightChange = { [weak self] _ in
            guard let self, !self.isUpdating else { return }
            DispatchQueue.main.async { self.refreshMeasuredHeights() }
        }
        view.onPostRender = onPostRender.map { handler in { handler($0, context) } }
    }

    private func configure(_ view: FileView<Metadata>, context: CodeViewItemContext) {
        let id = context.id
        view.renderAnnotation = renderFileAnnotation.map { render in { render($0, context) } }
        view.renderHeaderPrefix = renderHeaderPrefix.map { render in { _ in render(context) } }
        view.renderHeaderFilenameSuffix = renderHeaderFilenameSuffix.map { render in { _ in render(context) } }
        view.renderHeaderMetadata = renderHeaderMetadata.map { render in { _ in render(context) } }
        view.renderCustomHeader = renderCustomHeader.map { render in { _ in render(context) } }
        view.onLineClick = onLineClick.map { handler in { handler($0, context) } }
        view.onLineNumberClick = onLineNumberClick.map { handler in { handler($0, context) } }
        view.onLineEnter = onLineEnter.map { handler in { handler($0, context) } }
        view.onLineLeave = onLineLeave.map { handler in { handler($0, context) } }
        view.onTokenClick = onTokenClick.map { handler in { handler($0, context) } }
        view.onTokenEnter = onTokenEnter.map { handler in { handler($0, context) } }
        view.onTokenLeave = onTokenLeave.map { handler in { handler($0, context) } }
        view.onGutterUtilityClick = onGutterUtilityClick.map { handler in { handler($0, context) } }
        view.onLineSelected = { [weak self] range in
            guard let self else { return }
            self.handleSelection(range, id: id)
            self.onLineSelected?(range, context)
        }
        view.onHeightChange = { [weak self] _ in
            guard let self, !self.isUpdating else { return }
            DispatchQueue.main.async { self.refreshMeasuredHeights() }
        }
        view.onPostRender = onPostRender.map { handler in { handler($0, context) } }
    }

    private func handleSelection(_ range: SelectedLineRange?, id: String) {
        let previous = selection
        if let range {
            if let previousID = previous?.id, previousID != id {
                mountedDiffViews[previousID]?.setSelectedLines(nil)
                mountedFileViews[previousID]?.setSelectedLines(nil)
            }
            selection = CodeViewLineSelection(id: id, range: range)
        } else if previous?.id == id {
            selection = nil
        }
        if previous != selection {
            onSelectedLinesChange?(selection)
        }
    }

    private func refreshMeasuredHeights() {
        let width = scrollView.contentSize.width
        var changed = false
        for (id, view) in mountedDiffViews {
            guard let index = indexByID[id] else { continue }
            let height = view.preferredHeight(forWidth: width)
            if states[index].measuredHeight != height {
                states[index].measuredHeight = height
                states[index].expandedHunks = view.expandedHunksMap
                changed = true
            }
        }
        for (id, view) in mountedFileViews {
            guard let index = indexByID[id] else { continue }
            let height = view.preferredHeight(forWidth: width)
            if states[index].measuredHeight != height {
                states[index].measuredHeight = height
                changed = true
            }
        }
        if changed { relayoutItems() }
    }

    private func unmount(_ id: String) {
        if let view = mountedDiffViews.removeValue(forKey: id) {
            view.removeFromSuperview()
            view.stickyHeaderOffset = 0
            diffViewPool.append(view)
        }
        if let view = mountedFileViews.removeValue(forKey: id) {
            view.removeFromSuperview()
            view.stickyHeaderOffset = 0
            fileViewPool.append(view)
        }
    }

    /// Currently mounted item views (`getRenderedItems`).
    public var renderedItemIDs: [String] {
        states.map(\.item.id).filter { mountedDiffViews[$0] != nil || mountedFileViews[$0] != nil }
    }

    /// The mounted view for an item, if any.
    public func renderedView(for id: String) -> NSView? {
        mountedDiffViews[id] ?? mountedFileViews[id]
    }
}

/// Flipped document view hosting item views.
final class CodeViewDocumentView: NSView {
    override var isFlipped: Bool { true }
}
