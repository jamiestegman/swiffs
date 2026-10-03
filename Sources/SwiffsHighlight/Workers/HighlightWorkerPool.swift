// Native equivalent of `WorkerPoolManager`: highlights diffs and files off
// the main thread on a pool of highlighter instances, with an LRU cache keyed
// by `cacheKey`.

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
}

public struct HighlightWorkerStats: Hashable, Sendable {
    public var workers: Int
    public var pendingTasks: Int
    public var cachedDiffs: Int
    public var cachedFiles: Int
}

/// Highlights on background threads. Each worker owns one
/// `DiffsHighlighter` confined to its serial queue.
public final class HighlightWorkerPool: Sendable {
    public static let shared = HighlightWorkerPool()

    public typealias Completion<Value> = @Sendable (Result<Value, Error>) -> Void

    /// Unchecked because its highlighters are only used on its serial queue.
    private final class Worker: @unchecked Sendable {
        let queue: DispatchQueue
        let highlighter: DiffsHighlighter

        init(index: Int, registry: HighlighterRegistry) {
            queue = DispatchQueue(label: "swiffs.highlight.worker.\(index)", qos: .userInitiated)
            highlighter = DiffsHighlighter(registry: registry)
            // Owned by this worker, so large diffs tokenize both sides at once
            // without borrowing another worker.
            highlighter.sideHighlighter = DiffsHighlighter(registry: registry)
        }
    }

    private struct DiffCacheKey: Hashable {
        var cacheKey: String
        var options: RenderDiffOptions
    }

    private struct FileCacheKey: Hashable {
        var cacheKey: String
        var options: RenderFileOptions
    }

    /// What a keyed request does: use the cache, wait for a worker already
    /// computing the result, or start that work.
    private enum Request<Value> {
        case cached(Value)
        case waiting
        case start
    }

    private struct State {
        /// Tasks queued or running on each worker, by worker index.
        var pending: [Int]
        var diffCache: LRUCache<DiffCacheKey, ThemedDiffResult>
        var fileCache: LRUCache<FileCacheKey, ThemedFileResult>
        /// Callers waiting on a keyed result that a worker is computing, so a
        /// second request for it waits instead of computing it again.
        var diffWaiters: [DiffCacheKey: [Completion<ThemedDiffResult>]] = [:]
        var fileWaiters: [FileCacheKey: [Completion<ThemedFileResult>]] = [:]
    }

    private let workers: [Worker]
    private let state: Mutex<State>

