import AppKit
import SwiffsCore
import SwiftUI
import Testing
@testable import SwiffsUI

struct AccessibilityTests {
    private func elements(_ harness: Harness) -> [NSAccessibilityElement] {
        (harness.document.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
    }

    private func action(_ name: String, on element: NSAccessibilityElement?) -> NSAccessibilityCustomAction? {
        element?.accessibilityCustomActions()?.first { $0.name.hasPrefix(name) }
    }

    @Test func linesReadInDocumentOrderAfterTheirHeader() throws {
        let harness = Harness([.diff(try Fixtures.diff(step: 3))])
        let elements = elements(harness)
        #expect(elements.first?.accessibilityLabel() == "a.swift, 13 removed, 13 added")
        let lines = elements.dropFirst().prefix(3).map { "\($0.accessibilityLabel() ?? ""): \($0.accessibilityValue() as? String ?? "")" }
        #expect(lines == ["Line 1: let value1 = 1", "Line 2: let value2 = 2", "Line 3, removed: let value3 = 3"])
    }

    @Test func annotationViewsReadUnderTheirLine() throws {
        let harness = Harness([.diff(try Fixtures.diff(step: 3))], annotations: [DiffAnnotation(id: "a", itemID: "a.swift", side: .additions, lineNumber: 1)])
        let children = harness.document.accessibilityChildren() ?? []
        let line = try #require(children.firstIndex { ($0 as? NSAccessibilityElement)?.accessibilityLabel() == "Line 1" })
        #expect(children[line + 1] is NSHostingView<WidthBoundContent<NoteView>>)
    }

    @Test func separatorsExpandThroughActions() throws {
        let harness = Harness([.diff(try Fixtures.diff(count: 60, step: 30))])
        let expand = try #require(action("Expand", on: elements(harness).first))
        #expect(expand.handler?() == true)
        harness.view.layoutSubtreeIfNeeded()
        #expect(harness.rowFrame(15, in: "a.swift") != nil)
    }

    @Test func conflictsResolveThroughActions() throws {
        let harness = Harness([.conflicted(ConflictTests.file)])
        let accept = try #require(action("Accept current change", on: elements(harness).first))
        #expect(accept.handler?() == true)
        #expect(harness.client.resolutions.first?.file.contents == "let a = 1\nlet b = 2\nlet c = 4\n")
    }

    @Test func linesOfferTheGutterAction() throws {
        var configuration = Fixtures.configuration()
        configuration.showsGutterAction = true
        configuration.gutterActionLabel = "Comment"
        let harness = Harness([.diff(try Fixtures.diff(step: 3))], configuration: configuration)
        let line = try #require(elements(harness).first { $0.accessibilityLabel() == "Line 2" })
        #expect(action("Comment", on: line)?.handler?() == true)
        #expect(harness.client.gutterActions == [DiffLineSelection(itemID: "a.swift", range: SelectedLineRange(start: 2, side: .additions, end: 2))])
    }
}
