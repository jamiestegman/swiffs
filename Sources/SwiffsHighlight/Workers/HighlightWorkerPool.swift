// Native equivalent of `WorkerPoolManager`: highlights diffs and files off
// the main thread on a pool of highlighter instances, with an LRU cache keyed
// by `cacheKey`.

import Foundation
import SwiffsCore

/// A small LRU map (the `lru_map` dependency upstream).
final class LRUCache<Key: Hashable, Value> {
    private var values: [Key: Value] = [:]
    private var order: [Key] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func get(_ key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return value
    }

    func set(_ key: Key, _ value: Value) {
        if values[key] != nil, let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        values[key] = value
        order.append(key)
        while order.count > capacity {
            values.removeValue(forKey: order.removeFirst())
        }
    }

    func removeAll() {
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
public final class HighlightWorkerPool: @unchecked Sendable {
    public static let shared = HighlightWorkerPool()

    private final class Worker: @unchecked Sendable {
        let queue: DispatchQueue
        let highlighter: DiffsHighlighter
        var pending = 0

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

    private let workers: [Worker]
    private let lock = NSLock()
    private let diffCache: LRUCache<DiffCacheKey, ThemedDiffResult>
    private let fileCache: LRUCache<FileCacheKey, ThemedFileResult>

    public init(workerCount: Int = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 1)), cacheCapacity: Int = 100, registry: HighlighterRegistry = .shared) {
        workers = (0 ..< max(1, workerCount)).map { Worker(index: $0, registry: registry) }
        diffCache = LRUCache(capacity: cacheCapacity)
        fileCache = LRUCache(capacity: cacheCapacity)
    }

    private func nextWorker() -> Worker {
        lock.withLock {
            let worker = workers.min { $0.pending < $1.pending }!
            worker.pending += 1
            return worker
        }
    }

    private func finish(_ worker: Worker) {
        lock.withLock { worker.pending -= 1 }
    }

    public var stats: HighlightWorkerStats {
        lock.withLock {
            HighlightWorkerStats(
                workers: workers.count,
                pendingTasks: workers.reduce(0) { $0 + $1.pending },
                cachedDiffs: 0,
                cachedFiles: 0
            )
        }
    }

    /// Returns a cached result for a keyed diff, if any.
    public func cachedDiffResult(_ diff: FileDiffMetadata, options: RenderDiffOptions) -> ThemedDiffResult? {
        guard let cacheKey = diff.cacheKey else { return nil }
        return lock.withLock { diffCache.get(DiffCacheKey(cacheKey: cacheKey, options: options)) }
    }

    public func cachedFileResult(_ file: FileContents, options: RenderFileOptions) -> ThemedFileResult? {
        guard let cacheKey = file.cacheKey else { return nil }
        return lock.withLock { fileCache.get(FileCacheKey(cacheKey: cacheKey, options: options)) }
    }

    /// Highlights a diff on a worker; `completion` runs on the main queue.
    public func highlightDiff(
        _ diff: FileDiffMetadata,
        options: RenderDiffOptions,
        forcePlainText: Bool = false,
        completion: @escaping @Sendable (Result<ThemedDiffResult, Error>) -> Void
    ) {
        if !forcePlainText, let cached = cachedDiffResult(diff, options: options) {
            DispatchQueue.main.async { completion(.success(cached)) }
            return
        }
        let worker = nextWorker()
        worker.queue.async { [self] in
            let result = Result {
                try worker.highlighter.renderDiff(
                    diff,
                    options: options,
                    plainText: ForceDiffPlainTextOptions(forcePlainText: forcePlainText, expandedHunks: forcePlainText ? .all : nil)
                )
            }
            if case .success(let value) = result, !forcePlainText, let cacheKey = diff.cacheKey {
                lock.withLock { diffCache.set(DiffCacheKey(cacheKey: cacheKey, options: options), value) }
            }
            finish(worker)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Highlights a file on a worker; `completion` runs on the main queue.
    public func highlightFile(
        _ file: FileContents,
        options: RenderFileOptions,
        forcePlainText: Bool = false,
        completion: @escaping @Sendable (Result<ThemedFileResult, Error>) -> Void
    ) {
        if !forcePlainText, let cached = cachedFileResult(file, options: options) {
            DispatchQueue.main.async { completion(.success(cached)) }
            return
        }
        let worker = nextWorker()
        worker.queue.async { [self] in
            let result = Result { try worker.highlighter.renderFile(file, options: options, forcePlainText: forcePlainText) }
            if case .success(let value) = result, !forcePlainText, let cacheKey = file.cacheKey {
                lock.withLock { fileCache.set(FileCacheKey(cacheKey: cacheKey, options: options), value) }
            }
            finish(worker)
            DispatchQueue.main.async { completion(result) }
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
        lock.withLock {
            diffCache.removeAll()
            fileCache.removeAll()
        }
    }
}
