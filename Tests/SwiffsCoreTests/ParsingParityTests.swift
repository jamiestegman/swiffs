import Foundation
import Testing
@testable import SwiffsCore

/// Differential tests against golden output produced by the upstream
/// TypeScript implementation (see `Scripts/fixtures`).
struct ParsingParityTests {
    struct PatchCase: Decodable {
        var name: String
        var input: String
        var cacheKeyPrefix: String?
        var expected: [ParsedPatch]
    }

    struct FileCase: Decodable {
        struct Options: Decodable {
            var context: Int?
            var ignoreWhitespace: Bool?
        }

        var name: String
        var oldFile: FileContents?
        var newFile: FileContents?
        var options: Options?
        var expected: FileDiffMetadata
    }

    struct LineDiffCase: Decodable {
        struct Change: Decodable, Equatable {
            var value: String
            var added: Bool
            var removed: Bool
            var count: Int
        }

        var old: String
        var new: String
        var words: [Change]
        var chars: [Change]
    }

    @Test func parsePatchFilesMatchesUpstream() throws {
        let cases = try Fixtures.load("parsePatchFiles.json", as: [PatchCase].self)
        #expect(!cases.isEmpty)
        for testCase in cases {
            let actual = parsePatchFiles(testCase.input, cacheKeyPrefix: testCase.cacheKeyPrefix)
            if actual != testCase.expected {
                Issue.record("\(testCase.name): \(firstDifference(actual, testCase.expected) ?? "mismatch")")
            }
        }
    }

    @Test func parseDiffFromFileMatchesUpstream() throws {
        let cases = try Fixtures.load("parseDiffFromFile.json", as: [FileCase].self)
        #expect(!cases.isEmpty)
        for testCase in cases {
            var options = CreatePatchOptions()
            if let context = testCase.options?.context { options.context = context }
            if let ignoreWhitespace = testCase.options?.ignoreWhitespace { options.ignoreWhitespace = ignoreWhitespace }
            let actual = try parseDiffFromFile(oldFile: testCase.oldFile, newFile: testCase.newFile, options: options)
            if actual != testCase.expected {
                Issue.record("\(testCase.name): \(firstDifference(actual, testCase.expected) ?? "mismatch")")
            }
        }
    }

    @Test func lineDiffsMatchUpstream() throws {
        let cases = try Fixtures.load("lineDiffs.json", as: [LineDiffCase].self)
        #expect(!cases.isEmpty)
        for testCase in cases {
            let words = diffWordsWithSpace(testCase.old, testCase.new).map {
                LineDiffCase.Change(value: $0.value, added: $0.added, removed: $0.removed, count: $0.count)
            }
            let chars = diffChars(testCase.old, testCase.new).map {
                LineDiffCase.Change(value: $0.value, added: $0.added, removed: $0.removed, count: $0.count)
            }
            #expect(words == testCase.words, "words: \(testCase.old.debugDescription) -> \(testCase.new.debugDescription)")
            #expect(chars == testCase.chars, "chars: \(testCase.old.debugDescription) -> \(testCase.new.debugDescription)")
        }
    }
}
