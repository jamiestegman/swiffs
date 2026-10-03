import AppKit
import Testing
import SwiffsCore
@testable import SwiffsUI

/// An annotation keeps its view while it is unchanged, so a view the user is
/// working in (a comment being typed) survives other annotations changing.
@MainActor
struct AnnotationIdentityTests {
    final class Note: NSView {
        let label: String
        init(_ label: String) {
            self.label = label
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override var fittingSize: NSSize { NSSize(width: frame.width, height: 20) }
    }
    struct Opaque {
        let label: String
    }

    static let old = (1...12).map { "line \($0)\n" }.joined()
    static func diff() throws -> FileDiffMetadata {
        try parseDiffFromFile(oldFile: FileContents(name: "a.txt", contents: old), newFile: FileContents(name: "a.txt", contents: old.replacingOccurrences(of: "line 6\n", with: "six\n")))
    }
    static func notes(_ view: NSView) -> [Note] { view.subviews.flatMap { ($0 as? Note).map { [$0] } ?? notes($0) } }

    @Test func anUnchangedDiffAnnotationKeepsItsViewWhenOthersChange() throws {
        let view = FileDiffView<String>()
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        view.renderAnnotation = { Note($0.metadata) }
        let diff = try Self.diff()
        view.render(fileDiff: diff, lineAnnotations: [DiffLineAnnotation(side: .additions, lineNumber: 8, metadata: "kept")])
        view.layoutSubtreeIfNeeded()
        let kept = try #require(Self.notes(view.grid).first)

        view.render(fileDiff: diff, lineAnnotations: [
            DiffLineAnnotation(side: .additions, lineNumber: 4, metadata: "added"), DiffLineAnnotation(side: .additions, lineNumber: 8, metadata: "kept"),
        ])
        view.layoutSubtreeIfNeeded()
        let notes = Self.notes(view.grid)
        #expect(notes.map(\.label).sorted() == ["added", "kept"])
        #expect(notes.first { $0.label == "kept" } === kept, "the unchanged annotation keeps its view though its row moved")
        #expect(kept.frame.minY > notes.first { $0.label == "added" }!.frame.minY, "and is placed at its new row")

        view.render(fileDiff: diff, lineAnnotations: [
            DiffLineAnnotation(side: .additions, lineNumber: 4, metadata: "added"), DiffLineAnnotation(side: .additions, lineNumber: 8, metadata: "edited"),
        ])
        view.layoutSubtreeIfNeeded()
        #expect(Self.notes(view.grid).map(\.label).sorted() == ["added", "edited"], "a changed annotation gets a new view")
    }

    @Test func aFileAnnotationIsReplacedWhenItChangesAndKeptWhenItDoesNot() throws {
        let view = FileView<String>()
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        view.renderAnnotation = { Note($0.metadata) }
        let file = FileContents(name: "a.txt", contents: Self.old)
        view.render(file: file, lineAnnotations: [LineAnnotation(lineNumber: 8, metadata: "kept")])
        view.layoutSubtreeIfNeeded()
        let kept = try #require(Self.notes(view.grid).first)
        view.render(file: file, lineAnnotations: [LineAnnotation(lineNumber: 3, metadata: "added"), LineAnnotation(lineNumber: 8, metadata: "kept")])
        view.layoutSubtreeIfNeeded()
        #expect(Self.notes(view.grid).first { $0.label == "kept" } === kept)
        view.render(file: file, lineAnnotations: [LineAnnotation(lineNumber: 3, metadata: "added"), LineAnnotation(lineNumber: 8, metadata: "edited")])
        view.layoutSubtreeIfNeeded()
        #expect(Self.notes(view.grid).map(\.label).sorted() == ["added", "edited"])
    }

    @Test func annotationsThatCannotBeComparedAreRebuilt() throws {
        let view = FileDiffView<Opaque>()
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        view.renderAnnotation = { Note($0.metadata.label) }
        let diff = try Self.diff()
        view.render(fileDiff: diff, lineAnnotations: [DiffLineAnnotation(side: .additions, lineNumber: 8, metadata: Opaque(label: "one"))])
        view.layoutSubtreeIfNeeded()
        let first = try #require(Self.notes(view.grid).first)
        view.render(fileDiff: diff, lineAnnotations: [DiffLineAnnotation(side: .additions, lineNumber: 8, metadata: Opaque(label: "two"))])
        view.layoutSubtreeIfNeeded()
        #expect(Self.notes(view.grid).map(\.label) == ["two"])
        #expect(Self.notes(view.grid).first !== first)
    }
}
