import AppKit
import QuartzCore
import SwiftUI
import SwiffsCore
import SwiffsHighlight

/// A scrolling list of diffs, files and conflicted files, with SwiftUI
/// annotations under lines and a SwiftUI accessory in each header.
///
/// Give it values with `update(items:annotations:configuration:)`; it keeps
/// what is unchanged (layout, highlighting, annotation views and their
/// state) and reports what the user does to its `delegate`.
public final class DiffView<AnnotationID: Hashable & Sendable, Annotation: View, Accessory: View>: NSView, DocumentViewDelegate {
    public weak var delegate: (any DiffViewDelegate)?
    public private(set) var items: [DiffItem] = []
    public private(set) var annotations: [DiffAnnotation<AnnotationID>] = []
    public private(set) var configuration: DiffConfiguration
    /// The item at the top of the viewport.
    public private(set) var topItemID: String?
    /// The height of every item laid out, for showing the whole list without
    /// scrolling.
    public var contentHeight: CGFloat { layoutModel.contentHeight }

    /// The selected lines. Setting it does not notify the delegate.
    public var lineSelection: DiffLineSelection? {
        get { documentView.lineSelection }
        set { documentView.lineSelection = newValue }
    }

    private var annotationContent: (AnnotationID) -> Annotation
    private var accessoryContent: (DiffItem) -> Accessory
    private let highlightService: HighlightService
    let scrollView = NSScrollView()
    let layoutModel: DocumentLayout
    let documentView: DocumentView
    let stickyHeader = StickyHeaderView()
    private var annotationHosts: [AnyHashable: AnnotationRecord] = [:]
    private var accessoryHosts: [String: AccessoryHost<Accessory>] = [:]
    private var highlightTasks: [String: (generation: Int, task: Task<Void, Never>)] = [:]
    private var styleKey: StyleKey
    private var isLayingOut = false
    private var needsRelayout = false
    /// Set from an update until it is laid out, when small content is
    /// highlighted before its first frame.
    private var highlightsImmediately = false
    /// Set when drawing changed without the layout changing.
    private var needsFullRedraw = true
    private(set) var scroll = ScrollAnimator()
    private var displayLink: CADisplayLink?

    private struct AnnotationRecord {
        var annotation: DiffAnnotation<AnnotationID>
        var host: AnnotationHost<Annotation>
    }

    private struct StyleKey: Equatable {
        var theme: ThemeSelection
        var colorScheme: ThemeType
        var systemIsDark: Bool
        var typography: DiffTypography
        var overrides: DiffsColorOverrides
    }

