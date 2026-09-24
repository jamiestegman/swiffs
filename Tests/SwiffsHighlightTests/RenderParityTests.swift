import Foundation
import SwiffsCore
import Testing
@testable import SwiffsHighlight

/// Differential tests for `renderDiff` / `renderFile` against upstream
/// `renderDiffWithHighlighter` / `renderFileWithHighlighter` output.
struct RenderParityTests {
    struct FileCase: Decodable { var expected: FileDiffMetadata }
    struct PatchCase: Decodable { var expected: [ParsedPatch] }

    struct StyleKey: Decodable, Hashable {
        var dark: String?
        var light: String?
        var color: String?
        var fs: [Int]

        init(dark: String?, light: String?, color: String?, fs: [Int]) {
            self.dark = dark
            self.light = light
            self.color = color
            self.fs = fs
        }

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            dark = try container.decodeNil() ? nil : try container.decode(String.self)
            light = try container.decodeNil() ? nil : try container.decode(String.self)
            color = try container.decodeNil() ? nil : try container.decode(String.self)
            fs = try container.decode([Int].self)
        }
    }

    struct Theme: Decodable {
        var single: String?
        var dark: String?
        var light: String?

        init(from decoder: any Decoder) throws {
            if let single = try? decoder.singleValueContainer().decode(String.self) {
                self.single = single
                return
            }
            let object = try decoder.singleValueContainer().decode([String: String].self)
            dark = object["dark"]
            light = object["light"]
        }

        var selection: ThemeSelection {
            if let single { return .single(single) }
            return .pair(ThemesType(dark: dark!, light: light!))
        }
    }

    struct Line: Decodable {
        var text: String
        var runs: [[Int]]

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            text = try container.decode(String.self)
            runs = try container.decode([[Int]].self)
        }
    }

    struct DiffCase: Decodable {
        struct Options: Decodable {
            var theme: Theme
            var lineDiffType: String
        }

        struct Plain: Decodable {
            var forcePlainText: Bool
            var startingLine: Int
            var totalLines: Int
            var collapsedContextThreshold: Int
        }

        var diffIndex: Int
        var options: Options
        var plain: Plain?
        var deletionLines: [Line?]
        var additionLines: [Line?]
    }

    struct FileRenderCase: Decodable {
        var file: FileContents
        var theme: Theme
        var lines: [Line?]
    }

    struct Fixture: Decodable {
        var diffCount: Int
        var styles: [StyleKey]
        var cases: [DiffCase]
        var fileRenderCases: [FileRenderCase]
    }

    static let fixturesDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let coreFixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SwiffsCoreTests/Fixtures")

    static func loadDiffs() throws -> [FileDiffMetadata] {
        let decoder = JSONDecoder()
        let fileCases = try decoder.decode([FileCase].self, from: Data(contentsOf: coreFixturesDirectory.appendingPathComponent("parseDiffFromFile.json")))
        let patchCases = try decoder.decode([PatchCase].self, from: Data(contentsOf: coreFixturesDirectory.appendingPathComponent("parsePatchFiles.json")))
        var diffs = fileCases.prefix(24).map(\.expected)
        for patchCase in patchCases.prefix(6) {
            for patch in patchCase.expected {
                diffs.append(contentsOf: patch.files.prefix(2))
            }
        }
        return diffs
    }

    /// Flattens a native highlighted line into runs keyed like the fixture.
    static func flatten(_ line: HighlightedLine, slots: ThemeSlots, styleIndex: [StyleKey: Int]) -> [[Int]] {
        let length = line.text.utf16.count
        var perUnit = [(StyleKey, Bool)](repeating: (StyleKey(dark: nil, light: nil, color: nil, fs: [0, 0, 0]), false), count: length)
        for token in line.tokens {
            let key: StyleKey
            switch slots {
            case .single:
                let style = token.styles[0]
                key = StyleKey(dark: nil, light: nil, color: style.color, fs: [0, 0, style.fontStyle.rawValue])
            case .pair:
                let dark = token.styles[0]
                let light = token.styles[1]
                key = StyleKey(dark: dark.color, light: light.color, color: nil, fs: [dark.fontStyle.rawValue, light.fontStyle.rawValue, 0])
            }
            for i in token.start ..< min(token.end, length) {
                perUnit[i].0 = key
            }
        }
        for span in line.diffSpans {
            for i in max(0, span.start) ..< min(span.end, length) {
                perUnit[i].1 = true
            }
        }
        var runs: [[Int]] = []
        for (key, diff) in perUnit {
            let index = styleIndex[key] ?? -1
            if let last = runs.last, last[1] == index, last[2] == (diff ? 1 : 0) {
                runs[runs.count - 1][0] += 1
            } else {
                runs.append([1, index, diff ? 1 : 0])
            }
        }
        return runs
    }

    @Test func renderDiffMatchesUpstream() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixturesDirectory.appendingPathComponent("render.json")))
        let diffs = try Self.loadDiffs()
        #expect(diffs.count == fixture.diffCount)
        var styleIndex: [StyleKey: Int] = [:]
        for (i, key) in fixture.styles.enumerated() where styleIndex[key] == nil {
            styleIndex[key] = i
        }
        let highlighter = DiffsHighlighter()
        var mismatches: [String] = []
        for testCase in fixture.cases {
            let diff = diffs[testCase.diffIndex]
            let options = RenderDiffOptions(
                theme: testCase.options.theme.selection,
                tokenizeMaxLineLength: 1000,
                lineDiffType: LineDiffType(rawValue: testCase.options.lineDiffType)!,
                maxLineDiffLength: 1000
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
            let result = try highlighter.renderDiff(diff, options: options, plainText: plain)
            for (side, expectedLines, actualLines) in [
                ("deletion", testCase.deletionLines, result.deletionLines),
                ("addition", testCase.additionLines, result.additionLines),
            ] {
                for (index, expected) in expectedLines.enumerated() {
                    let actual = index < actualLines.count ? actualLines[index] : nil
                    guard let expected else {
                        if actual != nil { mismatches.append("diff \(testCase.diffIndex) \(side) \(index): unexpected line") }
                        continue
                    }
                    guard let actual else {
                        mismatches.append("diff \(testCase.diffIndex) \(side) \(index): missing line")
                        continue
                    }
                    if actual.text != expected.text {
                        mismatches.append("diff \(testCase.diffIndex) \(side) \(index): text \(actual.text.debugDescription) != \(expected.text.debugDescription)")
                        continue
                    }
                    let runs = Self.flatten(actual, slots: result.themes, styleIndex: styleIndex)
                    if runs != expected.runs {
                        mismatches.append("diff \(testCase.diffIndex) \(side) \(index) \(expected.text.debugDescription): runs \(runs) != \(expected.runs)")
                    }
                }
            }
        }
        if !mismatches.isEmpty {
            let summary = mismatches.prefix(10).joined(separator: "\n")
            Issue.record("\(mismatches.count) mismatches:\n\(summary)")
        }
    }

    @Test func renderFileMatchesUpstream() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixturesDirectory.appendingPathComponent("render.json")))
        var styleIndex: [StyleKey: Int] = [:]
        for (i, key) in fixture.styles.enumerated() where styleIndex[key] == nil {
            styleIndex[key] = i
        }
        let highlighter = DiffsHighlighter()
        for testCase in fixture.fileRenderCases {
            let result = try highlighter.renderFile(testCase.file, options: RenderFileOptions(theme: testCase.theme.selection, tokenizeMaxLineLength: 1000))
            #expect(result.lines.count == testCase.lines.count, "\(testCase.file.name) line count")
            for (index, expected) in testCase.lines.enumerated() where index < result.lines.count {
                guard let expected, let actual = result.lines[index] else { continue }
                #expect(actual.text == expected.text, "\(testCase.file.name):\(index)")
                let runs = Self.flatten(actual, slots: result.themes, styleIndex: styleIndex)
                #expect(runs == expected.runs, "\(testCase.file.name):\(index)")
            }
        }
    }
}
