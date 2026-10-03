import AppKit
import Testing
import SwiffsCore
@testable import SwiffsUI

/// A smooth scroll animates to its destination and settles there.
@MainActor
struct SmoothScrollTests {
    private func shown() -> (NSWindow, CodeView<String>, destination: CGFloat) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let code = CodeView<String>(options: CodeViewOptions())
        code.frame = window.contentView!.bounds
        window.contentView?.addSubview(code)
        let contents = (1 ... 400).map { "line \($0)\n" }.joined()
        code.setItems([.file(id: "a.txt", FileContents(name: "a.txt", contents: contents))])
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        code.scrollTo(.position(300))
        let destination = code.scrollTop
        code.scrollTo(.position(0))
        return (window, code, destination)
    }

    @Test func aSmoothScrollSettlesWhereAnInstantOneLands() async throws {
        let (window, code, destination) = shown()
        defer { window.close() }
        #expect(destination > 100 && code.scrollTop == 0)
        code.scrollTo(.position(300, behavior: .smooth))
        let deadline = Date().addingTimeInterval(3)
        while abs(code.scrollTop - destination) > 0.5, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(code.scrollTop - destination) < 0.5)
    }
}
