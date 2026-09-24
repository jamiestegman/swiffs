import Foundation
import Testing
@testable import SwiffsCore

/// Parity with upstream `hydratePartialDiff` (see
/// `generate-hydrate-fixtures.ts`).
struct HydrateParityTests {
    struct Case: Decodable {
        var name: String
        var patch: String
        var oldFile: FileContents
        var newFile: FileContents
        var expected: FileDiffMetadata
    }

    @Test func hydratePartialDiffMatchesUpstream() throws {
        let cases = try Fixtures.load("hydrate.json", as: [Case].self)
        #expect(cases.count > 20)
        for testCase in cases {
            let partial = try getSingularPatch(testCase.patch)
            var oldFile = testCase.oldFile
            oldFile.cacheKey = "old-key"
            var newFile = testCase.newFile
            newFile.cacheKey = "new-key"
            let hydrated = try hydratePartialDiff(partial, files: DiffLoadedFiles(oldFile: oldFile, newFile: newFile))
            if hydrated != testCase.expected {
                Issue.record("\(testCase.name): \(firstDifference(hydrated, testCase.expected) ?? "mismatch")")
            }
        }
    }
}
