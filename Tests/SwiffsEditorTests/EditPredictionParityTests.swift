import Foundation
import Testing
@testable import SwiffsEditor

/// Parity with upstream `editPrediction.ts` (see
/// `generate-edit-prediction-fixtures.ts`).
struct EditPredictionParityTests {
    struct Fixture: Decodable {
        struct Step: Decodable {
            struct Edit: Decodable {
                var range: DocumentRange
                var newText: String
            }

            struct Record: Decodable, Equatable {
                var path: String
                var hunk: String
                var start: Int
                var end: Int
                var at: Double
                var source: String
            }

            var edit: Edit
            var source: String
            var at: Double
            var cursor: Int
            var history: [Record]
            var request: EditPredictRequest?
        }

        struct Case: Decodable {
            var seed: Int
            var text: String
            var steps: [Step]
        }

        struct PatternCase: Decodable {
            var pattern: String
            var path: String
            var match: Bool
        }

        var cases: [Case]
        var patternCases: [PatternCase]
    }

    static func load() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/edit-prediction.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test func historyAndRequestsMatchUpstream() throws {
        let fixture = try Self.load()
        for testCase in fixture.cases {
            let document = TextDocument<Never>(uri: "file.ts", text: testCase.text, languageId: "typescript")
            var history: [EditPredictionHistoryRecord] = []
            for (index, step) in testCase.steps.enumerated() {
                let label = "seed \(testCase.seed) step \(index)"
                guard let change = try document.applyEdits([TextEdit(range: step.edit.range, newText: step.edit.newText)]) else {
                    Issue.record("\(label): no change")
                    break
                }
                history = recordEditPrediction(history, path: "src/file.ts", document: document, change: change, source: EditPredictionSource(rawValue: step.source)!, at: step.at)
                let actualHistory = history.map { Fixture.Step.Record(path: $0.path, hunk: $0.hunk, start: $0.start, end: $0.end, at: $0.at, source: $0.source.rawValue) }
                if actualHistory != step.history {
                    Issue.record("\(label) history: \(actualHistory.map(\.hunk)) != \(step.history.map(\.hunk))")
                    break
                }
                let request = buildEditPredictionRequest(path: "src/file.ts", document: document, cursorOffset: step.cursor, history: history, isLineEditable: { $0 % 7 != 3 })
                if request != step.request {
                    Issue.record("\(label) request: \(String(describing: request)) != \(String(describing: step.request))")
                    break
                }
            }
        }
    }

    @Test func patternsMatchUpstream() throws {
        for testCase in try Self.load().patternCases {
            #expect(matchesEditPredictionPattern(testCase.path, .glob(testCase.pattern)) == testCase.match, "\(testCase.pattern) \(testCase.path)")
        }
    }
}
