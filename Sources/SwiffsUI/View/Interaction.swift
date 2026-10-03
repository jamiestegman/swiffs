import AppKit
import SwiffsCore

/// A caret position in one column of an item: a row showing a line and a
/// UTF-16 offset into it.
struct TextPosition: Comparable, Hashable {
    var row: Int
    var offset: Int

    static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        lhs.row != rhs.row ? lhs.row < rhs.row : lhs.offset < rhs.offset
    }
}

/// Selected text within one column of one item.
struct TextSelection: Equatable {
    var itemID: String
    var column: Int
    var anchor: TextPosition
    var focus: TextPosition

    var start: TextPosition { min(anchor, focus) }
    var end: TextPosition { max(anchor, focus) }
    var isEmpty: Bool { anchor == focus }
}

enum TextGranularity {
    case character, word, line
}

/// What lies under a point in the document.
enum Hit: Equatable {
    case line(item: Int, row: Int, column: Int, line: RenderedLine, inNumbers: Bool)
    case control(item: Int, Control)
    case annotation(item: Int, row: Int, column: Int)
    case header(item: Int)
    case none
}

/// The pointer's current gesture.
enum PointerSession {
    case idle
    /// Dragging over line numbers selects lines.
    case selectingLines(itemID: String, anchor: SelectionPoint)
    /// A press on a selected single line, which a release without a drag
    /// unselects.
    case pressingSelectedLine(itemID: String, anchor: SelectionPoint)
    /// Dragging from the gutter action button selects the lines it acts on.
    case gutterAction(itemID: String, anchor: SelectionPoint, current: SelectionPoint)
    case selectingText(itemID: String, column: Int, lower: TextPosition, upper: TextPosition, granularity: TextGranularity, moved: Bool)
    /// A press on a control, which acts on release.
    case pressingControl(Control)
}

/// Word boundaries as a double-click finds them: runs of word characters,
/// whitespace or other punctuation.
func wordRange(in units: [UInt16], at offset: Int) -> Range<Int> {
    guard !units.isEmpty else { return 0 ..< 0 }
    var classes: [(start: Int, end: Int, kind: Int)] = []
    var position = 0
    for scalar in String(decoding: units, as: UTF16.self).unicodeScalars {
        let length = scalar.utf16.count
        let kind: Int
        if scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_" || scalar.properties.isIdeographic {
            kind = 0
        } else if scalar.properties.isWhitespace {
            kind = 1
        } else {
            kind = 2
        }
        classes.append((position, position + length, kind))
        position += length
    }
    // Prefer the character after the caret, else the one before it.
    var index = classes.firstIndex { offset >= $0.start && offset < $0.end } ?? (classes.count - 1)
    if offset >= position { index = classes.count - 1 }
    let kind = classes[index].kind
    var lower = index
    while lower > 0, classes[lower - 1].kind == kind { lower -= 1 }
    var upper = index
    while upper + 1 < classes.count, classes[upper + 1].kind == kind { upper += 1 }
    return classes[lower].start ..< classes[upper].end
}
