import Foundation
import Testing
@testable import SwiffsCore

/// Differential tests for `iterateOverDiff` and the virtual layout helpers.
struct LayoutParityTests {
    /// Rebuilds the list of diffs used by `generate-layout-fixtures.ts`.
    static func loadDiffs() throws -> [FileDiffMetadata] {
        let fileCases = try Fixtures.load("parseDiffFromFile.json", as: [ParsingParityTests.FileCase].self)
        let patchCases = try Fixtures.load("parsePatchFiles.json", as: [ParsingParityTests.PatchCase].self)
        var diffs = fileCases.map(\.expected)
        for patchCase in patchCases.prefix(15) {
            for patch in patchCase.expected {
                diffs.append(contentsOf: patch.files.prefix(2))
            }
        }
        return diffs
    }

    static func loadLayout() throws -> [String: Any] {
        let data = try Data(contentsOf: Fixtures.directory.appendingPathComponent("layout.json"))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func expanded(_ value: Any?) -> ExpandedHunks? {
        guard let object = value as? [String: Any], let kind = object["kind"] as? String else { return nil }
        switch kind {
        case "all": return .all
        case "regions":
            var regions: [Int: HunkExpansionRegion] = [:]
            for entry in object["regions"] as? [[Any]] ?? [] {
                let index = entry[0] as! Int
                let region = entry[1] as! [String: Int]
                regions[index] = HunkExpansionRegion(fromStart: region["fromStart"]!, fromEnd: region["fromEnd"]!)
            }
            return .regions(regions)
        default: return nil
        }
    }

    static func encode(_ line: DiffLineMetadata?) -> String {
        guard let line else { return "null" }
        return "[\(line.unifiedLineIndex),\(line.splitLineIndex),\(line.lineIndex),\(line.lineNumber),\(line.noEOFCR)]"
    }

    static func encodeExpected(_ line: Any) -> String {
        guard let array = line as? [Any] else { return "null" }
        let values = array.map { value -> String in
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return "\(value)"
        }
        return "[" + values.joined(separator: ",") + "]"
    }

    @Test func iterateOverDiffMatchesUpstream() throws {
        let diffs = try Self.loadDiffs()
        let layout = try Self.loadLayout()
        let cases = layout["iterateCases"] as! [[String: Any]]
        #expect(cases.count > 100)
        var failures = 0
        for (caseIndex, testCase) in cases.enumerated() {
            let diff = diffs[testCase["diffIndex"] as! Int]
            let style = IterationDiffStyle(rawValue: testCase["diffStyle"] as! String)!
            let totalLines = (testCase["totalLines"] as? Int) ?? .max
            let stopAfter = testCase["stopAfter"] as? Int
            var events: [String] = []
            var thrown: String?
            do {
                try iterateOverDiff(
                    diff: diff,
                    diffStyle: style,
                    startingLine: testCase["startingLine"] as! Int,
                    totalLines: totalLines,
                    expandedHunks: Self.expanded(testCase["expanded"]),
                    collapsedContextThreshold: testCase["collapsedContextThreshold"] as! Int
                ) { props in
                    events.append(
                        "\(props.hunkIndex)|\(props.hunk == nil ? 0 : 1)|\(props.type.rawValue)|\(props.collapsedBefore)|\(props.collapsedAfter)|\(Self.encode(props.deletionLine))|\(Self.encode(props.additionLine))"
                    )
                    if let stopAfter { return events.count >= stopAfter }
                    return false
                }
            } catch {
                thrown = "\(error)"
            }
            let expectedEvents = (testCase["events"] as! [[Any]]).map { event in
                "\(event[0])|\(event[1])|\(event[2])|\(event[3])|\(event[4])|\(Self.encodeExpected(event[5]))|\(Self.encodeExpected(event[6]))"
            }
            let expectedError = testCase["error"] as? String
            if (expectedError == nil) != (thrown == nil) {
                Issue.record("case \(caseIndex): error mismatch \(String(describing: thrown)) vs \(String(describing: expectedError))")
                failures += 1
                continue
            }
            if events != expectedEvents {
                failures += 1
                let firstMismatch = zip(events, expectedEvents).enumerated().first { $0.element.0 != $0.element.1 }
                Issue.record(
                    "case \(caseIndex) (\(style), start \(testCase["startingLine"]!), total \(totalLines)): count \(events.count) vs \(expectedEvents.count); first mismatch: \(String(describing: firstMismatch))"
                )
                if failures > 5 { break }
            }
        }
    }

    @Test func estimatedHeightsMatchUpstream() throws {
        let diffs = try Self.loadDiffs()
        let layout = try Self.loadLayout()
        let cases = layout["heightCases"] as! [[String: Any]]
        for (caseIndex, testCase) in cases.enumerated() {
            let diff = diffs[testCase["diffIndex"] as! Int]
            let m = testCase["metrics"] as! [String: Any]
            let metrics = VirtualFileMetrics(
                hunkLineCount: m["hunkLineCount"] as! Int,
                lineHeight: (m["lineHeight"] as! NSNumber).doubleValue,
                diffHeaderHeight: (m["diffHeaderHeight"] as! NSNumber).doubleValue,
                hunkSeparatorHeight: (m["hunkSeparatorHeight"] as? NSNumber)?.doubleValue,
                spacing: (m["spacing"] as! NSNumber).doubleValue,
                paddingTop: (m["paddingTop"] as? NSNumber)?.doubleValue,
                paddingBottom: (m["paddingBottom"] as? NSNumber)?.doubleValue
            )
            let expected = testCase["expected"] as! [String: Any]
            do {
                let result = try computeEstimatedDiffHeights(
                    fileDiff: diff,
                    metrics: metrics,
                    disableFileHeader: testCase["disableFileHeader"] as! Bool,
                    hunkSeparators: HunkSeparators(rawValue: testCase["hunkSeparators"] as! String)!,
                    expandUnchanged: testCase["expandUnchanged"] as! Bool,
                    expandedHunks: Self.expanded(testCase["expandedHunks"]),
                    collapsedContextThreshold: testCase["collapsedContextThreshold"] as! Int,
                    canHydratePartialDiff: testCase["canHydratePartialDiff"] as! Bool
                )
                #expect(expected["error"] == nil, "case \(caseIndex) expected error")
                #expect(result.splitHeight == (expected["splitHeight"] as? NSNumber)?.doubleValue, "case \(caseIndex) split")
                #expect(result.unifiedHeight == (expected["unifiedHeight"] as? NSNumber)?.doubleValue, "case \(caseIndex) unified")
            } catch {
                #expect(expected["error"] != nil, "case \(caseIndex) unexpected error \(error)")
            }
        }
    }

    @Test func renderableLinesMatchUpstream() throws {
        let diffs = try Self.loadDiffs()
        let layout = try Self.loadLayout()
        let cases = layout["renderableCases"] as! [[String: Any]]
        for testCase in cases {
            let diffIndex = testCase["diffIndex"] as! Int
            let diff = diffs[diffIndex]
            let expanded = Self.expanded(testCase["expanded"])
            let threshold = testCase["collapsedContextThreshold"] as! Int
            for (offset, entry) in (testCase["lines"] as! [[Any]]).enumerated() {
                let lineNumber = offset + 1
                if entry[0] as? String == "error" {
                    #expect(throws: (any Error).self) {
                        _ = try isAdditionLineRenderable(fileDiff: diff, lineNumber: lineNumber, expandedHunks: expanded, collapsedContextThreshold: threshold)
                        _ = try getNearestRenderableAdditionLine(fileDiff: diff, lineNumber: lineNumber, direction: .up, expandedHunks: expanded, collapsedContextThreshold: threshold)
                    }
                    continue
                }
                let renderable = try isAdditionLineRenderable(fileDiff: diff, lineNumber: lineNumber, expandedHunks: expanded, collapsedContextThreshold: threshold)
                let up = try getNearestRenderableAdditionLine(fileDiff: diff, lineNumber: lineNumber, direction: .up, expandedHunks: expanded, collapsedContextThreshold: threshold)
                let down = try getNearestRenderableAdditionLine(fileDiff: diff, lineNumber: lineNumber, direction: .down, expandedHunks: expanded, collapsedContextThreshold: threshold)
                #expect(renderable == entry[0] as? Bool, "diff \(diffIndex) line \(lineNumber) renderable")
                #expect(up == entry[1] as? Int, "diff \(diffIndex) line \(lineNumber) up")
                #expect(down == entry[2] as? Int, "diff \(diffIndex) line \(lineNumber) down")
            }
        }
    }
}
