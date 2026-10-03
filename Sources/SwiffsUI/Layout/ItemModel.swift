import AppKit
import SwiffsCore
import SwiffsHighlight

/// An item's content, parsed once per content.
enum ItemSource {
    case diff(FileDiffMetadata)
    case file(FileContents, lines: [String])
    case conflicted(ConflictedFile)
}

struct ConflictedFile {
    var file: FileContents
    var diff: FileDiffMetadata
    var actions: [MergeConflictDiffAction?]
    var markerRows: [MergeConflictMarkerRow]
}

/// An item's highlighted lines.
enum Highlighted {
    case diff(ThemedDiffResult)
    /// A file's lines; nil for lines not highlighted yet.
    case file([HighlightedLine?])
}

/// How an item's content changed.
enum ContentChange {
    case none
    case replaced
    /// A file gained text at its end.
    case grew(appended: String)
}

/// An item's rows and their heights at one width.
struct ItemBody {
    var rows: [RenderRow]
    /// The row holding each annotated line's annotations.
    var annotationRows: [AnnotationKey: Int] = [:]
    /// Row offsets from the top of the body.
    var rowTops: [CGFloat] = []
    var rowHeights: [CGFloat] = []
    var height: CGFloat = 0
}

struct LineKey: Hashable {
    var side: AnnotationSide
    var lineIndex: Int
}

/// One item: its parsed content, rows, heights, highlighting and caches.
/// Positions are in document coordinates.
final class ItemModel {
    private(set) var item: DiffItem
    private(set) var source: ItemSource
    private(set) var shape: ItemShape
    private var parseFailure: String?
    private var rowFailure: String?
    var expandedHunks: [Int: HunkExpansionRegion] = [:]
    /// Annotation tokens on each line, in input order.
    private(set) var annotations: [AnnotationKey: [AnyHashable]] = [:]
    var top: CGFloat = 0
    private(set) var height: CGFloat = 0
    private(set) var body: ItemBody?
    private(set) var geometry: ItemGeometry?
    private(set) var highlighted: Highlighted?
    /// Horizontal offset of the code, shared by both columns.
    var scrollX: CGFloat = 0
    private var lineLayouts: [LineKey: LineLayout] = [:]
    /// Widest laid out line in each cell slot.
    private var widestLine: [Int: CGFloat] = [:]
    /// The body's height when its rows were released, used until they are
    /// built again.
    private var releasedBodyHeight: CGFloat?
    /// Set when the rows must be rebuilt.
    private var rowsAreStale = true
    /// A partial diff is having its full files loaded.
    var isLoadingFiles = false
    /// Set when the item must be laid out again.
    var needsLayout = true
    /// Changes whenever the lines to highlight change.
    private(set) var generation = 0

    init(item: DiffItem, configuration: DiffConfiguration) {
        self.item = item
        (source, parseFailure) = Self.parse(item.content)
        shape = Self.shape(source, configuration: configuration)
    }

    var id: String { item.id }
    /// Why the item cannot be shown as it is.
    var failure: String? { parseFailure ?? rowFailure }

    /// The diff whose rows the item shows, if it is a diff or conflicted file.
    var diff: FileDiffMetadata? {
        switch source {
        case .diff(let diff): diff
        case .conflicted(let conflicted): conflicted.diff
        case .file: nil
        }
    }
    var bottom: CGFloat { top + height }
    var isCollapsed: Bool { item.isCollapsed }
    var hasBody: Bool { body != nil }

    // MARK: Updates

    /// Takes a new value for the item and says how its content changed.
    @discardableResult
    func update(_ newItem: DiffItem, configuration: DiffConfiguration) -> ContentChange {
        guard newItem != item else { return .none }
        let old = item
        item = newItem
        needsLayout = true
        if case .file(let file) = newItem.content, let appended = appendedText(from: old.content, to: newItem.content) {
            grow(file, appended: appended)
            return .grew(appended: appended)
        }
        guard newItem.content != old.content else { return .none }
        (source, parseFailure) = Self.parse(newItem.content)
        shape = Self.shape(source, configuration: configuration)
        expandedHunks = [:]
        highlighted = nil
        generation += 1
        invalidateRows()
        dropLineLayouts()
        return .replaced
    }

