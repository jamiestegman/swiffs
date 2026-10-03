import AppKit

/// Several annotations on one line, one above the other, each as wide as
/// the column the grid gives the stack.
final class AnnotationStackView: NSView {
    init(views: [NSView]) {
        super.init(frame: .zero)
        for view in views { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        NSSize(width: bounds.width, height: subviews.reduce(0) { $0 + height(of: $1) })
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for view in subviews {
            let height = height(of: view)
            view.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
        }
    }

    /// An annotation's height at the stack's width, measured as the grid
    /// measures a single annotation.
    private func height(of view: NSView) -> CGFloat {
        view.frame.size.width = bounds.width
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize.height
        return max(0, fitting > 0 ? fitting : view.intrinsicContentSize.height)
    }
}
