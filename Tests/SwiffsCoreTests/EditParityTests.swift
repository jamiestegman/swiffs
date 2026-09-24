import Foundation
import Testing
@testable import SwiffsCore

/// Parity with upstream `trimPatchContext` and `updateDiffHunks.ts`
/// (see `generate-edit-fixtures.ts`).
struct EditParityTests {
    struct Fixture: Decodable {
        struct Trim: Decodable {
            var name: String
            var patch: String
            var contextSize: Int
            var expected: String
        }

        struct Update: Decodable {
            var name: String
            var oldContents: String
            var newContents: String
            var context: Int
            var additionLines: [String]
            var changed: [Int]
            var updated: FileDiffMetadata
            var recomputedForEdit: FileDiffMetadata
        }

        var trims: [Trim]
        var updates: [Update]
    }

    @Test func trimPatchContextMatchesUpstream() throws {
        let fixture = try Fixtures.load("edit.json", as: Fixture.self)
        #expect(!fixture.trims.isEmpty)
        for trim in fixture.trims {
            let actual = trimPatchContext(trim.patch, contextSize: trim.contextSize)
            #expect(actual.utf16.elementsEqual(trim.expected.utf16), "\(trim.name) context=\(trim.contextSize)")
        }
    }

    @Test func updateDiffHunksMatchesUpstream() throws {
        let fixture = try Fixtures.load("edit.json", as: Fixture.self)
        #expect(!fixture.updates.isEmpty)
        for update in fixture.updates {
            var options = CreatePatchOptions()
            options.context = update.context
            let name = update.name.components(separatedBy: "/")[0]
            let diff = try parseDiffFromFile(
                oldFile: FileContents(name: name, contents: update.oldContents),
                newFile: FileContents(name: name, contents: update.newContents),
                options: options
            )
            var updated = diff
            updated.additionLines = update.additionLines
            updateDiffHunks(&updated, changedAdditionLineIndexes: update.changed, options: options)
            if updated != update.updated {
                Issue.record("\(update.name) context=\(update.context) updateDiffHunks: \(firstDifference(updated, update.updated) ?? "mismatch")")
            }
            var edited = diff
            edited.additionLines = update.additionLines
            recomputeDiffHunksForEdit(&edited, options: options)
            if edited != update.recomputedForEdit {
                Issue.record("\(update.name) context=\(update.context) recomputeDiffHunksForEdit: \(firstDifference(edited, update.recomputedForEdit) ?? "mismatch")")
            }
        }
    }
}