    /// The text a file gained at its end, if that is all that changed.
    private func appendedText(from old: DiffItem.Content, to new: DiffItem.Content) -> String? {
        guard case .file(let oldFile) = old, case .file(let newFile) = new, oldFile.name == newFile.name, oldFile.lang == newFile.lang,
              newFile.contents.utf8.count > oldFile.contents.utf8.count, newFile.contents.hasPrefix(oldFile.contents)
        else { return nil }
        return String(newFile.contents.utf8.dropFirst(oldFile.contents.utf8.count))
    }

    /// Appends text to a file, keeping every line before the last one as it
    /// was: its row, layout and highlighting.
    private func grow(_ file: FileContents, appended: String) {
        guard case .file(_, var lines) = source else { return }
        let last = lines.popLast() ?? ""
        let firstChanged = lines.count
        lines.append(contentsOf: linesFromFileContents(last + appended))
        source = .file(file, lines: lines)
        shape.totalLines = lines.count
        if case .file(var highlightedLines)? = highlighted {
            highlightedLines.removeSubrange(min(firstChanged, highlightedLines.count)...)
            highlighted = .file(highlightedLines)
        }
        lineLayouts = lineLayouts.filter { $0.key.lineIndex < firstChanged }
        invalidateRows()
    }

    /// Replaces a file's highlighting from a line on.
    func setHighlightedLines(from first: Int, _ lines: [HighlightedLine]) {
        var highlightedLines: [HighlightedLine?]
        if case .file(let existing)? = highlighted { highlightedLines = existing } else { highlightedLines = [] }
        if highlightedLines.count < first { highlightedLines.append(contentsOf: [HighlightedLine?](repeating: nil, count: first - highlightedLines.count)) }
        highlightedLines.replaceSubrange(first..., with: lines.map { Optional($0) })
        highlighted = .file(highlightedLines)
        lineLayouts = lineLayouts.filter { $0.key.lineIndex < first }
    }

    /// Replaces the diff with one whose full files are loaded, keeping
    /// expanded hunks.
    func hydrate(_ diff: FileDiffMetadata, configuration: DiffConfiguration) {
        guard case .diff = source else { return }
        source = .diff(diff)
        shape = Self.shape(source, configuration: configuration)
        highlighted = nil
        generation += 1
        needsLayout = true
        invalidateRows()
        dropLineLayouts()
    }

    func setAnnotations(_ annotations: [AnnotationKey: [AnyHashable]]) {
        guard annotations != self.annotations else { return }
        if Set(annotations.keys) != Set(self.annotations.keys) { invalidateRows() }
        self.annotations = annotations
        needsLayout = true
    }

    func configurationChanged(from old: DiffConfiguration, to new: DiffConfiguration) {
        shape = Self.shape(source, configuration: new)
        needsLayout = true
        if new.rowsDiffer(from: old) { invalidateRows() }
        if new.overflow != old.overflow || new.typography != old.typography || new.theme != old.theme || new.lineDiffType != old.lineDiffType {
            dropLineLayouts()
        }
        if new.theme != old.theme || new.lineDiffType != old.lineDiffType || new.tokenizeMaxLineLength != old.tokenizeMaxLineLength
            || new.tokenizeMaxLength != old.tokenizeMaxLength
        {
            highlighted = nil
            generation += 1
        }
    }

    func expand(hunk: Int, direction: ExpansionDirection, lineCount: Int) {
        var region = expandedHunks[hunk] ?? DiffsConstants.defaultExpandedRegion
        func add(_ value: Int) -> Int { value >= Int.max - lineCount ? Int.max / 2 : value + lineCount }
        if direction == .up || direction == .both { region.fromStart = add(region.fromStart) }
        if direction == .down || direction == .both { region.fromEnd = add(region.fromEnd) }
        expandedHunks[hunk] = region
        invalidateRows()
    }

    func setHighlighted(_ highlighted: Highlighted?, wraps: Bool) {
        self.highlighted = highlighted
        dropLineLayouts()
        if wraps { needsLayout = true }
    }

    func invalidateRows() {
        rowsAreStale = true
        releasedBodyHeight = nil
        needsLayout = true
    }

    /// Drops laid out lines, which are rebuilt when next drawn.
    func dropLineLayouts() {
        lineLayouts.removeAll()
        widestLine.removeAll()
    }

    // MARK: Layout

