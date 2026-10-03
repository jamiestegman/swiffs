import AppKit
import SwiftUI
import SwiffsCore
import SwiffsHighlight
import Testing
@testable import SwiffsUI

/// A diff view in a window, driven as a client drives it.
final class Harness {
    let window: NSWindow
    let view: DiffView<String, NoteView, EmptyView>
    let client = Client()
    var notes: [String: Note] = [:]

    final class Client: DiffViewDelegate {
        var selections: [DiffLineSelection?] = []
        var gutterActions: [DiffLineSelection] = []
        var resolutions: [DiffConflictResolution] = []
        var topItems: [String?] = []

        func diffView(_ diffView: NSView, didChangeLineSelection selection: DiffLineSelection?) { selections.append(selection) }
        func diffView(_ diffView: NSView, didRequestGutterActionFor selection: DiffLineSelection) { gutterActions.append(selection) }
        func diffView(_ diffView: NSView, didResolveConflict resolution: DiffConflictResolution) { resolutions.append(resolution) }
        func diffView(_ diffView: NSView, didScrollToItem itemID: String?) { topItems.append(itemID) }
    }

    init(_ items: [DiffItem], annotations: [DiffAnnotation<String>] = [], configuration: DiffConfiguration = Fixtures.configuration(), service: HighlightService = .shared, size: CGSize = CGSize(width: 800, height: 600)) {
        var notes: [String: Note] = [:]
        for annotation in annotations { notes[annotation.id] = Note() }
        self.notes = notes
        view = DiffView(configuration: configuration, highlightService: service) { id in NoteView(note: notes[id] ?? Note()) }
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.delegate = client
        view.update(items: items, annotations: annotations, configuration: configuration)
        view.layoutSubtreeIfNeeded()
    }

    isolated deinit {
        window.close()
    }

    var document: DocumentView { view.documentView }
    var scrollTop: CGFloat { view.scrollTop }

    func item(_ id: String) -> ItemModel? { view.layoutModel.item(id) }

    func scroll(to y: CGFloat) {
        view.scrollView.contentView.scroll(to: CGPoint(x: 0, y: y))
        view.scrollView.reflectScrolledClipView(view.scrollView.contentView)
    }

    /// The document frame of the row showing a line.
    func rowFrame(_ lineNumber: Int, side: AnnotationSide? = .additions, in itemID: String) -> CGRect? {
        guard let item = item(itemID), let row = item.row(forLineNumber: lineNumber, side: side) else { return nil }
        return item.rowFrame(row, showsHeaders: view.configuration.showsHeaders, width: document.bounds.width)
    }

    /// A point in a line's number column, in the document.
    func numberPoint(_ lineNumber: Int, in itemID: String) -> CGPoint? {
        guard let frame = rowFrame(lineNumber, in: itemID), let column = item(itemID)?.geometry?.columns.last else { return nil }
        return CGPoint(x: column.minX + 10, y: frame.midY)
    }

    func send(_ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) {
        let event = NSEvent.mouseEvent(
            with: type, location: document.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
        switch type {
        case .leftMouseDown: document.mouseDown(with: event)
        case .leftMouseDragged: document.mouseDragged(with: event)
        case .mouseMoved: document.mouseMoved(with: event)
        default: document.mouseUp(with: event)
        }
    }

    func click(_ point: CGPoint, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) {
        send(.leftMouseDown, at: point, modifiers: modifiers, clickCount: clickCount)
        send(.leftMouseUp, at: point, modifiers: modifiers, clickCount: clickCount)
    }
}

struct VirtualisationTests {
    @Test func onlyItemsNearTheViewportBuildRows() throws {
        let items = try (0 ..< 200).map { DiffItem.diff(try Fixtures.diff(name: "f\($0).swift")) }
        let harness = Harness(items)
        let built = harness.view.layoutModel.items.filter(\.hasBody).map(\.id)
        #expect(!built.isEmpty)
        #expect(built.count < 20)
        #expect(built.first == "f0.swift")
        #expect(harness.view.contentHeight > 200 * Metrics.headerHeight)

        let far = try #require(harness.item("f150.swift"))
        harness.scroll(to: far.top)
        harness.view.layoutSubtreeIfNeeded()
        #expect(harness.item("f150.swift")?.hasBody == true)
        #expect(harness.item("f0.swift")?.hasBody == false, "rows far behind the viewport are released")
    }

