// Port of jsdiff (https://github.com/kpdecker/jsdiff) v9 `diff/base.js`.
//
// The algorithm is Myers' O(ND) diff with jsdiff's edge-of-graph pruning. It
// is ported step for step so results (including tie breaking between equally
// short edit scripts) match the JavaScript implementation exactly.
//
// Tokens are interned into integer ids before running the algorithm. Equality
// between tokens is exact code-unit equality (like JavaScript `===`), not
// Swift's canonical-equivalence `String ==`.

import Foundation

/// A change object produced by the diff functions. Mirrors jsdiff's
/// `ChangeObject<string>`.
public struct ChangeObject: Hashable, Sendable {
    public var value: String
    public var added: Bool
    public var removed: Bool
    public var count: Int

    public init(value: String, added: Bool, removed: Bool, count: Int) {
        self.value = value
        self.added = added
        self.removed = removed
        self.count = count
    }
}

/// Options shared by the diff functions (subset of jsdiff's options that are
/// meaningful for the ported functions).
public struct DiffOptions: Hashable, Sendable {
    public var ignoreCase: Bool
    public var ignoreWhitespace: Bool
    public var ignoreNewlineAtEof: Bool
    public var stripTrailingCr: Bool
    public var newlineIsToken: Bool
    public var oneChangePerToken: Bool
    public var maxEditLength: Int?
    /// Maximum execution time in milliseconds.
    public var timeout: Double?

    public init(
        ignoreCase: Bool = false,
        ignoreWhitespace: Bool = false,
        ignoreNewlineAtEof: Bool = false,
        stripTrailingCr: Bool = false,
        newlineIsToken: Bool = false,
        oneChangePerToken: Bool = false,
        maxEditLength: Int? = nil,
        timeout: Double? = nil
    ) {
        self.ignoreCase = ignoreCase
        self.ignoreWhitespace = ignoreWhitespace
        self.ignoreNewlineAtEof = ignoreNewlineAtEof
        self.stripTrailingCr = stripTrailingCr
        self.newlineIsToken = newlineIsToken
        self.oneChangePerToken = oneChangePerToken
        self.maxEditLength = maxEditLength
        self.timeout = timeout
    }
}

/// A string wrapper whose equality and hashing use exact UTF-8 bytes, matching
/// JavaScript's `===` rather than Swift's Unicode canonical equivalence.
struct ExactStringKey: Hashable {
    let value: String

    static func == (lhs: ExactStringKey, rhs: ExactStringKey) -> Bool {
        lhs.value.utf8.elementsEqual(rhs.value.utf8)
    }

    func hash(into hasher: inout Hasher) {
        var copy = value
        copy.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}

/// A component in the edit script: `count` tokens that were added, removed or
/// kept.
struct DiffComponent {
    var count: Int
    var added: Bool
    var removed: Bool
}

/// The Myers diff engine, operating on interned token ids.
enum MyersDiff {
    private struct Node {
        var count: Int
        var added: Bool
        var removed: Bool
        var previous: Int32
    }

    private struct Path {
        var oldPos: Int
        var lastComponent: Int32
    }

