import AppKit
import SwiftUI
import Testing
import SwiffsCore
@testable import SwiffsUI

@MainActor
struct SwiftUIWrapperTests {
    private func host<V: View>(_ view: V) -> NSHostingView<V> {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    @Test func multiFileAndPatchInputs() throws {
        let files = host(DiffsFileDiff<Void>(oldFile: FileContents(name: "a.txt", contents: "a\n"), newFile: FileContents(name: "a.txt", contents: "b\n")))
        let diffView = try #require(find(FileDiffView<Void>.self, in: files))
        #expect(diffView.fileDiff?.additionLines == ["b\n"])

        let patch = "--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+c\n"
        let patched = host(DiffsFileDiff<Void>(patch: patch).header(metadata: { _ in NSTextField(labelWithString: "meta") }))
        let patchView = try #require(find(FileDiffView<Void>.self, in: patched))
        #expect(patchView.fileDiff?.additionLines == ["c\n"])
        #expect(find(NSTextField.self, in: patchView.header)?.stringValue == "meta")

    }
}
