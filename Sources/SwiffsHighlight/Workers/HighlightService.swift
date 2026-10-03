// Highlights diffs and files off the caller's thread on a bounded set of
// workers, caching results by content key (upstream's `WorkerPoolManager`).

import Foundation
import SwiffsCore
import Synchronization

/// A small LRU map (the `lru_map` dependency upstream).
struct LRUCache<Key: Hashable, Value> {
    private var values: [Key: Value] = [:]
    private var order: [Key] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func get(_ key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return value
    }

    mutating func set(_ key: Key, _ value: Value) {
        if values[key] != nil, let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        values[key] = value
        order.append(key)
        while order.count > capacity {
            values.removeValue(forKey: order.removeFirst())
        }
    }

    mutating func removeAll() {
        values.removeAll()
        order.removeAll()
    }

    var count: Int { values.count }
}

/// One highlighter (and its side highlighter for large diffs), used by one
/// task at a time.
actor HighlightWorker {
    private let highlighter: DiffsHighlighter

    init(registry: HighlighterRegistry) {
        let highlighter = DiffsHighlighter(registry: registry)
        highlighter.sideHighlighter = DiffsHighlighter(registry: registry)
        self.highlighter = highlighter
    }

    func render(_ diff: FileDiffMetadata, options: RenderDiffOptions, plainText: Bool) throws -> ThemedDiffResult {
        try highlighter.renderDiff(diff, options: options, plainText: ForceDiffPlainTextOptions(forcePlainText: plainText, expandedHunks: plainText ? .all : nil))
    }

    func render(_ file: FileContents, options: RenderFileOptions, plainText: Bool) throws -> ThemedFileResult {
        try highlighter.renderFile(file, options: options, forcePlainText: plainText)
    }
}

/// Highlights on background workers. It is the only code in Swiffs that
/// moves work off the caller's thread: callers `await` a result, and
/// requests for content with a cache key share one computation and one
/// cached result.
public final class HighlightService: Sendable {
    public static let shared = HighlightService()

    private enum Key: Hashable, Sendable {
        case diff(String, RenderDiffOptions)
        case file(String, RenderFileOptions)
    }

    private enum Output: Sendable {
        case diff(ThemedDiffResult)
        case file(ThemedFileResult)
    }

    private struct State {
        /// Requests queued or running on each worker.
        var load: [Int]
        var cache: LRUCache<Key, Output>
        var inFlight: [Key: Task<Output, any Error>] = [:]
    }

    private let workers: [HighlightWorker]
    private let state: Mutex<State>

