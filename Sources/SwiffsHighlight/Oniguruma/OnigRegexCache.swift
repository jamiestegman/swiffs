// Process-wide cache of compiled Oniguruma patterns.
//
// Every highlighter (main thread, workers, side highlighters) compiles the
// same grammar patterns. Oniguruma only reads a compiled regex while
// searching — match state lives on the stack and results go to the caller's
// region — so one compiled regex can serve concurrent searches, and each
// pattern compiles once per process instead of once per highlighter.

import COniguruma
import Foundation

/// A compiled pattern shared by scanners on any thread.
final class CompiledOnigRegex: @unchecked Sendable {
    let regex: OnigRegex
    /// Whether the pattern contains `\G`; such patterns cannot reuse cached
    /// search results.
    let hasGAnchor: Bool

    fileprivate init(regex: OnigRegex, hasGAnchor: Bool) {
        self.regex = regex
        self.hasGAnchor = hasGAnchor
    }

    deinit {
        onig_free(regex)
    }
}

final class OnigRegexCache: @unchecked Sendable {
    static let shared = OnigRegexCache(capacity: 8192)

    private struct Entry {
        var regex: CompiledOnigRegex
        var lastUse: UInt64
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    var count: Int { lock.withLock { entries.count } }

    /// The compiled regex for a pattern, compiling it on first use. Evicted
    /// entries stay alive while scanners reference them.
    func regex(for pattern: String) throws -> CompiledOnigRegex {
        if let hit = lookup(pattern) { return hit }
        // Compile outside the lock; if another thread won the race, use its
        // result.
        let compiled = try Self.compile(pattern)
        return lock.withLock {
            clock &+= 1
            if let existing = entries[pattern] {
                entries[pattern]?.lastUse = clock
                return existing.regex
            }
            entries[pattern] = Entry(regex: compiled, lastUse: clock)
            if entries.count > capacity { evictLeastRecentlyUsed() }
            return compiled
        }
    }

    func removeAll() {
        lock.withLock { entries.removeAll() }
    }

    private func lookup(_ pattern: String) -> CompiledOnigRegex? {
        lock.withLock {
            guard let entry = entries[pattern] else { return nil }
            clock &+= 1
            entries[pattern]?.lastUse = clock
            return entry.regex
        }
    }

    /// Drops the older half, so eviction cost amortizes across insertions.
    private func evictLeastRecentlyUsed() {
        let cutoff = entries.values.map(\.lastUse).sorted()[entries.count / 2]
        entries = entries.filter { $0.value.lastUse >= cutoff }
    }

    private static func compile(_ pattern: String) throws -> CompiledOnigRegex {
        onigInitialize()
        var regex: OnigRegex?
        var errorInfo = OnigErrorInfo()
        var source = pattern
        let status = source.withUTF8 { compileBytes($0, &regex, &errorInfo) }
        guard status == ONIG_NORMAL, let regex else {
            var message = [UInt8](repeating: 0, count: Int(ONIG_MAX_ERROR_MESSAGE_LEN))
            _ = withUnsafeMutablePointer(to: &errorInfo) { info in
                message.withUnsafeMutableBufferPointer { buffer in
                    swiffs_onig_error_code_to_str(buffer.baseAddress!, status, info)
                }
            }
            throw OnigError(message: String(decoding: message.prefix { $0 != 0 }, as: UTF8.self), pattern: pattern)
        }
        return CompiledOnigRegex(regex: regex, hasGAnchor: pattern.utf8.containsGAnchor)
    }

    private static func compileBytes(_ buffer: UnsafeBufferPointer<UInt8>, _ regex: inout OnigRegex?, _ errorInfo: inout OnigErrorInfo) -> Int32 {
        // Oniguruma needs a valid pointer even for an empty pattern.
        let base = buffer.baseAddress ?? UnsafePointer<UInt8>(bitPattern: 1)!
        return onig_new(
            &regex,
            base,
            base + buffer.count,
            OnigOptionType(ONIG_OPTION_CAPTURE_GROUP),
            swiffs_onig_encoding_utf8(),
            swiffs_onig_syntax_default(),
            &errorInfo
        )
    }
}

private extension String.UTF8View {
    /// Whether the pattern contains `\G` (vscode-oniguruma's check: any
    /// backslash followed by `G`).
    var containsGAnchor: Bool {
        var previous: UInt8 = 0
        for byte in self {
            if previous == UInt8(ascii: "\\"), byte == UInt8(ascii: "G") { return true }
            previous = byte
        }
        return false
    }
}
