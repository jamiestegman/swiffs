import AppKit
import SwiftUI
import SwiffsCore
@testable import SwiffsUI

/// A window hosting SwiftUI content, as apps host a diff list.
final class HostingWindow<Content: View> {
    let window: NSWindow
    let hostingView: NSHostingView<Content>

    init(_ content: Content, size: CGSize = CGSize(width: 800, height: 600)) {
        hostingView = NSHostingView(rootView: content)
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        layout()
    }

    isolated deinit {
        window.close()
    }

    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func resize(width: CGFloat) {
        window.setContentSize(CGSize(width: width, height: window.contentView?.frame.height ?? 600))
        layout()
    }

    /// The first view of a type in the window.
    func find<View: NSView>(_ type: View.Type) -> View? {
        func search(_ view: NSView) -> View? {
            if let match = view as? View { return match }
            for subview in view.subviews {
                if let match = search(subview) { return match }
            }
            return nil
        }
        return search(hostingView)
    }

    /// Sends a press and release at a point in a view.
    func click(_ point: CGPoint, in view: NSView, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) {
        let location = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            send(type, at: location, modifiers: modifiers, clickCount: clickCount, to: view)
        }
    }

    /// Presses at one point, drags to another and releases.
    func drag(from start: CGPoint, to end: CGPoint, in view: NSView) {
        send(.leftMouseDown, at: view.convert(start, to: nil), to: view)
        send(.leftMouseDragged, at: view.convert(end, to: nil), to: view)
        send(.leftMouseUp, at: view.convert(end, to: nil), to: view)
    }

    private func send(_ type: NSEvent.EventType, at location: CGPoint, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1, to view: NSView) {
        let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clickCount, pressure: 1)!
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
    }
}

enum Fixtures {
    static func lines(_ count: Int, prefix: String = "let value") -> String {
        (1 ... count).map { "\(prefix)\($0) = \($0)" }.joined(separator: "\n") + "\n"
    }

    /// A diff of a file of `count` lines with every `step`th line changed.
    static func diff(name: String = "a.swift", count: Int = 40, step: Int = 10) throws -> FileDiffMetadata {
        let old = lines(count)
        let new = (1 ... count).map { $0 % step == 0 ? "let value\($0) = \($0 * 10)" : "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
        return try parseDiffFromFile(oldFile: FileContents(name: name, contents: old), newFile: FileContents(name: name, contents: new))
    }

    static func configuration(style: DiffStyle = .unified) -> DiffConfiguration {
        var configuration = DiffConfiguration()
        configuration.style = style
        configuration.synchronousHighlightLineLimit = .max
        return configuration
    }
}

/// Waits for a condition the main actor makes true, yielding rather than
/// sleeping.
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0 ..< 10000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}
