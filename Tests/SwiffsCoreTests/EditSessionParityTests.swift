import Foundation
import Testing
@testable import SwiffsCore

/// Parity with upstream `editSessionHunks.ts` (see
/// `generate-edit-session-fixtures.ts`).
struct EditSessionParityTests {
    struct Step: Decodable {
        var type: String
        var lines: [Int]?
        var previousAdditionLines: [[PreviousLine]]?
        var additionLines: [String]?
        var result: SessionResult?
        var remappedExpansion: [[ExpansionEntry]]?
        var diff: FileDiffMetadata
        var error: String?
    }

    enum PreviousLine: Decodable {
        case index(Int)
        case text(String)
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let index = try? container.decode(Int.self) { self = .index(index) } else { self = .text(try container.decode(String.self)) }
        }
    }

    enum ExpansionEntry: Decodable {
        case key(Int)
        case region(HunkExpansionRegion)
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let key = try? container.decode(Int.self) { self = .key(key) } else { self = .region(try container.decode(HunkExpansionRegion.self)) }
        }
    }

    /// `SessionRegionChange` or `DivergenceCore`.
    struct SessionResult: Decodable {
        struct Span: Decodable { var firstIndex: Int; var lastIndex: Int }
        var regions: [Span?]?
        var start: Int?
        var deletionEnd: Int?
        var additionEnd: Int?
    }

    struct Case: Decodable {
        var seed: Int
        var context: Int
        var oldContents: String
        var newContents: String
        var steps: [Step]
        var finished: Bool
        var finalDiff: FileDiffMetadata
        var rebuiltExpansion: [[ExpansionEntry]]?
    }

    private static func expansion(_ entries: [[ExpansionEntry]]) -> [Int: HunkExpansionRegion] {
        var map: [Int: HunkExpansionRegion] = [:]
        for entry in entries {
            if case .key(let key) = entry[0], case .region(let region) = entry[1] { map[key] = region }
        }
        return map
    }

    @Test func editSessionHunksMatchUpstream() throws {
        let cases = try Fixtures.load("edit-session.json", as: [Case].self)
        #expect(cases.count > 50)
        for testCase in cases {
            var options = CreatePatchOptions()
            options.context = testCase.context
            var diff = try parseDiffFromFile(
                oldFile: FileContents(name: "f.txt", contents: testCase.oldContents),
                newFile: FileContents(name: "f.txt", contents: testCase.newContents),
                options: options
            )
            let expanded: [Int: HunkExpansionRegion] = [0: .init(fromStart: 2, fromEnd: 1), 1: .init(fromStart: 1, fromEnd: 3)]
            for (index, step) in testCase.steps.enumerated() {
                let label = "seed \(testCase.seed) step \(index) \(step.type)"
                let previous = diff.additionLines
                switch step.type {
                case "changed":
                    diff.additionLines = step.additionLines!
                    var previousMap: [Int: String] = [:]
                    for entry in step.previousAdditionLines ?? [] {
                        if case .index(let line) = entry[0], case .text(let text) = entry[1] { previousMap[line] = text }
                    }
                    let result = try applySessionChangedLines(&diff, changedAdditionLineIndexes: step.lines!, options: options, previousAdditionLines: previousMap)
                    #expect((result == nil) == (step.result == nil), "\(label) result presence")
                case "rebuild":
                    diff.additionLines = step.additionLines!
                    if let expectedError = step.error {
                        do {
                            try rebuildSessionHunks(&diff, options: options, getPreviousAdditionLine: { $0 >= 0 && $0 < previous.count ? previous[$0] : nil })
                            Issue.record("\(label): expected error \(expectedError)")
                        } catch {
                            #expect((error as? DiffsError)?.message == expectedError, "\(label) error")
                        }
                        break
                    }
                    let result = try rebuildSessionHunks(&diff, options: options, getPreviousAdditionLine: { $0 >= 0 && $0 < previous.count ? previous[$0] : nil })
                    #expect((result == nil) == (step.result == nil), "\(label) result presence")
                    if let result, let expected = step.result?.regions {
                        #expect(result.regions.map { $0.map { [$0.firstIndex, $0.lastIndex] } } == expected.map { $0.map { [$0.firstIndex, $0.lastIndex] } }, "\(label) regions")
                        if let remapped = step.remappedExpansion {
                            #expect(remapExpandedHunksForRegionChange(expanded, result) == Self.expansion(remapped), "\(label) expansion")
                        }
                    }
                default:
                    let core = findDivergenceCore(diff.deletionLines, diff.additionLines)
                    #expect(core?.start == step.result?.start && core?.deletionEnd == step.result?.deletionEnd && core?.additionEnd == step.result?.additionEnd, "\(label) core")
                }
                if diff != step.diff {
                    Issue.record("\(label): \(firstDifference(diff, step.diff) ?? "mismatch")")
                    break
                }
            }
            let anchors = try? captureExpansionAnchors(diff, expanded, collapsedContextThreshold: 4)
            let finished = finishEditSessionForDiff(&diff, options: options)
            #expect(finished == testCase.finished, "seed \(testCase.seed) finished")
            if diff != testCase.finalDiff {
                Issue.record("seed \(testCase.seed) final: \(firstDifference(diff, testCase.finalDiff) ?? "mismatch")")
            }
            if let anchors, let expected = testCase.rebuiltExpansion {
                #expect(rebuildExpansionFromAnchors(diff, anchors) == Self.expansion(expected), "seed \(testCase.seed) rebuilt expansion")
            }
        }
    }
}
