import AppKit
import SwiftUI

/// Content at a fixed width and its ideal height, reporting that height
/// whenever it changes.
struct WidthBoundContent<Content: View>: View {
    let content: Content
    let width: CGFloat
    let report: (CGFloat) -> Void

    var body: some View {
        content
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { report($0) }
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Content at its ideal size, reporting that size whenever it changes.
struct IdealSizeContent<Content: View>: View {
    let content: Content
    let report: (CGSize) -> Void

    var body: some View {
        content
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: \.size) { report($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// SwiftUI content placed by frame in the document, sized by the layout
/// contract: measured with `sizeThatFits` when created or given a new
/// width, then following the sizes the content reports.
/// `NSHostingView.fittingSize` and `intrinsicContentSize` ignore the width
/// they are given, so they are never used to measure.
final class AnnotationHost<Content: View> {
    let view: NSHostingView<WidthBoundContent<Content>>
    private(set) var width: CGFloat
    private(set) var height: CGFloat
    private var content: Content
    /// Called when the content reports a new height.
    private let heightChanged: (CGFloat) -> Void

    init(content: Content, width: CGFloat, heightChanged: @escaping (CGFloat) -> Void) {
        self.content = content
        self.width = width
        self.heightChanged = heightChanged
        height = Self.measure(content, width: width)
        view = NSHostingView(rootView: WidthBoundContent(content: content, width: width, report: { _ in }))
        view.sizingOptions = []
        view.rootView = root()
    }

    /// The content's ideal height at a width.
    static func measure(_ content: Content, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let controller = NSHostingController(rootView: content.frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
        return max(0, controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    func setContent(_ content: Content) {
        self.content = content
        view.rootView = root()
    }

    /// Gives the content a new width, measuring it at once so the next frame
    /// is laid out at the right height.
    func setWidth(_ width: CGFloat) {
        guard width != self.width else { return }
        self.width = width
        height = Self.measure(content, width: width)
        view.rootView = root()
    }

    private func root() -> WidthBoundContent<Content> {
        WidthBoundContent(content: content, width: width) { [weak self] height in
            guard let self, abs(height - self.height) > 0.25 else { return }
            self.height = height
            self.heightChanged(height)
        }
    }
}

/// A header accessory: SwiftUI content at its ideal size.
final class AccessoryHost<Content: View> {
    let view: NSHostingView<IdealSizeContent<Content>>
    private(set) var size: CGSize
    private var content: Content
    private let sizeChanged: (CGSize) -> Void

    init(content: Content, sizeChanged: @escaping (CGSize) -> Void) {
        self.content = content
        self.sizeChanged = sizeChanged
        size = NSHostingController(rootView: content.fixedSize()).sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        view = NSHostingView(rootView: IdealSizeContent(content: content, report: { _ in }))
        view.sizingOptions = []
        view.rootView = root()
    }

    func setContent(_ content: Content) {
        self.content = content
        view.rootView = root()
    }

    private func root() -> IdealSizeContent<Content> {
        IdealSizeContent(content: content) { [weak self] size in
            guard let self, size != self.size else { return }
            self.size = size
            self.sizeChanged(size)
        }
    }
}