    /// Lays out the header and, when `materialize` is set or rows already
    /// exist, the rows at `width`; otherwise estimates the body.
    func layout(width: CGFloat, materialize: Bool, configuration: DiffConfiguration, style: StyleContext, annotationHeight: (AnyHashable) -> CGFloat) {
        needsLayout = false
        let headerHeight = configuration.showsHeaders ? Metrics.headerHeight : 0
        updateGeometry(width: width, configuration: configuration, ch: style.ch)
        guard let geometry else { return }
        if item.isCollapsed {
            height = headerHeight
            return
        }
        if rowsAreStale, materialize || body != nil {
            buildRows(configuration: configuration)
        }
        guard var body else {
            let estimate = releasedBodyHeight ?? estimateBody(configuration: configuration, lineHeight: style.lineHeight)
                + annotations.values.joined().reduce(0) { $0 + annotationHeight($1) }
            height = headerHeight + estimate
            return
        }
        layoutRows(&body, geometry: geometry, configuration: configuration, style: style, annotationHeight: annotationHeight)
        self.body = body
        height = headerHeight + body.height
    }

    /// Places the item's columns at a width.
    func updateGeometry(width: CGFloat, configuration: DiffConfiguration, ch: CGFloat) {
        let geometry = ItemGeometry(shape: shape, width: width, configuration: configuration, ch: ch)
        guard geometry != self.geometry else { return }
        self.geometry = geometry
        needsLayout = true
    }

    /// Drops the rows and laid out lines of an item far from the viewport,
    /// keeping its height until they are built again.
    func release() {
        guard let body else { return }
        releasedBodyHeight = body.height
        self.body = nil
        rowsAreStale = true
        dropLineLayouts()
        needsLayout = true
    }

    private func estimateBody(configuration: DiffConfiguration, lineHeight: CGFloat) -> CGFloat {
        if failure != nil { return lineHeight + 2 * Metrics.gap }
        let codePadding = (configuration.showsHeaders ? 0 : Metrics.gap) + Metrics.gap
        switch source {
        case .file(_, let lines):
            return CGFloat(lines.count) * lineHeight + codePadding
        case .diff, .conflicted:
            guard let diff else { return lineHeight }
            var metrics = DiffsConstants.defaultVirtualFileMetrics
            metrics.lineHeight = Double(lineHeight)
            let heights = try? computeEstimatedDiffHeights(
                fileDiff: diff, metrics: metrics, disableFileHeader: true, hunkSeparators: configuration.hunkSeparators,
                expandUnchanged: configuration.expandsUnchanged, expandedHunks: .regions(expandedHunks),
                collapsedContextThreshold: configuration.collapsedContextThreshold, canHydratePartialDiff: false)
            guard let heights else { return lineHeight }
            let estimate = (shape.cellCount == 2 ? heights.splitHeight : heights.unifiedHeight) - getVirtualFileHeaderRegion(metrics, disableFileHeader: true)
            return CGFloat(estimate) + (configuration.showsHeaders ? 0 : Metrics.gap)
        }
    }

    private func buildRows(configuration: DiffConfiguration) {
        rowsAreStale = false
        do {
            let rows: [RenderRow]
            switch source {
            case .diff(let diff):
                rows = try buildDiffRows(
                    fileDiff: diff, options: rowOptions(configuration, style: configuration.style), expandedHunks: expandedHunks,
                    deletionAnnotationLines: annotationLines(.deletions), additionAnnotationLines: annotationLines(.additions)
                ).rows
            case .file(_, let lines):
                rows = buildFileRows(lineCount: lines.count, annotationLines: Set(annotations.keys.map(\.lineNumber))).rows
            case .conflicted(let conflicted):
                rows = try buildDiffRows(
                    fileDiff: conflicted.diff, options: rowOptions(configuration, style: .unified), expandedHunks: expandedHunks,
                    deletionAnnotationLines: annotationLines(.deletions), additionAnnotationLines: annotationLines(.additions),
                    injectedRows: MergeConflictInjectedRows(actions: conflicted.actions, markerRows: conflicted.markerRows, fileDiff: conflicted.diff)
                ).rows
            }
            var annotationRows: [AnnotationKey: Int] = [:]
            for (index, row) in rows.enumerated() {
                for case .annotation(let cell)? in row.cells {
                    for key in cell.keys { annotationRows[key] = index }
                }
            }
            body = ItemBody(rows: rows, annotationRows: annotationRows)
            rowFailure = nil
        } catch {
            body = ItemBody(rows: [])
            rowFailure = String(describing: error)
        }
    }

