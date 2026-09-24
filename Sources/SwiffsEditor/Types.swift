// Port of `editor/types.ts`: positions, ranges, edits and selections. All
// offsets are UTF-16 code units, matching JavaScript strings.

import Foundation
import SwiffsCore

/// A zero-based line and UTF-16 character offset (`Position`).
public struct Position: Hashable, Sendable, Codable, Comparable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    public static func < (lhs: Position, rhs: Position) -> Bool {
        lhs.line != rhs.line ? lhs.line < rhs.line : lhs.character < rhs.character
    }
}

/// A range between two positions (`Range`).
public struct DocumentRange: Hashable, Sendable, Codable {
    public var start: Position
    public var end: Position

    public init(start: Position, end: Position) {
        self.start = start
        self.end = end
    }
}

/// An edit addressed by positions (`TextEdit`).
public struct TextEdit: Hashable, Sendable, Codable {
    public var range: DocumentRange
    public var newText: String

    public init(range: DocumentRange, newText: String) {
        self.range = range
        self.newText = newText
    }
}

/// An edit addressed by UTF-16 offsets (`ResolvedTextEdit`).
public struct ResolvedTextEdit: Hashable, Sendable, Codable {
    public var start: Int
    public var end: Int
    public var text: String

    public init(start: Int, end: Int, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    /// UTF-16 length of the inserted text.
    public var textLength: Int { text.utf16.count }
}

/// A normalized change reported by the editor (`EditorChange`).
public struct EditorChange: Hashable, Sendable, Codable {
    public var start: Int
    public var end: Int
    public var text: String
    /// The replaced range before the change.
    public var range: DocumentRange

    public init(start: Int, end: Int, text: String, range: DocumentRange) {
        self.start = start
        self.end = end
        self.text = text
        self.range = range
    }
}

/// Selection direction: -1 backward, 0 none, 1 forward.
public enum SelectionDirection: Int, Hashable, Sendable, Codable {
    case backward = -1
    case none = 0
    case forward = 1
}

/// A selection (`EditorSelection`): a range plus the side the caret is on.
public struct EditorSelection: Hashable, Sendable, Codable {
    public var start: Position
    public var end: Position
    public var direction: SelectionDirection

    public init(start: Position, end: Position, direction: SelectionDirection = .none) {
        self.start = start
        self.end = end
        self.direction = direction
    }

    public init(caret: Position) {
        self.init(start: caret, end: caret, direction: .none)
    }

    public var range: DocumentRange { DocumentRange(start: start, end: end) }
    public var isCollapsed: Bool { start == end }
    /// The caret (focus) position.
    public var focus: Position { direction == .backward ? start : end }
    /// The anchor position.
    public var anchor: Position { direction == .backward ? end : start }
}

/// Undo coalescing groups (`EditHistoryCoalescingMode`).
public enum EditHistoryCoalescingMode: String, Hashable, Sendable, Codable {
    case insert, backspace, delete
}

/// Search options (`SearchParams`).
public struct SearchParams: Hashable, Sendable, Codable {
    public var text: String
    public var replaceText: String
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var regex: Bool

    public init(text: String, replaceText: String = "", caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.text = text
        self.replaceText = replaceText
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }
}

/// Document line ending.
public enum EndOfLine: String, Hashable, Sendable, Codable {
    case lf = "\n"
    case crlf = "\r\n"
    case cr = "\r"
}

/// UTF-16 helpers shared by the editor model.
enum UTF16Text {
    static func units(_ string: String) -> [UInt16] { Array(string.utf16) }

    static func string<C: Collection>(_ units: C) -> String where C.Element == UInt16 {
        String(decoding: units, as: UTF16.self)
    }

    static func isEOL(_ unit: UInt16) -> Bool { unit == 0x0A || unit == 0x0D }
    static func isHighSurrogate(_ unit: UInt16) -> Bool { unit >= 0xD800 && unit <= 0xDBFF }
    static func isLowSurrogate(_ unit: UInt16) -> Bool { unit >= 0xDC00 && unit <= 0xDFFF }
}

@inline(__always)
func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
    min(max(value, lower), upper)
}