    @Test func aRepeatedIdIsNotShown() throws {
        let harness = Harness([.diff(try Fixtures.diff(step: 3)), .diff(try Fixtures.diff(step: 5))])
        #expect(harness.view.layoutModel.items.count == 1)
        #expect(harness.item("a.swift")?.diff == (try Fixtures.diff(step: 3)))
    }

    @Test func collapsedItemsShowOnlyTheirHeader() throws {
        let harness = Harness([.diff(try Fixtures.diff(), isCollapsed: true)])
        #expect(harness.item("a.swift")?.height == Metrics.headerHeight)
        #expect(harness.item("a.swift")?.hasBody == false)
    }

    @Test func rowsMatchTheirEstimateSoBuildingThemMovesNothing() throws {
        let items = try (0 ..< 30).map { DiffItem.diff(try Fixtures.diff(name: "f\($0).swift")) }
        let harness = Harness(items)
        let target = try #require(harness.item("f20.swift"))
        let estimated = target.height
        harness.scroll(to: target.top)
        #expect(harness.item("f20.swift")?.hasBody == true)
        #expect(harness.item("f20.swift")?.height == estimated)
    }

    @Test func contentAboveTheViewportChangingKeepsTheReadLineInPlace() throws {
        let diff = try Fixtures.diff(count: 200, step: 4)
        let harness = Harness([.diff(diff)], annotations: [DiffAnnotation(id: "a", itemID: "a.swift", side: .additions, lineNumber: 10)])
        let line = try #require(harness.rowFrame(101, in: "a.swift"))
        harness.scroll(to: line.minY)
        let note = try #require(harness.notes["a"])
        note.lines = 5
        harness.view.layoutSubtreeIfNeeded()
        let moved = try #require(harness.rowFrame(101, in: "a.swift"))
        #expect(moved.minY == line.minY + 80)
        #expect(harness.scrollTop == moved.minY, "line 101 stays at the top of the viewport")
    }

    @Test func updatingWithEqualValuesKeepsItemsAndHighlighting() throws {
        let diff = try Fixtures.diff()
        let harness = Harness([.diff(diff)])
        let model = try #require(harness.item("a.swift"))
        #expect(model.highlighted != nil)
        harness.view.update(items: [.diff(diff)], configuration: harness.view.configuration)
        #expect(harness.item("a.swift") === model)
        #expect(model.highlighted != nil)
    }
}

struct HighlightingTests {
    @Test func largeContentHighlightsOffTheMainThreadThenRedraws() async throws {
        var configuration = Fixtures.configuration()
        configuration.synchronousHighlightLineLimit = 0
        let harness = Harness([.diff(try Fixtures.diff())], configuration: configuration, service: HighlightService(workerCount: 1))
        let model = try #require(harness.item("a.swift"))
        #expect(model.highlighted == nil, "nothing blocks the first frame")
        #expect(await eventually { model.highlighted != nil })
    }

    @Test func changedContentIsHighlightedAgain() throws {
        let harness = Harness([.diff(try Fixtures.diff(step: 10))])
        let model = try #require(harness.item("a.swift"))
        let first = model.generation
        harness.view.update(items: [.diff(try Fixtures.diff(step: 7))], configuration: harness.view.configuration)
        harness.view.layoutSubtreeIfNeeded()
        #expect(model.generation != first)
        #expect(model.highlighted != nil)
    }
}

struct ScrollingTests {
    @Test func scrollingToALineShowsItBelowTheStickyHeader() throws {
        let items = try (0 ..< 20).map { DiffItem.diff(try Fixtures.diff(name: "f\($0).swift", count: 100, step: 20)) }
        let harness = Harness(items)
        harness.view.scroll(to: .line(60, side: .additions, in: "f12.swift", animation: .none))
        let frame = try #require(harness.rowFrame(60, in: "f12.swift"))
        #expect(harness.scrollTop == frame.minY - Metrics.headerHeight)
        #expect(harness.view.stickyHeader.itemID == "f12.swift")
        #expect(harness.view.topItemID == "f12.swift")
        #expect(harness.client.topItems.last == "f12.swift")
    }

    @Test func scrollingToAnItemAlignsItsTop() throws {
        let items = try (0 ..< 20).map { DiffItem.diff(try Fixtures.diff(name: "f\($0).swift")) }
        let harness = Harness(items)
        harness.view.scroll(to: .item("f5.swift", animation: .none))
        #expect(harness.scrollTop == harness.item("f5.swift")?.top)
        #expect(harness.view.stickyHeader.itemID == nil)
    }

