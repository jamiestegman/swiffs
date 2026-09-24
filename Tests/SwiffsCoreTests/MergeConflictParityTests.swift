import Foundation
import Testing
@testable import SwiffsCore

/// Parity with upstream `parseMergeConflictDiffFromFile`,
/// `getMergeConflictParseResult`, `resolveConflict` and
/// `diffAcceptRejectHunk` (see `generate-merge-conflict-fixtures.ts`).
struct MergeConflictParityTests {
    private static func load() throws -> [String: Any] {
        let data = try Data(contentsOf: Fixtures.directory.appendingPathComponent("merge-conflicts.json"))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// Mirrors the generator's FNV-1a line hash.
    private static func hashLines(_ lines: [String]) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for (index, line) in lines.enumerated() {
            if index > 0 {
                hash ^= 0
                hash = hash &* 0x0100_0193
            }
            for unit in line.utf16 {
                hash ^= UInt32(unit)
                hash = hash &* 0x0100_0193
            }
        }
        return "\(lines.count):\(String(hash, radix: 16))"
    }

    private static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }

    private static func digest(_ diff: FileDiffMetadata) throws -> Any {
        var object = try json(diff) as! [String: Any]
        object["deletionLines"] = hashLines(diff.deletionLines)
        object["additionLines"] = hashLines(diff.additionLines)
        return object
    }

    private static func file(_ file: FileContents) throws -> Any {
        var object = try json(file) as! [String: Any]
        object["contents"] = hashLines([file.contents])
        return object
    }

    private static func compare(_ actual: Any, _ expected: Any, _ label: String) {
        if let difference = diffJSON(actual, expected, path: "$") {
            Issue.record("\(label): \(difference)")
        }
    }

    private static func errorMessage(_ error: Error) -> String {
        (error as? DiffsError)?.message ?? String(describing: error)
    }

    @Test func conflictParsingAndResolutionMatchUpstream() throws {
        let cases = try Self.load()["cases"] as! [[String: Any]]
        #expect(cases.count > 5)
        for testCase in cases {
            let fileObject = testCase["file"] as! [String: Any]
            let input = FileContents(name: fileObject["name"] as! String, contents: fileObject["contents"] as! String)
            let name = input.name

            let lineResult = getMergeConflictParseResult(splitFileContents(input.contents))
            Self.compare(lineResult.lineTypes.map(\.rawValue), testCase["lineTypes"]!, "\(name) lineTypes")
            Self.compare(try Self.json(lineResult.regions), testCase["regions"]!, "\(name) regions")

            for parse in testCase["parses"] as! [[String: Any]] {
                let context = (parse["maxContextLines"] as? Int) ?? Int.max
                let label = "\(name) context=\(context)"
                let result: ParseMergeConflictDiffFromFileResult
                do {
                    result = try parseMergeConflictDiffFromFile(input, maxContextLines: context)
                } catch {
                    Self.compare(Self.errorMessage(error), parse["error"] ?? "no error", "\(label) error")
                    continue
                }
                if let expectedError = parse["error"] {
                    Issue.record("\(label): expected error \(expectedError)")
                    continue
                }
                Self.compare(try Self.digest(result.fileDiff), parse["fileDiff"]!, "\(label) fileDiff")
                Self.compare(try Self.file(result.currentFile), parse["currentFile"]!, "\(label) currentFile")
                Self.compare(try Self.file(result.incomingFile), parse["incomingFile"]!, "\(label) incomingFile")
                let actions: [Any] = try result.actions.map { try $0.map(Self.json) ?? NSNull() }
                Self.compare(actions, parse["actions"]!, "\(label) actions")
                Self.compare(try Self.json(result.markerRows), parse["markerRows"]!, "\(label) markerRows")

                for resolution in parse["resolutions"] as! [[String: Any]] {
                    let actionIndex = resolution["actionIndex"] as! Int
                    let type = MergeConflictResolution(rawValue: resolution["type"] as! String)!
                    let expected = resolution["resolved"] as! [String: Any]
                    let resolvedLabel = "\(label) action=\(actionIndex) \(type)"
                    guard let action = result.actions[actionIndex] else {
                        Issue.record("\(resolvedLabel): missing action")
                        continue
                    }
                    do {
                        let resolved = try resolveConflict(result.fileDiff, conflict: action.conflictData, type: type)
                        Self.compare(try Self.digest(resolved), expected, resolvedLabel)
                    } catch {
                        Self.compare(Self.errorMessage(error), expected["error"] ?? "no error", "\(resolvedLabel) error")
                    }
                }
            }
        }
    }

    @Test func acceptRejectHunkMatchesUpstream() throws {
        let cases = try Self.load()["acceptReject"] as! [[String: Any]]
        #expect(!cases.isEmpty)
        for testCase in cases {
            let name = testCase["name"] as! String
            var options = CreatePatchOptions()
            if let context = testCase["context"] as? Int { options.context = context }
            let diff = try parseDiffFromFile(
                oldFile: FileContents(name: name, contents: testCase["oldContents"] as! String, cacheKey: "\(name)-old"),
                newFile: FileContents(name: name, contents: testCase["newContents"] as! String, cacheKey: "\(name)-new"),
                options: options
            )
            let label = "\(name) context=\(String(describing: testCase["context"]))"
            Self.compare(try Self.digest(diff), testCase["diff"]!, "\(label) diff")
            for result in testCase["results"] as! [[String: Any]] {
                let hunkIndex = result["hunkIndex"] as! Int
                let type = DiffAcceptRejectHunkType(rawValue: result["type"] as! String)!
                let changeIndex = result["changeIndex"] as? Int
                let expected = result["resolved"] as! [String: Any]
                let resultLabel = "\(label) hunk=\(hunkIndex) \(type) change=\(String(describing: changeIndex))"
                do {
                    let resolved = try diffAcceptRejectHunk(diff, hunkIndex: hunkIndex, type: type, changeIndex: changeIndex)
                    Self.compare(try Self.digest(resolved), expected, resultLabel)
                } catch {
                    Self.compare(Self.errorMessage(error), expected["error"] ?? "no error", "\(resultLabel) error")
                }
            }
        }
    }

    @Test func sequentialResolutionMatchesUpstream() throws {
        let sequences = try Self.load()["sequences"] as! [[String: Any]]
        #expect(sequences.count > 10)
        for sequence in sequences {
            let fileObject = sequence["file"] as! [String: Any]
            var file = FileContents(
                name: fileObject["name"] as! String,
                contents: fileObject["contents"] as! String,
                cacheKey: fileObject["cacheKey"] as? String
            )
            let type = MergeConflictResolution(rawValue: sequence["type"] as! String)!
            let parsed = try parseMergeConflictDiffFromFile(file)
            var fileDiff = parsed.fileDiff
            var actions = parsed.actions
            for (stepIndex, step) in (sequence["steps"] as! [[String: Any]]).enumerated() {
                let conflictIndex = step["conflictIndex"] as! Int
                let label = "\(file.name) \(type) \(sequence["order"]!) step=\(stepIndex)"
                let result = try resolveUnresolvedConflict(
                    fileDiff: fileDiff,
                    actions: actions,
                    conflictIndex: conflictIndex,
                    resolution: type,
                    previousFile: file
                )
                guard let expected = step["result"] as? [String: Any] else {
                    #expect(result == nil, "\(label)")
                    continue
                }
                guard let result else {
                    Issue.record("\(label): expected a result")
                    break
                }
                Self.compare(try Self.json(result.file), expected["file"]!, "\(label) file")
                Self.compare(try Self.digest(result.fileDiff), expected["fileDiff"]!, "\(label) fileDiff")
                let resultActions: [Any] = try result.actions.map { try $0.map(Self.json) ?? NSNull() }
                Self.compare(resultActions, expected["actions"]!, "\(label) actions")
                Self.compare(try Self.json(result.markerRows), expected["markerRows"]!, "\(label) markerRows")
                file = result.file
                fileDiff = result.fileDiff
                actions = result.actions
            }
        }
    }
}