    private func rowOptions(_ configuration: DiffConfiguration, style: DiffStyle) -> DiffRowsOptions {
        DiffRowsOptions(
            diffStyle: style, hunkSeparators: configuration.hunkSeparators, expandUnchanged: configuration.expandsUnchanged,
            collapsedContextThreshold: configuration.collapsedContextThreshold, expansionLineCount: configuration.expansionLineCount,
            canLoadDiffFiles: configuration.loadsFullFiles)
    }

    private func annotationLines(_ side: AnnotationSide) -> Set<Int> {
        Set(annotations.keys.filter { $0.side == side }.map(\.lineNumber))
    }

    private func layoutRows(_ body: inout ItemBody, geometry: ItemGeometry, configuration: DiffConfiguration, style: StyleContext, annotationHeight: (AnyHashable) -> CGFloat) {
        let lineHeight = style.lineHeight
        let wraps = configuration.overflow == .wrap
        body.rowTops.removeAll(keepingCapacity: true)
        body.rowHeights.removeAll(keepingCapacity: true)
        body.rowTops.reserveCapacity(body.rows.count)
        body.rowHeights.reserveCapacity(body.rows.count)
        var y = geometry.codePaddingTop
        for row in body.rows {
            var height: CGFloat = 0
            for column in geometry.columns {
                guard column.cellIndex < row.cells.count, let cell = row.cells[column.cellIndex] else { continue }
                let cellHeight: CGFloat
                switch cell {
                case .line(let line):
                    cellHeight = wraps ? CGFloat(layout(for: line, column: column, geometry: geometry, configuration: configuration, style: style).visualLineCount) * lineHeight : lineHeight
                case .annotation(let annotation):
                    cellHeight = annotation.keys.reduce(0) { total, key in total + (annotations[key] ?? []).reduce(0) { $0 + annotationHeight($1) } }
                case .noNewline, .buffer:
                    cellHeight = lineHeight
                case .separator(let separator):
                    cellHeight = separatorHeight(separator)
                case .injected(let injected):
                    if case .mergeConflictActions = injected.kind {
                        cellHeight = Metrics.conflictActionsHeight
                    } else {
                        cellHeight = lineHeight
                    }
                }
                height = max(height, cellHeight)
            }
            body.rowTops.append(y)
            body.rowHeights.append(height)
            y += height
        }
        if failure != nil {
            y += lineHeight
        }
        body.height = body.rows.isEmpty && failure == nil ? 0 : y + geometry.codePaddingBottom
    }

    /// Where each annotation sits in the document, stacked in its row's
    /// column in the order given.
    func annotationFrames(showsHeaders: Bool, height: (AnyHashable) -> CGFloat) -> [(token: AnyHashable, frame: CGRect)] {
        guard let body, let geometry, !item.isCollapsed else { return [] }
        var frames: [(AnyHashable, CGRect)] = []
        let bodyTop = bodyTop(showsHeaders: showsHeaders)
        for row in Set(body.annotationRows.values).sorted() {
            for column in geometry.columns {
                guard column.cellIndex < body.rows[row].cells.count, case .annotation(let cell)? = body.rows[row].cells[column.cellIndex] else { continue }
                var y = bodyTop + body.rowTops[row]
                for key in cell.keys {
                    for token in annotations[key] ?? [] {
                        let tokenHeight = height(token)
                        frames.append((token, CGRect(x: column.contentMinX, y: y, width: column.contentWidth, height: tokenHeight)))
                        y += tokenHeight
                    }
                }
            }
        }
        return frames
    }

    /// The width an annotation on a line is laid out at.
    func annotationWidth(side: AnnotationSide?) -> CGFloat {
        geometry?.column(for: side)?.contentWidth ?? 0
    }

    // MARK: Lines

    /// The source text of a line, without its line break.
    func text(side: AnnotationSide, lineIndex: Int) -> String {
        let lines: [String]
        if case .file(_, let fileLines) = source {
            lines = fileLines
        } else if let diff {
            lines = side == .deletions ? diff.deletionLines : diff.additionLines
        } else {
            lines = []
        }
        return lineIndex < lines.count ? cleanLastNewline(lines[lineIndex]) : ""
    }

    /// A line with its highlighting, or plain until highlighting arrives.
    func line(side: AnnotationSide, lineIndex: Int, slots: Int) -> HighlightedLine {
        switch highlighted {
        case .diff(let result)?:
            let lines = side == .deletions ? result.deletionLines : result.additionLines
            if lineIndex < lines.count, let line = lines[lineIndex] { return line }
        case .file(let lines)?:
            if lineIndex < lines.count, let line = lines[lineIndex] { return line }
        case nil:
            break
        }
        return .plain(text(side: side, lineIndex: lineIndex), slots: slots)
    }

