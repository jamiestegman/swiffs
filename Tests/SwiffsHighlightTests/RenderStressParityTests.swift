import Foundation
import SwiffsCore
import Testing
@testable import SwiffsHighlight

/// Upstream renders of mutated samples in every test language: Unicode,
/// line endings, tabs, long lines, windowed plain text and ANSI.
struct RenderStressParityTests {
    struct Options: Decodable {
        var theme: RenderParityTests.Theme
        var lineDiffType: String?
        var tokenizeMaxLineLength: Int
        var maxLineDiffLength: Int?
    }

    struct DiffCase: Decodable {
        var name: String
        var diff: FileDiffMetadata
        var options: Options
        var plain: RenderParityTests.DiffCase.Plain?
        var deletionLines: [RenderParityTests.Line?]
        var additionLines: [RenderParityTests.Line?]
    }

    struct FileCase: Decodable {
        var name: String
        var file: FileContents
        var options: Options
        var lines: [RenderParityTests.Line?]
    }

    struct Fixture: Decodable {
        var styles: [RenderParityTests.StyleKey]
        var diffCases: [DiffCase]
        var fileCases: [FileCase]
    }

    static let fixture: Fixture = {
        let url = RenderParityTests.fixturesDirectory.appendingPathComponent("render-stress.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    static let styleIndex: [RenderParityTests.StyleKey: Int] = {
        var index: [RenderParityTests.StyleKey: Int] = [:]
        for (i, key) in fixture.styles.enumerated() where index[key] == nil {
            index[key] = i
        }
        return index
    }()

    static func compare(_ label: String, expected: [RenderParityTests.Line?], actual: [HighlightedLine?], slots: ThemeSlots, into mismatches: inout [String]) {
        // Upstream fills a sparse array, so windowed results end at the last
        // rendered line; lines past it must be absent here.
        if actual.count < expected.count || actual[expected.count...].contains(where: { $0 != nil }) {
            mismatches.append("\(label): \(actual.count) lines, expected \(expected.count)")
        }
        for (index, expectedLine) in expected.enumerated() {
            let actualLine = index < actual.count ? actual[index] : nil
            guard let expectedLine else {
                if actualLine != nil { mismatches.append("\(label):\(index) unexpected line") }
                continue
            }
            guard let actualLine else {
                mismatches.append("\(label):\(index) missing line")
                continue
            }
            if actualLine.text != expectedLine.text {
                mismatches.append("\(label):\(index) text \(actualLine.text.debugDescription) != \(expectedLine.text.debugDescription)")
                continue
            }
            let runs = RenderParityTests.flatten(actualLine, slots: slots, styleIndex: styleIndex)
            if runs != expectedLine.runs {
                mismatches.append("\(label):\(index) \(expectedLine.text.debugDescription) runs \(runs) != \(expectedLine.runs)")
            }
        }
    }

    @Test func renderDiffMatchesUpstream() throws {
        let highlighter = DiffsHighlighter()
        var mismatches: [String] = []
        for testCase in Self.fixture.diffCases {
            let options = RenderDiffOptions(
                theme: testCase.options.theme.selection,
                tokenizeMaxLineLength: testCase.options.tokenizeMaxLineLength,
                lineDiffType: LineDiffType(rawValue: testCase.options.lineDiffType ?? "word-alt")!,
                maxLineDiffLength: testCase.options.maxLineDiffLength ?? 1000
            )
            var plain = ForceDiffPlainTextOptions()
            if let p = testCase.plain {
                plain = ForceDiffPlainTextOptions(
                    forcePlainText: p.forcePlainText,
                    startingLine: p.startingLine,
                    totalLines: p.totalLines,
                    expandedHunks: .all,
                    collapsedContextThreshold: p.collapsedContextThreshold
                )
            }
            let result = try highlighter.renderDiff(testCase.diff, options: options, plainText: plain)
            Self.compare("\(testCase.name) deletions", expected: testCase.deletionLines, actual: result.deletionLines, slots: result.themes, into: &mismatches)
            Self.compare("\(testCase.name) additions", expected: testCase.additionLines, actual: result.additionLines, slots: result.themes, into: &mismatches)
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches:\n\(mismatches.prefix(12).joined(separator: "\n"))")
    }

    @Test func renderFileMatchesUpstream() throws {
        let highlighter = DiffsHighlighter()
        var mismatches: [String] = []
        for testCase in Self.fixture.fileCases {
            let result = try highlighter.renderFile(
                testCase.file,
                options: RenderFileOptions(theme: testCase.options.theme.selection, tokenizeMaxLineLength: testCase.options.tokenizeMaxLineLength)
            )
            Self.compare(testCase.name, expected: testCase.lines, actual: result.lines, slots: result.themes, into: &mismatches)
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches:\n\(mismatches.prefix(12).joined(separator: "\n"))")
    }
}