    @Test func nearestScrollsOnlyWhenTheTargetIsOutOfView() throws {
        let items = try (0 ..< 20).map { DiffItem.diff(try Fixtures.diff(name: "f\($0).swift")) }
        let harness = Harness(items)
        harness.view.scroll(to: .line(2, in: "f0.swift", alignment: .nearest, animation: .none))
        #expect(harness.scrollTop == 0)
        harness.view.scroll(to: .line(30, in: "f3.swift", alignment: .nearest, animation: .none))
        let frame = try #require(harness.rowFrame(30, in: "f3.swift"))
        #expect(harness.scrollTop + harness.view.viewportHeight == frame.maxY, "\(harness.scrollTop) \(harness.view.viewportHeight) \(frame)")
    }

    @Test func smoothScrollingSettlesWhereAnInstantScrollLands() throws {
        let items = try (0 ..< 10).map { DiffItem.diff(try Fixtures.diff(name: "f\($0).swift")) }
        let harness = Harness(items)
        let instant = try #require(harness.view.scroll.destination(for: .item("f2.swift"), in: harness.view))
        harness.view.scroll(to: .item("f2.swift", animation: .smooth))
        var now = CACurrentMediaTime() * 1000
        var positions: [CGFloat] = []
        for _ in 0 ..< 600 where harness.view.scroll.isAnimating {
            now += 1000 / 120
            harness.view.stepScrollAnimation(at: now)
            positions.append(harness.scrollTop)
        }
        #expect(!harness.view.scroll.isAnimating)
        #expect(harness.scrollTop == instant)
        #expect(positions.count > 2, "it moved over several frames")
        #expect(zip(positions, positions.dropFirst()).allSatisfy { $0 <= $1 + 0.5 }, "without overshooting back")
    }
}

struct InteractionTests {
    private func harness(lineSelection: Bool = true, gutterAction: Bool = true) throws -> Harness {
        var configuration = Fixtures.configuration()
        configuration.allowsLineSelection = lineSelection
        configuration.showsGutterAction = gutterAction
        // Every third line changes, so every line shows.
        return Harness([.diff(try Fixtures.diff(step: 3))], configuration: configuration)
    }

    @Test func draggingOverLineNumbersSelectsLines() throws {
        let harness = try harness()
        let start = try #require(harness.numberPoint(5, in: "a.swift"))
        let end = try #require(harness.numberPoint(8, in: "a.swift"))
        harness.send(.leftMouseDown, at: start)
        harness.send(.leftMouseDragged, at: end)
        harness.send(.leftMouseUp, at: end)
        let selection = DiffLineSelection(itemID: "a.swift", range: SelectedLineRange(start: 5, side: .additions, end: 8))
        #expect(harness.view.lineSelection == selection)
        #expect(harness.client.selections.last == selection)
    }

    @Test func clickingASelectedLineAgainUnselectsIt() throws {
        let harness = try harness()
        let point = try #require(harness.numberPoint(5, in: "a.swift"))
        harness.click(point)
        #expect(harness.view.lineSelection?.range.start == 5)
        harness.click(point)
        #expect(harness.view.lineSelection == nil)
    }

