// Floating popovers placed over the editor (the native counterpart of
// `editor/popover.ts`): marker messages and selection actions.

import AppKit

/// A rounded floating container placed above or below an anchor rect.
final class EditorPopoverView: NSView {
    private let background = NSVisualEffectView()
    let content: NSView

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(background)
        addSubview(content)
        shadow = NSShadow()
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 6
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    static let padding: CGFloat = 8

    /// Sizes to the content and positions relative to an anchor rect in the
    /// container's coordinates, above when there is room.
    func place(in container: NSView, anchor: CGRect, maxWidth: CGFloat = 420, preferAbove: Bool = true) {
        let padding = Self.padding
        content.frame.size.width = min(maxWidth, container.bounds.width - 24) - padding * 2
        content.layoutSubtreeIfNeeded()
        var size = content.fittingSize
        if size.width <= 0 || size.height <= 0 { size = content.intrinsicContentSize }
        size.width = min(size.width, maxWidth - padding * 2)
        let width = size.width + padding * 2
        let height = size.height + padding * 2
        var x = min(max(8, anchor.minX), container.bounds.width - width - 8)
        x = max(8, x)
        let above = anchor.minY - height - 4
        let below = anchor.maxY + 4
        let y = preferAbove && above >= 0 ? above : below
        frame = CGRect(x: x, y: y, width: width, height: height)
        background.frame = bounds
        content.frame = CGRect(x: padding, y: padding, width: size.width, height: size.height)
    }
}

/// A wrapping message label for marker popovers.
@MainActor
func makeMarkerMessageView(_ message: String, source: String?) -> NSView {
    let text = source.map { "\(message)  (\($0))" } ?? message
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: 12)
    label.preferredMaxLayoutWidth = 380
    label.isSelectable = true
    return label
}