    public init(
        workerCount: Int = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 1)),
        cacheCapacity: Int = 100,
        registry: HighlighterRegistry = .shared
    ) {
        workers = (0 ..< max(1, workerCount)).map { _ in HighlightWorker(registry: registry) }
        state = Mutex(State(load: Array(repeating: 0, count: workers.count), cache: LRUCache(capacity: cacheCapacity)))
    }

    /// Requests queued or running.
    public var pendingCount: Int { state.withLock { $0.load.reduce(0, +) } }

    /// The cached result for a keyed diff, if any.
    public func cachedResult(for diff: FileDiffMetadata, options: RenderDiffOptions) -> ThemedDiffResult? {
        guard let key = diff.cacheKey, case .diff(let result)? = state.withLock({ $0.cache.get(.diff(key, options)) }) else { return nil }
        return result
    }

    /// The cached result for a keyed file, if any.
    public func cachedResult(for file: FileContents, options: RenderFileOptions) -> ThemedFileResult? {
        guard let key = file.cacheKey, case .file(let result)? = state.withLock({ $0.cache.get(.file(key, options)) }) else { return nil }
        return result
    }

    /// Highlights a diff. With `plainText`, lines are split and diffed but not
    /// tokenized.
    @concurrent
    public func highlight(_ diff: FileDiffMetadata, options: RenderDiffOptions, plainText: Bool = false) async throws -> ThemedDiffResult {
        let key = plainText ? nil : diff.cacheKey.map { Key.diff($0, options) }
        let output = try await result(for: key) { worker in .diff(try await worker.render(diff, options: options, plainText: plainText)) }
        guard case .diff(let result) = output else { preconditionFailure("A diff key produced a file result") }
        return result
    }

    /// Highlights a file.
    @concurrent
    public func highlight(_ file: FileContents, options: RenderFileOptions, plainText: Bool = false) async throws -> ThemedFileResult {
        let key = plainText ? nil : file.cacheKey.map { Key.file($0, options) }
        let output = try await result(for: key) { worker in .file(try await worker.render(file, options: options, plainText: plainText)) }
        guard case .file(let result) = output else { preconditionFailure("A file key produced a diff result") }
        return result
    }

    /// Starts highlighting keyed content so a later request finds it cached
    /// or in flight. Unkeyed content is ignored.
    public func prefetch(_ diff: FileDiffMetadata, options: RenderDiffOptions) {
        guard let cacheKey = diff.cacheKey else { return }
        startIfNeeded(.diff(cacheKey, options)) { worker in .diff(try await worker.render(diff, options: options, plainText: false)) }
    }

    public func prefetch(_ file: FileContents, options: RenderFileOptions) {
        guard let cacheKey = file.cacheKey else { return }
        startIfNeeded(.file(cacheKey, options)) { worker in .file(try await worker.render(file, options: options, plainText: false)) }
    }

    /// Clears cached results, for example after registering themes.
    public func clearCache() {
        state.withLock { $0.cache.removeAll() }
    }

    private func result(for key: Key?, work: @escaping @Sendable (HighlightWorker) async throws -> Output) async throws -> Output {
        guard let key else {
            try Task.checkCancellation()
            return try await run(work)
        }
        switch lookup(key, work: work) {
        case .cached(let output): return output
        case .running(let task): return try await task.value
        }
    }

    private enum Lookup {
        case cached(Output)
        case running(Task<Output, any Error>)
    }

    private func startIfNeeded(_ key: Key, work: @escaping @Sendable (HighlightWorker) async throws -> Output) {
        _ = lookup(key, work: work)
    }

    /// The cached output for a key, or the task computing it, started if no
    /// request has started it yet.
    private func lookup(_ key: Key, work: @escaping @Sendable (HighlightWorker) async throws -> Output) -> Lookup {
        state.withLock { state in
            if let cached = state.cache.get(key) { return .cached(cached) }
            if let running = state.inFlight[key] { return .running(running) }
            let task = Task {
                do {
                    let output = try await self.run(work)
                    self.state.withLock { state in
                        state.cache.set(key, output)
                        state.inFlight[key] = nil
                    }
                    return output
                } catch {
                    self.state.withLock { $0.inFlight[key] = nil }
                    throw error
                }
            }
            state.inFlight[key] = task
            return .running(task)
        }
    }

    /// Runs work on the least loaded worker.
    private func run(_ work: @Sendable (HighlightWorker) async throws -> Output) async throws -> Output {
        let index = state.withLock { state in
            let index = state.load.indices.min { state.load[$0] < state.load[$1] }!
            state.load[index] += 1
            return index
        }
        defer { state.withLock { $0.load[index] -= 1 } }
        return try await work(workers[index])
    }
}

extension HighlightService {
    /// Highlights small content synchronously on the main actor, so a view's
    /// first frame is already highlighted. Returns the cached result for
    /// keyed content; nil when the content has more than `lineLimit` lines.
    @MainActor
    public func immediateResult(for diff: FileDiffMetadata, options: RenderDiffOptions, lineLimit: Int) -> ThemedDiffResult? {
        if let cached = cachedResult(for: diff, options: options) { return cached }
        guard max(diff.additionLines.count, diff.deletionLines.count) <= lineLimit,
              let result = try? Self.mainHighlighter.renderDiff(diff, options: options)
        else { return nil }
        if let key = diff.cacheKey { state.withLock { $0.cache.set(.diff(key, options), .diff(result)) } }
        return result
    }

    @MainActor
    public func immediateResult(for file: FileContents, lineCount: Int, options: RenderFileOptions, lineLimit: Int) -> ThemedFileResult? {
        if let cached = cachedResult(for: file, options: options) { return cached }
        guard lineCount <= lineLimit, let result = try? Self.mainHighlighter.renderFile(file, options: options) else { return nil }
        if let key = file.cacheKey { state.withLock { $0.cache.set(.file(key, options), .file(result)) } }
        return result
    }

    @MainActor private static let mainHighlighter = DiffsHighlighter()
}
