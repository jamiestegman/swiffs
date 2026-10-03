import Foundation
import SwiffsCore
import Testing
@testable import SwiffsHighlight

struct HighlightServiceTests {
    private let options = RenderDiffOptions(theme: .pair(DiffsConstants.defaultThemes))

    @Test func concurrentRequestsForOneKeyedDiffShareOneComputation() async throws {
        let service = HighlightService(workerCount: 2)
        var diff = try ConcurrencyInvarianceTests.largeDiff()
        diff.cacheKey = "single-flight"
        async let first = service.highlight(diff, options: options)
        async let second = service.highlight(diff, options: options)
        let (a, b) = try await (first, second)
        #expect(a.additionLines == b.additionLines && a.deletionLines == b.deletionLines)
        #expect(service.cachedResult(for: diff, options: options)?.additionLines == a.additionLines)
    }

    @Test func keyedRequestsRunOnce() async throws {
        let service = HighlightService(workerCount: 2)
        var diff = try ConcurrencyInvarianceTests.largeDiff()
        diff.cacheKey = "once"
        service.prefetch(diff, options: options)
        service.prefetch(diff, options: options)
        #expect(service.pendingCount <= 1)
        _ = try await service.highlight(diff, options: options)
        #expect(service.pendingCount == 0)
    }

    @Test func unkeyedRequestsAreNotCached() async throws {
        let service = HighlightService(workerCount: 1)
        let diff = try ConcurrencyInvarianceTests.largeDiff()
        _ = try await service.highlight(diff, options: options)
        #expect(service.cachedResult(for: diff, options: options) == nil)
    }

    @Test func cancelledUnkeyedRequestsDoNotRun() async throws {
        let service = HighlightService(workerCount: 1)
        let diff = try ConcurrencyInvarianceTests.largeDiff()
        let task = Task { try await service.highlight(diff, options: options) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test @MainActor func smallContentHighlightsImmediately() throws {
        let service = HighlightService(workerCount: 1)
        var file = FileContents(name: "a.swift", contents: "let a = 1")
        file.cacheKey = "small"
        let options = RenderFileOptions()
        let result = try #require(service.immediateResult(for: file, lineCount: 1, options: options, lineLimit: 10))
        #expect(result.lines.count == 1)
        #expect(service.cachedResult(for: file, options: options) != nil)
        #expect(service.immediateResult(for: FileContents(name: "b.swift", contents: "let b = 2"), lineCount: 1, options: options, lineLimit: 0) == nil)
    }
}
