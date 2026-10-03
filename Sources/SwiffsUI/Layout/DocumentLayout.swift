import AppKit
import SwiffsCore

/// Every item's place in one scrolling document. Items near the viewport
/// have their rows built and laid out; the rest are estimated.
final class DocumentLayout {
    private(set) var configuration: DiffConfiguration
    private(set) var style: StyleContext
    private(set) var items: [ItemModel] = []
    private var indexByID: [String: Int] = [:]
    private(set) var width: CGFloat = 0
    private(set) var contentHeight: CGFloat = 0
    /// The height of an annotation's content, by its token.
    var annotationHeight: (AnyHashable) -> CGFloat = { _ in 0 }
    init(configuration: DiffConfiguration, style: StyleContext) {
        self.configuration = configuration
        self.style = style
    }

    func item(_ id: String) -> ItemModel? {
        indexByID[id].map { items[$0] }
    }

    func index(of id: String) -> Int? {
        indexByID[id]
    }

    /// Takes new items and their annotations, keeping the state of items
    /// whose id remains. Returns the items whose content changed and those
    /// removed.
    func setItems(_ newItems: [DiffItem], annotations: [String: [AnnotationKey: [AnyHashable]]]) -> (changed: [ItemModel], removed: [ItemModel]) {
        var previous = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var changed: [ItemModel] = []
        items = newItems.map { newItem in
            let model: ItemModel
            if let existing = previous.removeValue(forKey: newItem.id) {
                let contentChanged = existing.item.content != newItem.content
                _ = existing.update(newItem, configuration: configuration)
                if contentChanged { changed.append(existing) }
                model = existing
            } else {
                model = ItemModel(item: newItem, configuration: configuration)
                changed.append(model)
            }
            model.setAnnotations(annotations[newItem.id] ?? [:])
            return model
        }
        indexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        return (changed, Array(previous.values))
    }

    func setConfiguration(_ configuration: DiffConfiguration, style: StyleContext) {
        let old = self.configuration
        self.configuration = configuration
        let styleChanged = style !== self.style
        self.style = style
        for item in items {
            item.configurationChanged(from: old, to: configuration)
            if styleChanged { item.dropLineLayouts() }
        }
    }

    func setWidth(_ width: CGFloat) {
        guard width != self.width else { return }
        self.width = width
        for item in items {
            item.needsLayout = true
            if configuration.overflow == .wrap { item.dropLineLayouts() }
        }
    }

    /// Places every item's columns at the current width.
    func updateGeometry() {
        guard width > 0 else { return }
        for item in items { item.updateGeometry(width: width, configuration: configuration, ch: style.ch) }
    }

    /// Lays out items that need it, building rows for those within
    /// `materializing` and releasing rows of those beyond `keeping`, and
    /// positions every item.
    /// Returns whether anything moved or was laid out again.
    @discardableResult
    func layout(materializing: ClosedRange<CGFloat>, keeping: ClosedRange<CGFloat>, alsoMaterializing pinned: String? = nil) -> Bool {
        guard width > 0 else { return false }
        var changed = false
        var y = configuration.padding
        for (index, item) in items.enumerated() {
            if index > 0 { y += configuration.itemSpacing }
            if item.top != y { changed = true }
            item.top = y
            let near = (y <= materializing.upperBound && y + item.height >= materializing.lowerBound) || item.id == pinned
            let far = (y > keeping.upperBound || y + item.height < keeping.lowerBound) && item.id != pinned
            if far, item.hasBody {
                item.release()
            }
            if item.needsLayout || (near && !item.hasBody && !item.isCollapsed) {
                item.layout(width: width, materialize: near, configuration: configuration, style: style, annotationHeight: annotationHeight)
                changed = true
            }
            y += item.height
        }
        let height = items.isEmpty ? 0 : y + configuration.padding
        if height != contentHeight { changed = true }
        contentHeight = height
        return changed
    }

    /// The first item whose bottom is below `y`.
    func firstItemIndex(atOrBelow y: CGFloat) -> Int {
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].bottom <= y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The item containing `y`, if any.
    func itemIndex(at y: CGFloat) -> Int? {
        let index = firstItemIndex(atOrBelow: y)
        guard index < items.count, items[index].top <= y else { return nil }
        return index
    }

    /// Items intersecting a vertical range.
    func items(in minY: CGFloat, _ maxY: CGFloat) -> ArraySlice<ItemModel> {
        let start = firstItemIndex(atOrBelow: minY)
        var end = start
        while end < items.count, items[end].top < maxY { end += 1 }
        return items[start ..< end]
    }
}

extension ItemModel {
    /// Document y of the body's top.
    func bodyTop(showsHeaders: Bool) -> CGFloat {
        top + (showsHeaders ? Metrics.headerHeight : 0)
    }

    /// The row at a document y, if the rows are built.
    func rowIndex(at y: CGFloat, showsHeaders: Bool) -> Int? {
        guard let body, !body.rowTops.isEmpty else { return nil }
        let local = y - bodyTop(showsHeaders: showsHeaders)
        var low = 0
        var high = body.rowTops.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if local < body.rowTops[mid] {
                high = mid - 1
            } else if local >= body.rowTops[mid] + body.rowHeights[mid] {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    /// The first row whose bottom is below a document y.
    func firstRowIndex(atOrBelow y: CGFloat, showsHeaders: Bool) -> Int {
        guard let body else { return 0 }
        let local = y - bodyTop(showsHeaders: showsHeaders)
        var low = 0
        var high = body.rowTops.count
        while low < high {
            let mid = (low + high) / 2
            if body.rowTops[mid] + body.rowHeights[mid] <= local { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// A row's frame in document coordinates.
    func rowFrame(_ row: Int, showsHeaders: Bool, width: CGFloat) -> CGRect? {
        guard let body, row < body.rowTops.count else { return nil }
        return CGRect(x: 0, y: bodyTop(showsHeaders: showsHeaders) + body.rowTops[row], width: width, height: body.rowHeights[row])
    }

    /// The row showing a line, if the rows are built.
    func row(forLineNumber lineNumber: Int, side: AnnotationSide?) -> Int? {
        guard let body else { return nil }
        for (index, row) in body.rows.enumerated() {
            for cell in row.cells {
                if case .line(let line)? = cell, line.lineNumber == lineNumber, side == nil || shape.kind == .file || line.side == side {
                    return index
                }
            }
        }
        return nil
    }
}