    @Test func shiftClickExtendsTheSelection() throws {
        let harness = try harness()
        harness.click(try #require(harness.numberPoint(5, in: "a.swift")))
        harness.click(try #require(harness.numberPoint(9, in: "a.swift")), modifiers: .shift)
        #expect(harness.view.lineSelection?.range == SelectedLineRange(start: 5, side: .additions, end: 9))
    }

    @Test func theGutterActionReportsTheHoveredLine() throws {
        let harness = try harness()
        let frame = try #require(harness.rowFrame(12, in: "a.swift"))
        harness.send(.mouseMoved, at: CGPoint(x: 200, y: frame.midY))
        let item = try #require(harness.item("a.swift"))
        let painter = try #require(harness.document.painter(for: item))
        let column = try #require(item.geometry?.columns.first)
        let button = painter.gutterActionRect(column: column, top: frame.minY)
        harness.click(CGPoint(x: button.midX, y: button.midY))
        #expect(harness.client.gutterActions == [DiffLineSelection(itemID: "a.swift", range: SelectedLineRange(start: 12, side: .additions, end: 12))])
    }

    @Test func theGutterActionAppliesToTheSelection() throws {
        let harness = try harness()
        harness.view.lineSelection = DiffLineSelection(itemID: "a.swift", range: SelectedLineRange(start: 3, side: .additions, end: 6))
        let item = try #require(harness.item("a.swift"))
        let target = try #require(harness.document.gutterActionTarget(in: item))
        let frame = try #require(item.rowFrame(target.row, showsHeaders: true, width: 800))
        let painter = try #require(harness.document.painter(for: item))
        let column = try #require(item.geometry?.columns[target.column])
        let button = painter.gutterActionRect(column: column, top: frame.minY)
        harness.click(CGPoint(x: button.midX, y: button.midY))
        #expect(harness.client.gutterActions.last?.range == SelectedLineRange(start: 3, side: .additions, end: 6))
    }

    @Test func draggingOverCodeSelectsTextToCopy() throws {
        let harness = try harness()
        let first = try #require(harness.rowFrame(1, in: "a.swift"))
        let second = try #require(harness.rowFrame(2, in: "a.swift"))
        let codeX = try #require(harness.item("a.swift")?.geometry?.columns.first?.contentMinX)
        harness.send(.leftMouseDown, at: CGPoint(x: codeX + 9, y: first.midY))
        harness.send(.leftMouseDragged, at: CGPoint(x: 2000, y: second.midY))
        harness.send(.leftMouseUp, at: CGPoint(x: 2000, y: second.midY))
        #expect(harness.document.selectedText == "let value1 = 1\nlet value2 = 2")
    }

    @Test func doubleClickSelectsAWord() throws {
        let harness = try harness()
        let frame = try #require(harness.rowFrame(2, in: "a.swift"))
        let item = try #require(harness.item("a.swift"))
        let column = try #require(item.geometry?.columns.first)
        let painter = try #require(harness.document.painter(for: item))
        let x = painter.textOriginX(for: column) + harness.view.layoutModel.style.ch * 6
        harness.click(CGPoint(x: x, y: frame.midY), clickCount: 2)
        #expect(harness.document.selectedText == "value2")
    }

    @Test func expandingAHunkRevealsHiddenLines() throws {
        let harness = Harness([.diff(try Fixtures.diff(count: 60, step: 30))])
        #expect(harness.rowFrame(15, in: "a.swift") == nil)
        harness.view.expand(hunk: 0, inItem: "a.swift")
        harness.view.layoutSubtreeIfNeeded()
        #expect(harness.rowFrame(15, in: "a.swift") != nil)
    }
}

struct ConflictTests {
    static let file = FileContents(name: "c.swift", contents: """
    let a = 1
    <<<<<<< HEAD
    let b = 2
    =======
    let b = 3
    >>>>>>> feature
    let c = 4

    """)

    @Test func acceptingAConflictReportsTheResolvedFile() throws {
        let harness = Harness([.conflicted(Self.file)])
        let item = try #require(harness.item("c.swift"))
        let body = try #require(item.body)
        let row = try #require(body.rows.firstIndex { row in
            if case .injected(let cell)? = row.cells.first ?? nil, case .mergeConflictActions = cell.kind { return true }
            return false
        })
        let frame = try #require(item.rowFrame(row, showsHeaders: true, width: 800))
        let column = try #require(item.geometry?.columns.first)
        let painter = try #require(harness.document.painter(for: item))
        let actions = painter.conflictActionFrames(contentRect: CGRect(x: column.contentMinX, y: frame.minY, width: column.contentWidth, height: frame.height))
        let incoming = try #require(actions.first { $0.0 == .incoming })
        harness.click(CGPoint(x: incoming.1.midX, y: incoming.1.midY))
        let resolution = try #require(harness.client.resolutions.first)
        #expect(resolution.resolution == .incoming)
        #expect(resolution.file.contents == "let a = 1\nlet b = 3\nlet c = 4\n")

        harness.view.update(items: [.conflicted(resolution.file, id: "c.swift")], configuration: harness.view.configuration)
        harness.view.layoutSubtreeIfNeeded()
        #expect(harness.item("c.swift")?.failure == nil)
    }
}

struct IsolationRuleTests {
    /// The UI module's isolation map allows none of these (S3).
    @Test func uiModuleUsesNoBannedConstructs() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SwiffsUI")
        let banned = ["DispatchQueue", "Timer.", "Timer(", "assumeIsolated", "@unchecked Sendable", "nonisolated(unsafe)", "NSLock", "NSRecursiveLock"]
        var violations: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in banned where text.contains(token) {
                violations.append("\(file.lastPathComponent): \(token)")
            }
        }
        #expect(violations.isEmpty, "\(violations)")
    }
}