    /// Returns the edit script, or nil when `maxEditLength` / `timeout` was
    /// exceeded.
    static func diff(
        old oldTokens: [Int],
        new newTokens: [Int],
        oneChangePerToken: Bool = false,
        maxEditLength requestedMaxEditLength: Int? = nil,
        timeout: Double? = nil
    ) -> [DiffComponent]? {
        let newLen = newTokens.count
        let oldLen = oldTokens.count
        var nodes: [Node] = []
        nodes.reserveCapacity(64)

        func append(_ node: Node) -> Int32 {
            nodes.append(node)
            return Int32(nodes.count - 1)
        }

        func addToPath(_ path: Path, added: Bool, removed: Bool, oldPosInc: Int) -> Path {
            let lastIndex = path.lastComponent
            if lastIndex >= 0, !oneChangePerToken {
                let last = nodes[Int(lastIndex)]
                if last.added == added, last.removed == removed {
                    let node = append(Node(count: last.count + 1, added: added, removed: removed, previous: last.previous))
                    return Path(oldPos: path.oldPos + oldPosInc, lastComponent: node)
                }
            }
            let node = append(Node(count: 1, added: added, removed: removed, previous: lastIndex))
            return Path(oldPos: path.oldPos + oldPosInc, lastComponent: node)
        }

        func extractCommon(_ basePath: inout Path, diagonalPath: Int) -> Int {
            var oldPos = basePath.oldPos
            var newPos = oldPos - diagonalPath
            var commonCount = 0
            while newPos + 1 < newLen, oldPos + 1 < oldLen, oldTokens[oldPos + 1] == newTokens[newPos + 1] {
                newPos += 1
                oldPos += 1
                commonCount += 1
                if oneChangePerToken {
                    basePath.lastComponent = append(Node(count: 1, added: false, removed: false, previous: basePath.lastComponent))
                }
            }
            if commonCount > 0, !oneChangePerToken {
                basePath.lastComponent = append(Node(count: commonCount, added: false, removed: false, previous: basePath.lastComponent))
            }
            basePath.oldPos = oldPos
            return newPos
        }

        func buildValues(_ last: Int32) -> [DiffComponent] {
            var components: [DiffComponent] = []
            var index = last
            while index >= 0 {
                let node = nodes[Int(index)]
                components.append(DiffComponent(count: node.count, added: node.added, removed: node.removed))
                index = node.previous
            }
            components.reverse()
            return components
        }

        var maxEditLength = newLen + oldLen
        if let requestedMaxEditLength {
            maxEditLength = min(maxEditLength, requestedMaxEditLength)
        }
        let abortAfter: Double = timeout.map { Date().timeIntervalSince1970 * 1000 + $0 } ?? .infinity

        // bestPath is indexed by diagonal in [-(maxEditLength+1), maxEditLength+1].
        let offset = maxEditLength + 1
        var bestPath = [Path?](repeating: nil, count: 2 * offset + 1)
        var seed = Path(oldPos: -1, lastComponent: -1)
        var newPos = extractCommon(&seed, diagonalPath: 0)
        bestPath[offset] = seed
        if seed.oldPos + 1 >= oldLen, newPos + 1 >= newLen {
            return buildValues(seed.lastComponent)
        }

        var minDiagonalToConsider = Int.min
        var maxDiagonalToConsider = Int.max
        var editLength = 1

        var checkCounter = 0
        while editLength <= maxEditLength {
            if abortAfter.isFinite {
                checkCounter &+= 1
                if checkCounter & 0x3F == 0, Date().timeIntervalSince1970 * 1000 > abortAfter {
                    return nil
                }
            }
            var diagonalPath = max(minDiagonalToConsider, -editLength)
            let upper = min(maxDiagonalToConsider, editLength)
            while diagonalPath <= upper {
                defer { diagonalPath += 2 }
                let removeIndex = diagonalPath - 1 + offset
                let addIndex = diagonalPath + 1 + offset
                let removePath = removeIndex >= 0 ? bestPath[removeIndex] : nil
                let addPath = addIndex < bestPath.count ? bestPath[addIndex] : nil
                if removePath != nil {
                    // No one else is going to attempt to use this value, clear it
                    bestPath[removeIndex] = nil
                }
                var canAdd = false
                if let addPath {
                    let addPathNewPos = addPath.oldPos - diagonalPath
                    canAdd = 0 <= addPathNewPos && addPathNewPos < newLen
                }
                let canRemove = removePath.map { $0.oldPos + 1 < oldLen } ?? false
                if !canAdd && !canRemove {
                    // If this path is a terminal then prune
                    bestPath[diagonalPath + offset] = nil
                    continue
                }

                var basePath: Path
                if !canRemove || (canAdd && removePath!.oldPos < addPath!.oldPos) {
                    basePath = addToPath(addPath!, added: true, removed: false, oldPosInc: 0)
                } else {
                    basePath = addToPath(removePath!, added: false, removed: true, oldPosInc: 1)
                }
                newPos = extractCommon(&basePath, diagonalPath: diagonalPath)
                if basePath.oldPos + 1 >= oldLen, newPos + 1 >= newLen {
                    return buildValues(basePath.lastComponent)
                }
                bestPath[diagonalPath + offset] = basePath
                if basePath.oldPos + 1 >= oldLen {
                    maxDiagonalToConsider = min(maxDiagonalToConsider, diagonalPath - 1)
                }
                if newPos + 1 >= newLen {
                    minDiagonalToConsider = max(minDiagonalToConsider, diagonalPath + 1)
                }
            }
            editLength += 1
        }
        return nil
    }
}

/// Tokenizer + equality behaviour for a jsdiff `Diff` subclass.
protocol TokenDiff {
    func tokenize(_ value: String, options: DiffOptions) -> [String]
    /// The key used for equality comparisons (tokens with equal keys are
    /// considered equal).
    func equalityKey(_ token: String, options: DiffOptions) -> String
    func join(_ tokens: ArraySlice<String>) -> String
    func postProcess(_ changes: [ChangeObject], options: DiffOptions) -> [ChangeObject]
}

extension TokenDiff {
    func equalityKey(_ token: String, options: DiffOptions) -> String {
        options.ignoreCase ? token.lowercased() : token
    }

