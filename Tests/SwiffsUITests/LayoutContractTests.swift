import AppKit
import Observation
import SwiftUI
import SwiffsCore
import Testing
@testable import SwiffsUI

@Observable final class Note {
    var lines: Int
    var text: String

    init(lines: Int = 1, text: String = "") {
        self.lines = lines
        self.text = text
    }
}

struct NoteView: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0 ..< note.lines, id: \.self) { index in
                Text("line \(index)").frame(height: 20)
            }
            if !note.text.isEmpty {
                Text(note.text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

typealias NoteList = DiffList<String, NoteView, EmptyView>
typealias NoteHost = NSHostingView<WidthBoundContent<EnvironmentBound<NoteView>>>

/// Annotations are measured at their column's width when they appear and
/// follow their content's size from then on, inside a SwiftUI-hosted window
/// as apps use them.
struct LayoutContractTests {
    let diff: FileDiffMetadata
    let item: DiffItem

    init() throws {
        diff = try Fixtures.diff()
        item = .diff(diff)
    }

    private func host(_ notes: [String: Note], at lines: [String: Int], style: DiffStyle = .unified, width: CGFloat = 800) -> HostingWindow<NoteList> {
        let annotations = notes.keys.sorted().map { DiffAnnotation(id: $0, itemID: item.id, side: .additions, lineNumber: lines[$0] ?? 10) }
        return HostingWindow(NoteList([item], annotations: annotations, configuration: Fixtures.configuration(style: style)) { id in NoteView(note: notes[id]!) }, size: CGSize(width: width, height: 600))
    }

    private func diffView(_ window: HostingWindow<NoteList>) throws -> NoteList.NSViewType {
        try #require(window.find(NoteList.NSViewType.self))
    }

    private func rowFrame(after lineNumber: Int, in view: NoteList.NSViewType) throws -> CGRect {
        let model = try #require(view.layoutModel.item(item.id))
        let row = try #require(model.row(forLineNumber: lineNumber, side: .additions))
        return try #require(model.rowFrame(row, showsHeaders: true, width: 0))
    }

    @Test func annotationIsMeasuredBeforeItsFirstFrame() throws {
        let window = host(["a": Note(lines: 2)], at: ["a": 10])
        let host = try #require(window.find(NoteHost.self))
        let view = try diffView(window)
        let column = try #require(view.layoutModel.item(item.id)?.geometry?.columns.first)
        #expect(host.frame.height == 40)
        #expect(host.frame.width == column.contentWidth)
        let line = try rowFrame(after: 10, in: view)
        let next = try rowFrame(after: 11, in: view)
        #expect(next.minY - line.maxY == 40, "the annotation row sits between its line and the next")
    }

    @Test func annotationFollowsItsContentInOneLayoutPass() throws {
        let note = Note(lines: 1)
        let window = host(["a": note], at: ["a": 10])
        let view = try diffView(window)
        let host = try #require(window.find(NoteHost.self))
        let before = try rowFrame(after: 11, in: view)

        note.lines = 4
        window.layout()
        #expect(host.frame.height == 80)
        #expect(try rowFrame(after: 11, in: view).minY == before.minY + 60)

        note.lines = 2
        window.layout()
        #expect(host.frame.height == 40)
        #expect(try rowFrame(after: 11, in: view).minY == before.minY + 20)
    }

    @Test func annotationIsMeasuredAgainAtANewWidth() throws {
        let note = Note(lines: 0, text: String(repeating: "word ", count: 80))
        let window = host(["a": note], at: ["a": 10], width: 900)
        let host = try #require(window.find(NoteHost.self))
        let wide = host.frame.height
        window.resize(width: 400)
        #expect(host.frame.height > wide, "narrower columns wrap the text onto more lines")
        let column = try #require(try diffView(window).layoutModel.item(item.id)?.geometry?.columns.first)
        #expect(host.frame.width == column.contentWidth)
    }

    @Test func splitAnnotationsTakeTheirSidesColumn() throws {
        let window = host(["a": Note()], at: ["a": 10], style: .split)
        let host = try #require(window.find(NoteHost.self))
        let columns = try #require(try diffView(window).layoutModel.item(item.id)?.geometry?.columns)
        #expect(columns.count == 2)
        #expect(host.frame.minX == columns[1].contentMinX)
        #expect(host.frame.width == columns[1].contentWidth)
    }

    @Test func annotationsOnOneLineStackInOrder() throws {
        let window = host(["a": Note(lines: 1), "b": Note(lines: 2)], at: ["a": 10, "b": 10])
        let view = try diffView(window)
        let hosts = view.documentView.subviews.compactMap { $0 as? NoteHost }.sorted { $0.frame.minY < $1.frame.minY }
        #expect(hosts.count == 2)
        #expect(hosts.map(\.frame.height) == [20, 40])
        #expect(hosts[1].frame.minY == hosts[0].frame.maxY)
        #expect(try rowFrame(after: 11, in: view).minY - (try rowFrame(after: 10, in: view)).maxY == 60)
    }

    @Test func annotationKeepsItsViewWhileOthersChangeAndWhenItMoves() throws {
        let notes = ["a": Note(), "b": Note()]
        let view = DiffView(configuration: Fixtures.configuration()) { (id: String) in NoteView(note: notes[id]!) }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.update(items: [item], annotations: [DiffAnnotation(id: "a", itemID: item.id, side: .additions, lineNumber: 10)], configuration: view.configuration)
        view.layoutSubtreeIfNeeded()
        let original = try #require(view.documentView.subviews.first { $0 is NSHostingView<WidthBoundContent<NoteView>> })

        view.update(items: [item], annotations: [
            DiffAnnotation(id: "a", itemID: item.id, side: .additions, lineNumber: 20),
            DiffAnnotation(id: "b", itemID: item.id, side: .additions, lineNumber: 10),
        ], configuration: view.configuration)
        view.layoutSubtreeIfNeeded()
        let hosts = view.documentView.subviews.filter { $0 is NSHostingView<WidthBoundContent<NoteView>> }
        #expect(hosts.count == 2)
        #expect(hosts.contains { $0 === original })
        let model = try #require(view.layoutModel.item(item.id))
        let row = try #require(model.row(forLineNumber: 20, side: .additions))
        let line = try #require(model.rowFrame(row, showsHeaders: true, width: 0))
        #expect(original.frame.minY == line.maxY, "the moved annotation sits under its new line")
        window.close()
    }
}
