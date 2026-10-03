import Foundation
import SwiffsCore
import Testing
@testable import SwiffsHighlight

/// Requests for a result that is already being computed wait for it instead
/// of computing it again.
struct WorkerPoolSingleFlightTests {
    private func submitTwice(_ diff: FileDiffMetadata, to pool: HighlightWorkerPool) async throws -> (pending: Int, ThemedDiffResult, ThemedDiffResult) {
        let options = RenderDiffOptions(theme: .pair(DiffsConstants.defaultThemes))
        var pending = 0
        let results: [ThemedDiffResult] = try await withThrowingTaskGroup(of: ThemedDiffResult.self) { group in
            let first = AsyncThrowingStream<ThemedDiffResult, Error>.makeStream()
            let second = AsyncThrowingStream<ThemedDiffResult, Error>.makeStream()
            pool.highlightDiff(diff, options: options) { first.continuation.yield(with: $0); first.continuation.finish() }
            pool.highlightDiff(diff, options: options) { second.continuation.yield(with: $0); second.continuation.finish() }
            pending = pool.stats.pendingTasks
            group.addTask { for try await value in first.stream { return value }; throw CancellationError() }
            group.addTask { for try await value in second.stream { return value }; throw CancellationError() }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        return (pending, results[0], results[1])
    }

    @Test func concurrentRequestsForOneKeyedDiffShareOneJob() async throws {
        let pool = HighlightWorkerPool(workerCount: 1)
        var diff = try ConcurrencyInvarianceTests.largeDiff()
        diff.cacheKey = "single-flight"
        let (pending, a, b) = try await submitTwice(diff, to: pool)
        #expect(pending == 1, "one job for both requests")
        #expect(a.additionLines == b.additionLines && a.deletionLines == b.deletionLines)
        #expect(pool.cachedDiffResult(diff, options: RenderDiffOptions(theme: .pair(DiffsConstants.defaultThemes)))?.additionLines == a.additionLines)
    }

    @Test func requestsForAnUnkeyedDiffEachRun() async throws {
        let pool = HighlightWorkerPool(workerCount: 1)
        let (pending, _, _) = try await submitTwice(try ConcurrencyInvarianceTests.largeDiff(), to: pool)
        #expect(pending == 2, "nothing identifies them as the same work")
    }
}
