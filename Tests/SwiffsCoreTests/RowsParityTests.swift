import Foundation
import Testing
@testable import SwiffsCore

/// Differential tests for `buildDiffRows` against upstream
/// `DiffHunksRenderer.processDiffResult`.
struct RowsParityTests {
    static func encodeColumn(_ cells: [RenderCell], options: DiffRowsOptions) -> [String] {
        var out: [String] = []
        var pendingBuffer = 0
        func flushBuffer() {
            if pendingBuffer > 0 {
                out.append("buf|\(pendingBuffer)")
                pendingBuffer = 0
            }
        }
        for cell in cells {
            if case .buffer = cell {
                pendingBuffer += 1
                continue
            }
            flushBuffer()
            switch cell {
            case .line(let line):
                let prefix = line.side == .deletions ? "d" : "a"
                out.append("line|\(prefix)\(line.lineIndex)|\(line.lineNumber)|\(line.lineType.rawValue)|\(line.unifiedLineIndex),\(line.splitLineIndex)")
            case .annotation(let annotation):
                let slots = annotation.keys.map { key in
                    "annotation-\(key.side.map { "\($0.rawValue)-" } ?? "")\(key.lineNumber)"
                }
                out.append("ann|\(annotation.hunkIndex),\(annotation.lineIndex)|\(slots.joined(separator: ","))")
            case .separator(let separator):
                let isLineInfo = separator.type == .lineInfo || separator.type == .lineInfoBasic
                let type: String = {
                    // `createSeparator` reports `simple` when it has no children.
                    if separator.type == .metadata { return separator.content != nil ? "metadata" : "simple" }
                    return separator.type.rawValue
                }()
                let expandIndex = isLineInfo && separator.expandable != nil ? "\(separator.hunkIndex)" : "null"
                let text = separator.type == .simple ? "null" : separator.label
                out.append("sep|\(type)|\(expandIndex)|\(separator.isFirstHunk)|\(separator.isLastHunk)|\(text)")
            case .noNewline(let type):
                out.append("nonl|\(type.rawValue)")
            case .injected:
                out.append("injected")
            case .buffer:
                break
            }
        }
        flushBuffer()
        return out
    }

    static func encodeExpected(_ column: [[Any]]?) -> [String]? {
        guard let column else { return nil }
        return column.map { entry in
            let kind = entry[0] as! String
            func s(_ v: Any) -> String {
                if v is NSNull { return "null" }
                if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
                return "\(v)"
            }
            switch kind {
            case "line": return "line|\(s(entry[1]))|\(s(entry[2]))|\(s(entry[3]))|\(s(entry[4]))"
            case "ann":
                // Multiple annotations on one line share a slot name upstream;
                // the native model groups them under one key.
                var seen: Set<String> = []
                let slots = (entry[2] as! [String]).filter { seen.insert($0).inserted }.joined(separator: ",")
                return "ann|\(s(entry[1]))|\(slots)"
            case "sep": return "sep|\(s(entry[1]))|\(s(entry[2]))|\(s(entry[3]))|\(s(entry[4]))|\(s(entry[5]))"
            case "nonl": return "nonl|\(s(entry[1]))"
            case "buf": return "buf|\(s(entry[1]))"
            default: return "unknown"
            }
        }
    }

