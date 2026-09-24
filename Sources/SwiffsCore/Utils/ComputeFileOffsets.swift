// Port of `computeFileOffsets.ts`.

import Foundation

/// UTF-16 offsets of line starts; `\n`, `\r` and `\r\n` each end a line
/// (`computeLineOffsets`).
public func computeLineOffsets(_ contents: String) -> [Int] {
    computeLineOffsets(utf16: Array(contents.utf16))
}

public func computeLineOffsets<C: Collection>(utf16 units: C) -> [Int] where C.Element == UInt16, C.Index == Int {
    var offsets = [0]
    var i = units.startIndex
    while i < units.endIndex {
        let unit = units[i]
        if unit == 0x0A || unit == 0x0D {
            if unit == 0x0D, i + 1 < units.endIndex, units[i + 1] == 0x0A {
                i += 1
            }
            offsets.append(i + 1 - units.startIndex)
        }
        i += 1
    }
    return offsets
}

/// Line breaks in a string, counting `\r\n` once (`countLineBreaks`).
public func countLineBreaks(_ contents: String) -> Int {
    var count = 0
    var previousWasCR = false
    for unit in contents.utf16 {
        if unit == 0x0A {
            if !previousWasCR { count += 1 }
            previousWasCR = false
        } else if unit == 0x0D {
            count += 1
            previousWasCR = true
        } else {
            previousWasCR = false
        }
    }
    return count
}

/// Splits contents into lines aligned with `computeLineOffsets`, keeping
/// line endings; a trailing newline produces a final empty line
/// (`linesFromFileContents`).
public func linesFromFileContents(_ contents: String) -> [String] {
    let units = Array(contents.utf16)
    let offsets = computeLineOffsets(utf16: units)
    return offsets.indices.map { i in
        let start = offsets[i]
        let end = i + 1 < offsets.count ? offsets[i + 1] : units.count
        return String(decoding: units[start ..< end], as: UTF16.self)
    }
}