    func join(_ tokens: ArraySlice<String>) -> String {
        tokens.joined()
    }

    func postProcess(_ changes: [ChangeObject], options: DiffOptions) -> [ChangeObject] {
        changes
    }

    func diff(_ oldString: String, _ newString: String, options: DiffOptions = DiffOptions()) -> [ChangeObject]? {
        let oldTokens = tokenize(oldString, options: options).filter { !$0.isEmpty }
        let newTokens = tokenize(newString, options: options).filter { !$0.isEmpty }
        return diffTokens(oldTokens, newTokens, options: options)
    }

    func diffTokens(_ oldTokens: [String], _ newTokens: [String], options: DiffOptions) -> [ChangeObject]? {
        var ids: [ExactStringKey: Int] = [:]
        ids.reserveCapacity(oldTokens.count + newTokens.count)
        func intern(_ token: String) -> Int {
            let key = ExactStringKey(value: equalityKey(token, options: options))
            if let id = ids[key] { return id }
            let id = ids.count
            ids[key] = id
            return id
        }
        let oldIds = oldTokens.map(intern)
        let newIds = newTokens.map(intern)
        guard let components = MyersDiff.diff(
            old: oldIds,
            new: newIds,
            oneChangePerToken: options.oneChangePerToken,
            maxEditLength: options.maxEditLength,
            timeout: options.timeout
        ) else {
            return nil
        }
        var changes: [ChangeObject] = []
        changes.reserveCapacity(components.count)
        var newPos = 0
        var oldPos = 0
        for component in components {
            if !component.removed {
                let value = join(newTokens[newPos ..< newPos + component.count])
                newPos += component.count
                if !component.added {
                    oldPos += component.count
                }
                changes.append(ChangeObject(value: value, added: component.added, removed: false, count: component.count))
            } else {
                let value = join(oldTokens[oldPos ..< oldPos + component.count])
                oldPos += component.count
                changes.append(ChangeObject(value: value, added: false, removed: true, count: component.count))
            }
        }
        return postProcess(changes, options: options)
    }
}

// MARK: - JavaScript string helpers

enum JSString {
    /// JavaScript's `\s` character class.
    @inline(__always)
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09 ... 0x0D, 0x20, 0xA0, 0x1680, 0x2000 ... 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// `String.prototype.trim`.
    static func trim(_ value: String) -> String {
        let scalars = value.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }) else { return "" }
        let last = scalars.lastIndex(where: { !isWhitespace($0) })!
        return String(scalars[first ... last])
    }

    /// `String.prototype.trimEnd`.
    static func trimEnd(_ value: String) -> String {
        let scalars = value.unicodeScalars
        guard let last = scalars.lastIndex(where: { !isWhitespace($0) }) else { return "" }
        return String(scalars[...last])
    }

    /// `String.prototype.trimStart`.
    static func trimStart(_ value: String) -> String {
        let scalars = value.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }) else { return "" }
        return String(scalars[first...])
    }

    /// Length in UTF-16 code units (JavaScript `String.length`).
    @inline(__always)
    static func length(_ value: String) -> Int {
        value.utf16.count
    }

    @inline(__always)
    static func length(_ value: Substring) -> Int {
        value.utf16.count
    }
}