    @Test func rowsMatchUpstream() throws {
        let diffs = try LayoutParityTests.loadDiffs()
        let data = try Data(contentsOf: Fixtures.directory.appendingPathComponent("rows.json"))
        let cases = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        #expect(cases.count > 100)
        var failures: [String] = []
        for (caseIndex, testCase) in cases.enumerated() {
            let diff = diffs[testCase["diffIndex"] as! Int]
            let o = testCase["options"] as! [String: Any]
            let options = DiffRowsOptions(
                diffStyle: DiffStyle(rawValue: o["diffStyle"] as! String)!,
                hunkSeparators: HunkSeparators(rawValue: o["hunkSeparators"] as! String)!,
                expandUnchanged: o["expandUnchanged"] as! Bool,
                collapsedContextThreshold: o["collapsedContextThreshold"] as! Int,
                expansionLineCount: o["expansionLineCount"] as! Int,
                canLoadDiffFiles: o["canLoadDiffFiles"] as! Bool
            )
            var expanded: [Int: HunkExpansionRegion] = [:]
            for entry in testCase["expanded"] as! [[Any]] {
                let region = entry[1] as! [String: Int]
                expanded[entry[0] as! Int] = HunkExpansionRegion(fromStart: region["fromStart"]!, fromEnd: region["fromEnd"]!)
            }
            var deletionLines: Set<Int> = []
            var additionLines: Set<Int> = []
            for annotation in testCase["annotations"] as! [[String: Any]] {
                if annotation["side"] as! String == "deletions" {
                    deletionLines.insert(annotation["lineNumber"] as! Int)
                } else {
                    additionLines.insert(annotation["lineNumber"] as! Int)
                }
            }
            let expectedError = testCase["error"] as? String
            let result: DiffRowsResult
            do {
                result = try buildDiffRows(
                    fileDiff: diff,
                    options: options,
                    expandedHunks: expanded,
                    deletionAnnotationLines: deletionLines,
                    additionAnnotationLines: additionLines
                )
            } catch {
                if expectedError == nil { failures.append("case \(caseIndex): unexpected error \(error)") }
                continue
            }
            if expectedError != nil {
                failures.append("case \(caseIndex): expected error \(expectedError!)")
                continue
            }
            func column(_ index: Int) -> [RenderCell] { result.rows.compactMap { $0.cells[index] } }
            let actualUnified = options.diffStyle == .unified ? Self.encodeColumn(column(0), options: options) : nil
            let actualDeletions = options.diffStyle == .split && result.hasDeletionsColumn ? Self.encodeColumn(column(0), options: options) : nil
            let actualAdditions = options.diffStyle == .split && result.hasAdditionsColumn ? Self.encodeColumn(column(1), options: options) : nil
            let expectedUnified = Self.encodeExpected(testCase["unified"] as? [[Any]])
            let expectedDeletions = Self.encodeExpected(testCase["deletions"] as? [[Any]])
            let expectedAdditions = Self.encodeExpected(testCase["additions"] as? [[Any]])
            for (name, actual, expected) in [
                ("unified", actualUnified, expectedUnified),
                ("deletions", actualDeletions, expectedDeletions),
                ("additions", actualAdditions, expectedAdditions),
            ] {
                // Upstream omits empty columns; treat empty as absent.
                let a = (actual?.isEmpty ?? true) ? nil : actual
                let e = (expected?.isEmpty ?? true) ? nil : expected
                if a != e {
                    let firstDiff = (0 ..< min(a?.count ?? 0, e?.count ?? 0)).first { a![$0] != e![$0] }
                    failures.append(
                        "case \(caseIndex) diff \(testCase["diffIndex"]!) \(o) \(name): counts \(a?.count ?? -1) vs \(e?.count ?? -1); first diff at \(String(describing: firstDiff)): \(firstDiff.map { a![$0] } ?? "-") vs \(firstDiff.map { e![$0] } ?? "-")"
                    )
                }
            }
            if let rowCount = testCase["rowCount"] as? Int, rowCount != result.rows.count {
                failures.append("case \(caseIndex): rowCount \(result.rows.count) vs \(rowCount)")
            }
            if let totalLines = testCase["totalLines"] as? Int, totalLines != result.totalLines {
                failures.append("case \(caseIndex): totalLines \(result.totalLines) vs \(totalLines)")
            }
            let expectedHunkData = (testCase["hunkData"] as? [[String: Any]] ?? []).map { "\($0["slotName"]!)|\($0["hunkIndex"]!)|\($0["lines"]!)" }
            let actualHunkData = result.hunkData.map { "\($0.slotName)|\($0.hunkIndex)|\($0.lines)" }
            if expectedHunkData != actualHunkData {
                failures.append("case \(caseIndex): hunkData \(actualHunkData) vs \(expectedHunkData)")
            }
        }
        if !failures.isEmpty {
            let summary = failures.prefix(12).joined(separator: "\n")
            Issue.record("\(failures.count) failures:\n\(summary)")
        }
    }
}
