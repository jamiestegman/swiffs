import AppKit

/// The header of the item at the top of the viewport, drawn over the
/// scrolling document. The item's accessory moves into it while it shows.
final class StickyHeaderView: NSView {
    private(set) var itemID: String?
    private var content: HeaderContent?
    private var style: StyleContext?
    private var accessoryWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    func show(_ item: ItemModel, style: StyleContext, accessoryWidth: CGFloat) {
        let content = HeaderContent(item)
        if item.id != itemID || content != self.content || style !== self.style || accessoryWidth != self.accessoryWidth {
            needsDisplay = true
        }
        itemID = item.id
        self.content = content
        self.style = style
        self.accessoryWidth = accessoryWidth
        isHidden = false
    }

    func hide() {
        itemID = nil
        isHidden = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let content, let style, let context = NSGraphicsContext.current?.cgContext else { return }
        HeaderPainter(content: content, style: style).draw(in: bounds, accessoryWidth: accessoryWidth, context: context)
    }
}