struct GrowingFileTests {
    @Test func appendedTextKeepsEarlierLinesAndHighlightsOnlyTheTail() async throws {
        let start = FileContents(name: "live.swift", contents: "let a = 1\nlet b = ")
        let harness = Harness([.file(start)])
        let model = try #require(harness.item("live.swift"))
        let generation = model.generation
        let firstLine = model.line(side: .additions, lineIndex: 0, slots: 2)
        #expect(firstLine.tokens.count > 1, "the first update highlights at once")

        let grown = FileContents(name: "live.swift", contents: "let a = 1\nlet b = 2\nlet c = \"three\"\n")
        harness.view.update(items: [.file(grown)], configuration: harness.view.configuration)
        harness.view.layoutSubtreeIfNeeded()
        #expect(harness.item("live.swift") === model)
        #expect(model.generation == generation, "growing is not a new file")
        #expect(model.line(side: .additions, lineIndex: 0, slots: 2) == firstLine, "the first line keeps its highlighting")
        #expect(model.body?.rows.count == 4)

        let whole = try DiffsHighlighter().renderFile(grown, options: harness.view.configuration.renderFileOptions).lines
        #expect(await eventually { model.line(side: .additions, lineIndex: 2, slots: 2).tokens.count > 1 })
        let streamed = model.line(side: .additions, lineIndex: 2, slots: 2)
        #expect(streamed.text == whole[2]?.text)
        #expect(streamed.tokens.last?.styles == whole[2]?.tokens.last?.styles)
    }

    @Test func replacedContentIsNotTreatedAsGrowth() throws {
        let harness = Harness([.file(FileContents(name: "f.swift", contents: "let a = 1\n"))])
        let model = try #require(harness.item("f.swift"))
        let generation = model.generation
        harness.view.update(items: [.file(FileContents(name: "f.swift", contents: "let b = 2\n"))], configuration: harness.view.configuration)
        #expect(model.generation != generation)
    }
}

struct AccessoryTests {
    struct Badge: View {
        let name: String
        var body: some View { Text(name).frame(width: 60, height: 20) }
    }

    private func harness(_ count: Int) throws -> (NSWindow, DiffView<String, EmptyView, Badge>) {
        let view = DiffView(configuration: Fixtures.configuration(), annotation: { (_: String) in EmptyView() }) { item in Badge(name: item.id) }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.update(items: try (0 ..< count).map { .diff(try Fixtures.diff(name: "f\($0).swift")) }, configuration: view.configuration)
        view.layoutSubtreeIfNeeded()
        return (window, view)
    }

    private func badges(in view: NSView) -> [NSView] {
        view.subviews.filter { $0 is NSHostingView<IdealSizeContent<Badge>> }
    }

    @Test func accessoriesSitAtTheEndOfTheirHeader() throws {
        let (window, view) = try harness(3)
        defer { window.close() }
        let first = try #require(view.layoutModel.item("f0.swift"))
        let badge = try #require(badges(in: view.documentView).min { $0.frame.minY < $1.frame.minY })
        #expect(badge.frame.size == CGSize(width: 60, height: 20))
        #expect(badge.frame.maxX == view.scrollView.contentSize.width - HeaderPainter.paddingInline)
        #expect(badge.frame.midY == first.top + Metrics.headerHeight / 2)
        #expect(view.documentView.accessoryWidths["f0.swift"] == 60)
    }

    @Test func theStuckItemsAccessoryMovesIntoTheStickyHeader() throws {
        let (window, view) = try harness(10)
        defer { window.close() }
        view.scroll(to: .line(20, in: "f2.swift", animation: .none))
        #expect(view.stickyHeader.itemID == "f2.swift")
        #expect(badges(in: view.stickyHeader).count == 1)
        view.scroll(to: .item("f0.swift", animation: .none))
        #expect(view.stickyHeader.itemID == nil)
        #expect(badges(in: view.stickyHeader).isEmpty)
    }

    @Test func accessoriesOfItemsFarAwayAreReleased() throws {
        let (window, view) = try harness(60)
        defer { window.close() }
        let initial = badges(in: view.documentView).count
        #expect(initial > 0 && initial < 15)
        view.scroll(to: .item("f50.swift", animation: .none))
        #expect(badges(in: view.documentView).count < 15)
        #expect(view.documentView.accessoryWidths["f0.swift"] == nil)
    }

    @Test func aListWithoutAccessoriesHostsNone() throws {
        let window = HostingWindow(DiffList([.diff(try Fixtures.diff())], configuration: Fixtures.configuration()))
        let view = try #require(window.find(DiffList<NoAnnotation, EmptyView, EmptyView>.NSViewType.self))
        #expect(view.documentView.subviews.isEmpty)
    }
}