    public init(
        configuration: DiffConfiguration = DiffConfiguration(),
        highlightService: HighlightService = .shared,
        @ViewBuilder annotation: @escaping (AnnotationID) -> Annotation,
        @ViewBuilder headerAccessory: @escaping (DiffItem) -> Accessory
    ) {
        self.configuration = configuration
        self.highlightService = highlightService
        annotationContent = annotation
        accessoryContent = headerAccessory
        styleKey = StyleKey(theme: configuration.theme, colorScheme: configuration.colorScheme, systemIsDark: false, typography: configuration.typography, overrides: configuration.colorOverrides)
        let style = Self.makeStyle(styleKey)
        layoutModel = DocumentLayout(configuration: configuration, style: style)
        documentView = DocumentView(layout: layoutModel)
        super.init(frame: .zero)
        layoutModel.annotationHeight = { [weak self] token in self?.annotationHosts[token]?.host.height ?? 0 }
        documentView.delegate = self
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        addSubview(stickyHeader)
        NotificationCenter.default.addObserver(self, selector: #selector(viewportDidChange), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isFlipped: Bool { true }

    // MARK: Input

    /// Shows new values. Items, annotations and configuration are compared
    /// with the current ones by id, so only what changed is rebuilt.
    public func update(items: [DiffItem], annotations: [DiffAnnotation<AnnotationID>] = [], configuration: DiffConfiguration) {
        guard items != self.items || annotations != self.annotations || configuration != self.configuration else { return }
        if configuration != self.configuration {
            needsFullRedraw = true
            let old = self.configuration
            self.configuration = configuration
            refreshStyle(force: old.typography != configuration.typography || old.theme != configuration.theme)
            if old.renderDiffOptions != configuration.renderDiffOptions || old.tokenizeMaxLength != configuration.tokenizeMaxLength {
                cancelHighlights()
            }
        }
        self.items = items
        self.annotations = annotations
        let (changed, removed) = layoutModel.setItems(items, annotations: groupAnnotations(annotations))
        for item in changed + removed { cancelHighlight(item.id) }
        for item in removed {
            accessoryHosts.removeValue(forKey: item.id)?.view.removeFromSuperview()
        }
        syncAnnotationHosts()
        for (id, host) in accessoryHosts {
            if let item = layoutModel.item(id) { host.setContent(accessoryContent(item.item)) }
        }
        if let selection = lineSelection, layoutModel.item(selection.itemID) == nil {
            documentView.lineSelection = nil
        }
        highlightsImmediately = true
        relayout()
    }

    /// Replaces the builders of annotation and accessory content, refreshing
    /// every hosted view.
    public func setContent(@ViewBuilder annotation: @escaping (AnnotationID) -> Annotation, @ViewBuilder headerAccessory: @escaping (DiffItem) -> Accessory) {
        annotationContent = annotation
        accessoryContent = headerAccessory
        for record in annotationHosts.values { record.host.setContent(annotation(record.annotation.id)) }
        for (id, host) in accessoryHosts {
            if let item = layoutModel.item(id) { host.setContent(headerAccessory(item.item)) }
        }
    }

    private func groupAnnotations(_ annotations: [DiffAnnotation<AnnotationID>]) -> [String: [AnnotationKey: [AnyHashable]]] {
        var grouped: [String: [AnnotationKey: [AnyHashable]]] = [:]
        for annotation in annotations {
            grouped[annotation.itemID, default: [:]][key(of: annotation), default: []].append(AnyHashable(annotation.id))
        }
        return grouped
    }

    /// Diffs key annotations by side, files by line alone.
    private func key(of annotation: DiffAnnotation<AnnotationID>) -> AnnotationKey {
        if let item = layoutModel.item(annotation.itemID), item.shape.kind == .file {
            return AnnotationKey(side: nil, lineNumber: annotation.lineNumber)
        }
        return AnnotationKey(side: annotation.side ?? .additions, lineNumber: annotation.lineNumber)
    }

    private func syncAnnotationHosts() {
        var remaining = annotationHosts
        for annotation in annotations {
            let token = AnyHashable(annotation.id)
            if var record = remaining.removeValue(forKey: token) {
                record.annotation = annotation
                record.host.setContent(annotationContent(annotation.id))
                annotationHosts[token] = record
            } else {
                let host = AnnotationHost(content: annotationContent(annotation.id), width: annotationWidth(annotation)) { [weak self] _ in
                    self?.annotationHeightChanged(token)
                }
                documentView.addSubview(host.view)
                annotationHosts[token] = AnnotationRecord(annotation: annotation, host: host)
            }
        }
        for (token, record) in remaining {
            record.host.view.removeFromSuperview()
            annotationHosts[token] = nil
        }
    }

    private func annotationWidth(_ annotation: DiffAnnotation<AnnotationID>) -> CGFloat {
        guard let item = layoutModel.item(annotation.itemID) else { return 0 }
        return item.annotationWidth(side: item.shape.kind == .file ? nil : annotation.side ?? .additions)
    }

    private func annotationHeightChanged(_ token: AnyHashable) {
        guard let record = annotationHosts[token], let item = layoutModel.item(record.annotation.itemID) else { return }
        item.needsLayout = true
        relayout()
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        relayout()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshStyle(force: false)
        relayout()
    }

    private func refreshStyle(force: Bool) {
        let key = StyleKey(
            theme: configuration.theme, colorScheme: configuration.colorScheme, systemIsDark: effectiveAppearance.isDark,
            typography: configuration.typography, overrides: configuration.colorOverrides)
        let style = key != styleKey || force ? Self.makeStyle(key) : layoutModel.style
        styleKey = key
        layoutModel.setConfiguration(configuration, style: style)
        needsFullRedraw = true
        stickyHeader.needsDisplay = true
    }

    private static func makeStyle(_ key: StyleKey) -> StyleContext {
        let theme = (try? ResolvedDiffsTheme.resolve(key.theme))
            ?? ResolvedDiffsTheme(light: ThemeColorInputs(fg: .black, bg: .white), dark: ThemeColorInputs(fg: .white, bg: .black), baseThemeType: nil, slots: .pair(dark: "pierre-dark", light: "pierre-light"))
        return StyleContext(typography: key.typography, theme: theme, themeType: key.colorScheme, systemIsDark: key.systemIsDark, overrides: key.overrides)
    }

    private var viewport: CGRect { scrollView.contentView.bounds }

    /// Lays out the document around the viewport, keeping what the user is
    /// reading in place, and places hosted views.
    private func relayout(materializing pinned: String? = nil) {
        guard !isLayingOut else {
            needsRelayout = true
            return
        }
        isLayingOut = true
        defer { isLayingOut = false }
        repeat {
            needsRelayout = false
            let width = scrollView.contentSize.width
            guard width > 0 else { return }
            layoutModel.setWidth(width)
            layoutModel.updateGeometry()
            for record in annotationHosts.values {
                let newWidth = annotationWidth(record.annotation)
                if newWidth != record.host.width {
                    record.host.setWidth(newWidth)
                    layoutModel.item(record.annotation.itemID)?.needsLayout = true
                }
            }
            let anchor = captureAnchor()
            let visible = viewport
            let overscan = visible.height * configuration.overscan
            let changed = layoutModel.layout(
                materializing: (visible.minY - overscan) ... (visible.maxY + overscan),
                keeping: (visible.minY - 3 * overscan - visible.height) ... (visible.maxY + 3 * overscan + visible.height),
                alsoMaterializing: pinned)
            let size = CGSize(width: width, height: max(layoutModel.contentHeight, visible.height))
            if documentView.frame.size != size { documentView.frame = CGRect(origin: .zero, size: size) }
            restore(anchor)
            if changed || needsFullRedraw {
                placeHostedViews()
                documentView.needsDisplay = true
                needsFullRedraw = false
            } else {
                placeAccessories()
            }
            requestHighlights()
            highlightsImmediately = false
            updateStickyHeader()
            updateTopItem()
        } while needsRelayout
    }

    private struct Anchor {
        var itemID: String
        var generation: Int
        var row: Int?
        /// Distance from the anchored item or row's top to the viewport top.
        var offset: CGFloat
    }

    private func captureAnchor() -> Anchor? {
        let top = viewport.minY
        guard top > 0, let index = layoutModel.itemIndex(at: top) else { return nil }
        let item = layoutModel.items[index]
        if let row = item.rowIndex(at: top, showsHeaders: configuration.showsHeaders), let frame = item.rowFrame(row, showsHeaders: configuration.showsHeaders, width: 0) {
            return Anchor(itemID: item.id, generation: item.generation, row: row, offset: top - frame.minY)
        }
        return Anchor(itemID: item.id, generation: item.generation, row: nil, offset: top - item.top)
    }

    private func restore(_ anchor: Anchor?) {
        guard let anchor, let item = layoutModel.item(anchor.itemID) else { return }
        var top = item.top + anchor.offset
        if let row = anchor.row, item.generation == anchor.generation, let frame = item.rowFrame(row, showsHeaders: configuration.showsHeaders, width: 0) {
            top = frame.minY + anchor.offset
        }
        if abs(top - viewport.minY) > 0.5 { setScrollTop(top) }
    }

    private func placeHostedViews() {
        var placed: Set<AnyHashable> = []
        for item in layoutModel.items where item.hasBody {
            for (token, frame) in item.annotationFrames(showsHeaders: configuration.showsHeaders, height: layoutModel.annotationHeight) {
                guard let record = annotationHosts[token] else { continue }
                record.host.view.frame = frame
                record.host.view.isHidden = false
                placed.insert(token)
            }
        }
        for (token, record) in annotationHosts where !placed.contains(token) {
            record.host.view.isHidden = true
        }
        placeAccessories()
    }

    private var hasAccessories: Bool { Accessory.self != EmptyView.self && configuration.showsHeaders }

    private func placeAccessories() {
        guard hasAccessories else { return }
        let visible = viewport
        let reach = visible.height * configuration.overscan
        for item in layoutModel.items(in: visible.minY - reach, visible.maxY + reach) where accessoryHosts[item.id] == nil {
            let id = item.id
            let host = AccessoryHost(content: accessoryContent(item.item)) { [weak self] _ in self?.accessorySizeChanged(id) }
            documentView.addSubview(host.view)
            accessoryHosts[id] = host
        }
        for (id, host) in accessoryHosts {
            guard let item = layoutModel.item(id) else { continue }
            documentView.accessoryWidths[id] = host.size.width
            guard id != stickyHeader.itemID else { continue }
            if host.view.superview !== documentView { documentView.addSubview(host.view) }
            host.view.frame = accessoryFrame(host.size, headerTop: item.top)
        }
    }

    private func accessoryFrame(_ size: CGSize, headerTop: CGFloat) -> CGRect {
        CGRect(x: scrollView.contentSize.width - HeaderPainter.paddingInline - size.width, y: headerTop + ((Metrics.headerHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
    }

    private func accessorySizeChanged(_ id: String) {
        guard let item = layoutModel.item(id) else { return }
        placeAccessories()
        documentView.redrawItems([id])
        if stickyHeader.itemID == id { updateStickyHeader() }
        _ = item
    }

    // MARK: Viewport

    @objc private func viewportDidChange() {
        guard !isLayingOut else { return }
        let visible = viewport
        let overscan = visible.height * configuration.overscan
        let needsRows = layoutModel.items(in: visible.minY - overscan, visible.maxY + overscan).contains { !$0.hasBody && !$0.isCollapsed }
        if needsRows {
            relayout()
        } else {
            placeAccessories()
            requestHighlights()
            updateStickyHeader()
            updateTopItem()
        }
    }

    private func updateStickyHeader() {
        let top = viewport.minY
        guard configuration.stickyHeaders, configuration.showsHeaders, let index = layoutModel.itemIndex(at: top) else {
            unstick()
            return
        }
        let item = layoutModel.items[index]
        guard !item.isCollapsed, top > item.top else {
            unstick()
            return
        }
        if stickyHeader.itemID != item.id { unstick() }
        let accessory = accessoryHosts[item.id]
        stickyHeader.show(item, style: layoutModel.style, accessoryWidth: accessory?.size.width ?? 0)
        let pushed = min(0, item.bottom - top - Metrics.headerHeight)
        stickyHeader.frame = CGRect(x: 0, y: pushed, width: scrollView.contentSize.width, height: Metrics.headerHeight)
        if let accessory {
            if accessory.view.superview !== stickyHeader { stickyHeader.addSubview(accessory.view) }
            accessory.view.frame = accessoryFrame(accessory.size, headerTop: 0)
        }
    }

    private func unstick() {
        if let id = stickyHeader.itemID, let host = accessoryHosts[id], let item = layoutModel.item(id) {
            documentView.addSubview(host.view)
            host.view.frame = accessoryFrame(host.size, headerTop: item.top)
        }
        stickyHeader.hide()
    }

    private func updateTopItem() {
        let id = layoutModel.itemIndex(at: viewport.minY + 1).map { layoutModel.items[$0].id }
        guard id != topItemID else { return }
        topItemID = id
        delegate?.diffView(self, didScrollToItem: id)
    }

    // MARK: Highlighting

    /// Highlights items near the viewport, before they scroll in. Content
    /// shown by an update is highlighted at once when small, so it never
    /// appears plain; while scrolling nothing blocks a frame.
    private func requestHighlights() {
        let visible = viewport
        let reach = visible.height * (configuration.overscan + configuration.prefetch)
        for item in layoutModel.items(in: visible.minY - reach, visible.maxY + reach) where item.highlighted == nil && !item.isCollapsed {
            requestHighlight(item, immediately: highlightsImmediately && item.top < visible.maxY && item.bottom > visible.minY)
        }
    }

    private enum HighlightRequest {
        case diff(FileDiffMetadata, RenderDiffOptions, plainText: Bool)
        case file(FileContents, lineCount: Int, RenderFileOptions, plainText: Bool)
    }

    private func highlightRequest(for item: ItemModel) -> HighlightRequest? {
        switch item.source {
        case .diff(let diff):
            return .diff(diff, configuration.renderDiffOptions, plainText: max(diff.additionLines.count, diff.deletionLines.count) > configuration.tokenizeMaxLength)
        case .conflicted(let conflicted):
            var options = configuration.renderDiffOptions
            options.lineDiffType = .none
            return .diff(conflicted.diff, options, plainText: conflicted.diff.additionLines.count > configuration.tokenizeMaxLength)
        case .file(let file, let lines):
            return .file(file, lineCount: lines.count, configuration.renderFileOptions, plainText: lines.count > configuration.tokenizeMaxLength)
        }
    }

    private func requestHighlight(_ item: ItemModel, immediately: Bool) {
        let generation = item.generation
        if let existing = highlightTasks[item.id], existing.generation == generation { return }
        guard let request = highlightRequest(for: item) else { return }
        let id = item.id
        let service = highlightService
        let limit = configuration.synchronousHighlightLineLimit
        let task: Task<Void, Never>
        switch request {
        case .diff(let diff, let options, let plainText):
            if immediately, !plainText, let result = service.immediateResult(for: diff, options: options, lineLimit: limit) {
                applyHighlight(.diff(result), to: id, generation: generation)
                return
            }
            task = Task { [weak self] in
                guard let result = try? await service.highlight(diff, options: options, plainText: plainText) else { return }
                self?.applyHighlight(.diff(result), to: id, generation: generation)
            }
        case .file(let file, let lineCount, let options, let plainText):
            if immediately, !plainText, let result = service.immediateResult(for: file, lineCount: lineCount, options: options, lineLimit: limit) {
                applyHighlight(.file(result), to: id, generation: generation)
                return
            }
            task = Task { [weak self] in
                guard let result = try? await service.highlight(file, options: options, plainText: plainText) else { return }
                self?.applyHighlight(.file(result), to: id, generation: generation)
            }
        }
        highlightTasks[id] = (generation, task)
    }

    private func applyHighlight(_ highlighted: Highlighted, to id: String, generation: Int) {
        if highlightTasks[id]?.generation == generation { highlightTasks[id] = nil }
        guard let item = layoutModel.item(id), item.generation == generation else { return }
        let wraps = configuration.overflow == .wrap
        item.setHighlighted(highlighted, wraps: wraps)
        if wraps, !isLayingOut {
            relayout()
        } else {
            documentView.redrawItems([id])
        }
    }

    private func cancelHighlight(_ id: String) {
        highlightTasks.removeValue(forKey: id)?.task.cancel()
    }

    private func cancelHighlights() {
        for (_, entry) in highlightTasks { entry.task.cancel() }
        highlightTasks.removeAll()
    }

    // MARK: Document events

    /// Reveals hidden context around a hunk, as its separator's buttons do.
    /// A partial diff loads its full files first when
    /// `DiffConfiguration.loadsFullFiles` is set.
    public func expand(hunk: Int, inItem itemID: String, direction: ExpansionDirection = .both, all: Bool = false) {
        guard let item = layoutModel.item(itemID) else { return }
        documentView(documentView, expand: item, hunk: hunk, direction: direction, all: all)
    }

    func documentView(_ view: DocumentView, expand item: ItemModel, hunk: Int, direction: ExpansionDirection, all: Bool) {
        item.expand(hunk: hunk, direction: direction, lineCount: all ? Int.max : configuration.expansionLineCount)
        if configuration.loadsFullFiles, case .diff(let diff) = item.source, canHydrateDiff(diff), !item.isLoadingFiles {
            loadFiles(for: item, diff: diff)
        }
        relayout()
    }

    private func loadFiles(for item: ItemModel, diff: FileDiffMetadata) {
        item.isLoadingFiles = true
        let id = item.id
        Task { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            let files = try? await delegate.diffView(self, loadFilesFor: diff, itemID: id)
            guard let item = self.layoutModel.item(id) else { return }
            item.isLoadingFiles = false
            guard let files, case .diff(diff) = item.source, let hydrated = try? hydratePartialDiff(diff, files: files) else { return }
            self.cancelHighlight(id)
            item.hydrate(hydrated, configuration: self.configuration)
            self.relayout()
        }
    }

    func documentView(_ view: DocumentView, resolve item: ItemModel, conflict: Int, resolution: MergeConflictResolution) {
        guard case .conflicted(let conflicted) = item.source,
              let state = try? resolveUnresolvedConflict(fileDiff: conflicted.diff, actions: conflicted.actions, conflictIndex: conflict, resolution: resolution, previousFile: conflicted.file)
        else { return }
        delegate?.diffView(self, didResolveConflict: DiffConflictResolution(itemID: item.id, conflictIndex: conflict, resolution: resolution, file: state.file))
    }

    func documentView(_ view: DocumentView, didChangeLineSelection selection: DiffLineSelection?) {
        delegate?.diffView(self, didChangeLineSelection: selection)
    }

    func documentView(_ view: DocumentView, didRequestGutterAction selection: DiffLineSelection) {
        delegate?.diffView(self, didRequestGutterActionFor: selection)
    }

    // MARK: Scrolling

    /// Scrolls to an item, line or range.
    public func scroll(to target: DiffScrollTarget) {
        if case .item = target.location {} else if let id = target.itemID, layoutModel.item(id)?.hasBody == false {
            relayout(materializing: id)
        }
        guard let destination = scroll.destination(for: target, in: self) else { return }
        let distance = abs(destination - viewport.minY)
        let smooth = target.animation == .smooth || (target.animation == .automatic && distance < viewport.height * 2)
        guard smooth else {
            stopAnimation()
            setScrollTop(destination)
            return
        }
        scroll.begin(target: target, from: viewport.minY, at: CACurrentMediaTime() * 1000, in: self)
        if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(animationFrame(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func animationFrame(_ link: CADisplayLink) {
        stepScrollAnimation(at: link.targetTimestamp * 1000)
    }

    /// Advances smooth scrolling to `now`, in milliseconds.
    func stepScrollAnimation(at now: Double) {
        guard let position = scroll.step(at: now, in: self, settings: configuration.smoothScrolling) else {
            stopAnimation()
            return
        }
        setScrollTop(position)
        if !scroll.isAnimating { stopAnimation() }
    }

    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        scroll.stop()
    }

    public override func scrollWheel(with event: NSEvent) {
        if displayLink != nil { stopAnimation() }
        super.scrollWheel(with: event)
    }

    private func setScrollTop(_ value: CGFloat) {
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: clampScrollTop(value)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func clampScrollTop(_ value: CGFloat) -> CGFloat {
        max(0, min(value, max(0, documentView.frame.height - viewport.height)))
    }

    var scrollTop: CGFloat { viewport.minY }
    var viewportHeight: CGFloat { viewport.height }
    var stickyOffset: CGFloat { configuration.stickyHeaders && configuration.showsHeaders ? Metrics.headerHeight : 0 }

    /// A target's frame in document coordinates.
    func targetRect(_ location: DiffScrollTarget.Location) -> CGRect? {
        switch location {
        case .item(let id):
            guard let item = layoutModel.item(id) else { return nil }
            return CGRect(x: 0, y: item.top, width: 0, height: item.height)
        case .line(let id, let lineNumber, let side):
            return lineRect(id, lineNumber, side)
        case .range(let id, let range):
            guard let start = lineRect(id, range.start, range.side), let end = lineRect(id, range.end, range.endSide ?? range.side) else { return nil }
            return start.union(end)
        }
    }

    private func lineRect(_ id: String, _ lineNumber: Int, _ side: AnnotationSide?) -> CGRect? {
        guard let item = layoutModel.item(id), let row = item.row(forLineNumber: lineNumber, side: item.shape.kind == .file ? nil : side ?? .additions) else { return nil }
        return item.rowFrame(row, showsHeaders: configuration.showsHeaders, width: 0)
    }
}

extension DiffView where Accessory == EmptyView {
    public convenience init(configuration: DiffConfiguration = DiffConfiguration(), highlightService: HighlightService = .shared, @ViewBuilder annotation: @escaping (AnnotationID) -> Annotation) {
        self.init(configuration: configuration, highlightService: highlightService, annotation: annotation) { _ in EmptyView() }
    }
}

extension DiffView where AnnotationID == NoAnnotation, Annotation == EmptyView, Accessory == EmptyView {
    public convenience init(configuration: DiffConfiguration = DiffConfiguration(), highlightService: HighlightService = .shared) {
        self.init(configuration: configuration, highlightService: highlightService, annotation: NoAnnotation.content) { _ in EmptyView() }
    }
}

extension DiffScrollTarget {
    var itemID: String? {
        switch location {
        case .item(let id), .line(let id, _, _), .range(let id, _): id
        }
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
            .map { [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua].contains($0) } ?? false
    }
}