    public init(workerCount: Int = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 1)), cacheCapacity: Int = 100, registry: HighlighterRegistry = .shared) {
        workers = (0 ..< max(1, workerCount)).map { Worker(index: $0, registry: registry) }
        state = Mutex(State(pending: Array(repeating: 0, count: workers.count), diffCache: LRUCache(capacity: cacheCapacity), fileCache: LRUCache(capacity: cacheCapacity)))
    }

    private func nextWorker() -> Int {
        state.withLock { state in
            let index = state.pending.indices.min { state.pending[$0] < state.pending[$1] }!
            state.pending[index] += 1
            return index
        }
    }

    private func finish(_ index: Int) {
        state.withLock { $0.pending[index] -= 1 }
    }

    public var stats: HighlightWorkerStats {
        state.withLock { state in
            HighlightWorkerStats(workers: workers.count, pendingTasks: state.pending.reduce(0, +), cachedDiffs: 0, cachedFiles: 0)
        }
    }

    /// Returns a cached result for a keyed diff, if any.
    public func cachedDiffResult(_ diff: FileDiffMetadata, options: RenderDiffOptions) -> ThemedDiffResult? {
        guard let cacheKey = diff.cacheKey else { return nil }
        return state.withLock { $0.diffCache.get(DiffCacheKey(cacheKey: cacheKey, options: options)) }
    }

    /// A result available now: the cached one, or, for content of at most
    /// `synchronousLineLimit` lines, one highlighted on the main thread and
    /// cached. Nil means the request should go to `highlightDiff`.
    @MainActor
    public func immediateResult(for request: DiffHighlightRequest, synchronousLineLimit: Int) -> ThemedDiffResult? {
        guard !request.forcePlainText else { return nil }
        if let cached = cachedDiffResult(request.diff, options: request.options) { return cached }
        guard request.lineCount <= synchronousLineLimit, let result = try? Self.mainThreadHighlighter.renderDiff(request.diff, options: request.options) else { return nil }
        if let cacheKey = request.diff.cacheKey {
            state.withLock { $0.diffCache.set(DiffCacheKey(cacheKey: cacheKey, options: request.options), result) }
        }
        return result
    }

    /// A file's counterpart of `immediateResult(for:synchronousLineLimit:)`.
    @MainActor
    public func immediateResult(for request: FileHighlightRequest, synchronousLineLimit: Int) -> ThemedFileResult? {
        guard !request.forcePlainText else { return nil }
        if let cached = cachedFileResult(request.file, options: request.options) { return cached }
        guard request.lineCount <= synchronousLineLimit, let result = try? Self.mainThreadHighlighter.renderFile(request.file, options: request.options) else { return nil }
        if let cacheKey = request.file.cacheKey {
            state.withLock { $0.fileCache.set(FileCacheKey(cacheKey: cacheKey, options: request.options), result) }
        }
        return result
    }

    /// Highlights small content synchronously on the main thread.
    @MainActor private static let mainThreadHighlighter = DiffsHighlighter()

    public func cachedFileResult(_ file: FileContents, options: RenderFileOptions) -> ThemedFileResult? {
        guard let cacheKey = file.cacheKey else { return nil }
        return state.withLock { $0.fileCache.get(FileCacheKey(cacheKey: cacheKey, options: options)) }
    }

    /// Highlights a diff on a worker; `completion` runs on the main queue.
    public func highlightDiff(
        _ diff: FileDiffMetadata,
        options: RenderDiffOptions,
        forcePlainText: Bool = false,
        completion: @escaping Completion<ThemedDiffResult>
    ) {
        let key = forcePlainText ? nil : diff.cacheKey.map { DiffCacheKey(cacheKey: $0, options: options) }
        if let key {
            let request: Request<ThemedDiffResult> = state.withLock { state in
                if let hit = state.diffCache.get(key) { return .cached(hit) }
                let running = state.diffWaiters[key] != nil
                state.diffWaiters[key, default: []].append(completion)
                return running ? .waiting : .start
            }
            switch request {
            case .cached(let hit):
                DispatchQueue.main.async { completion(.success(hit)) }
                return
            case .waiting:
                return
            case .start:
                break
            }
        }
        let index = nextWorker()
        let worker = workers[index]
        worker.queue.async { [self] in
            let result = Result {
                try worker.highlighter.renderDiff(
                    diff,
                    options: options,
                    plainText: ForceDiffPlainTextOptions(forcePlainText: forcePlainText, expandedHunks: forcePlainText ? .all : nil)
                )
            }
            let waiters: [Completion<ThemedDiffResult>] = state.withLock { state in
                guard let key else { return [completion] }
                if case .success(let value) = result { state.diffCache.set(key, value) }
                return state.diffWaiters.removeValue(forKey: key) ?? []
            }
            finish(index)
            DispatchQueue.main.async { for waiter in waiters { waiter(result) } }
        }
    }

    /// Highlights a file on a worker; `completion` runs on the main queue.
    public func highlightFile(
        _ file: FileContents,
        options: RenderFileOptions,
        forcePlainText: Bool = false,
        completion: @escaping Completion<ThemedFileResult>
    ) {
        let key = forcePlainText ? nil : file.cacheKey.map { FileCacheKey(cacheKey: $0, options: options) }
        if let key {
            let request: Request<ThemedFileResult> = state.withLock { state in
                if let hit = state.fileCache.get(key) { return .cached(hit) }
                let running = state.fileWaiters[key] != nil
                state.fileWaiters[key, default: []].append(completion)
                return running ? .waiting : .start
            }
            switch request {
            case .cached(let hit):
                DispatchQueue.main.async { completion(.success(hit)) }
                return
            case .waiting:
                return
            case .start:
                break
            }
        }
        let index = nextWorker()
        let worker = workers[index]
        worker.queue.async { [self] in
            let result = Result { try worker.highlighter.renderFile(file, options: options, forcePlainText: forcePlainText) }
            let waiters: [Completion<ThemedFileResult>] = state.withLock { state in
                guard let key else { return [completion] }
                if case .success(let value) = result { state.fileCache.set(key, value) }
                return state.fileWaiters.removeValue(forKey: key) ?? []
            }
            finish(index)
            DispatchQueue.main.async { for waiter in waiters { waiter(result) } }
        }
    }

    public func highlightDiff(_ diff: FileDiffMetadata, options: RenderDiffOptions, forcePlainText: Bool = false) async throws -> ThemedDiffResult {
        try await withCheckedThrowingContinuation { continuation in
            highlightDiff(diff, options: options, forcePlainText: forcePlainText) { continuation.resume(with: $0) }
        }
    }

    public func highlightFile(_ file: FileContents, options: RenderFileOptions, forcePlainText: Bool = false) async throws -> ThemedFileResult {
        try await withCheckedThrowingContinuation { continuation in
            highlightFile(file, options: options, forcePlainText: forcePlainText) { continuation.resume(with: $0) }
        }
    }

    /// Clears cached results (e.g. after registering new themes).
    public func clearCache() {
        state.withLock { state in
            state.diffCache.removeAll()
            state.fileCache.removeAll()
        }
    }
}