    /// Lines kept laid out at once; scrolling through larger items lays
    /// evicted lines out again.
    private static let maxLineLayouts = 4096

    func layout(for line: RenderedLine, column: Column, geometry: ItemGeometry, configuration: DiffConfiguration, style: StyleContext) -> LineLayout {
        let key = LineKey(side: line.side, lineIndex: line.lineIndex)
        if let cached = lineLayouts[key] { return cached }
        let wrapWidth = configuration.overflow == .wrap ? max(style.ch * 4, column.contentWidth - geometry.contentPaddingStart - geometry.contentPaddingEnd) : nil
        let highlighted = self.line(side: line.side, lineIndex: line.lineIndex, slots: ThemeSlots(configuration.theme).count)
        let layout = LineLayout.make(highlighted, style: style, wrapWidth: wrapWidth)
        if lineLayouts.count >= Self.maxLineLayouts { lineLayouts.removeAll(keepingCapacity: true) }
        lineLayouts[key] = layout
        widestLine[column.cellIndex] = max(widestLine[column.cellIndex] ?? 0, layout.width)
        return layout
    }

    /// How far the code can scroll horizontally, from the lines laid out so
    /// far.
    func maxScrollX(configuration: DiffConfiguration) -> CGFloat {
        guard configuration.overflow == .scroll, let geometry else { return 0 }
        return geometry.columns.map { column in
            max(0, (widestLine[column.cellIndex] ?? 0) + geometry.contentPaddingStart + geometry.contentPaddingEnd - column.contentWidth)
        }.max() ?? 0
    }

    /// Lays out every line once to learn the horizontal scroll range,
    /// keeping only the widths.
    func measureAllLines(configuration: DiffConfiguration, style: StyleContext) {
        guard let body, let geometry else { return }
        let slots = ThemeSlots(configuration.theme).count
        for row in body.rows {
            for column in geometry.columns {
                guard column.cellIndex < row.cells.count, case .line(let line)? = row.cells[column.cellIndex],
                      lineLayouts[LineKey(side: line.side, lineIndex: line.lineIndex)] == nil
                else { continue }
                let width = LineLayout.make(self.line(side: line.side, lineIndex: line.lineIndex, slots: slots), style: style, wrapWidth: nil).width
                widestLine[column.cellIndex] = max(widestLine[column.cellIndex] ?? 0, width)
            }
        }
    }

    // MARK: Parsing

    private static func parse(_ content: DiffItem.Content) -> (ItemSource, String?) {
        switch content {
        case .diff(let diff):
            return (.diff(diff), nil)
        case .file(let file):
            return (.file(file, lines: linesFromFileContents(file.contents)), nil)
        case .conflicted(let file):
            do {
                let parsed = try parseMergeConflictDiffFromFile(file)
                return (.conflicted(ConflictedFile(file: file, diff: parsed.fileDiff, actions: parsed.actions, markerRows: parsed.markerRows)), nil)
            } catch {
                return (.file(file, lines: linesFromFileContents(file.contents)), String(describing: error))
            }
        }
    }

    private static func shape(_ source: ItemSource, configuration: DiffConfiguration) -> ItemShape {
        switch source {
        case .diff(let diff):
            let split = configuration.style == .split
            let hasDeletions = diff.type != .new
            let hasAdditions = diff.type != .deleted
            return ItemShape(
                kind: .diff, cellCount: split ? 2 : 1, isSplit: split && hasDeletions && hasAdditions,
                hasDeletionsColumn: hasDeletions, hasAdditionsColumn: hasAdditions, totalLines: totalLines(diff), hasConflicts: false)
        case .file(_, let lines):
            return ItemShape(kind: .file, cellCount: 1, isSplit: false, hasDeletionsColumn: false, hasAdditionsColumn: false, totalLines: lines.count, hasConflicts: false)
        case .conflicted(let conflicted):
            return ItemShape(kind: .diff, cellCount: 1, isSplit: false, hasDeletionsColumn: false, hasAdditionsColumn: false, totalLines: totalLines(conflicted.diff), hasConflicts: true)
        }
    }

    private static func totalLines(_ diff: FileDiffMetadata) -> Int {
        max(getTotalLineCountFromHunks(diff.hunks), diff.additionLines.count, diff.deletionLines.count)
    }
}
