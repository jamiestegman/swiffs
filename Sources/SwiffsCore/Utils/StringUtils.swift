// Small string helpers ported from `packages/diffs/src/utils`.

import Foundation

/// Port of `cleanLastNewline`: strips one trailing `\n` (and a preceding
/// `\r`).
public func cleanLastNewline(_ contents: String) -> String {
    let utf8 = contents.utf8
    guard utf8.last == UInt8(ascii: "\n") else { return contents }
    var end = utf8.index(before: utf8.endIndex)
    if end > utf8.startIndex, utf8[utf8.index(before: end)] == UInt8(ascii: "\r") {
        end = utf8.index(before: end)
    }
    return String(contents[..<end])
}

/// Substring variant of `cleanLastNewline`.
public func cleanLastNewline(_ contents: Substring) -> Substring {
    let utf8 = contents.utf8
    guard utf8.last == UInt8(ascii: "\n") else { return contents }
    var end = utf8.index(before: utf8.endIndex)
    if end > utf8.startIndex, utf8[utf8.index(before: end)] == UInt8(ascii: "\r") {
        end = utf8.index(before: end)
    }
    return contents[..<end]
}

/// Port of `splitFileContents`: splits file contents into lines, preserving
/// trailing newlines on each line.
public func splitFileContents(_ contents: String) -> [String] {
    if contents.isEmpty { return [] }
    return splitWithNewlines(contents).map(String.init)
}

/// Splits after each `\n`, keeping the newline on the line. An empty string
/// yields `[""]` (matching the upstream parser helper).
func splitWithNewlines(_ contents: Substring) -> [Substring] {
    if contents.isEmpty { return [contents] }
    var lines: [Substring] = []
    let utf8 = contents.utf8
    var start = utf8.startIndex
    var index = start
    while index != utf8.endIndex {
        let next = utf8.index(after: index)
        if utf8[index] == UInt8(ascii: "\n") {
            lines.append(contents[start ..< next])
            start = next
        }
        index = next
    }
    if start != utf8.endIndex {
        lines.append(contents[start...])
    }
    return lines
}

func splitWithNewlines(_ contents: String) -> [Substring] {
    splitWithNewlines(contents[...])
}

public enum LineEndingType: String, Sendable {
    case crlf = "CRLF"
    case cr = "CR"
    case lf = "LF"
    case none
}

/// Port of `getLineEndingType`.
public func getLineEndingType(_ content: String) -> LineEndingType {
    if content.contains("\r\n") { return .crlf }
    if content.utf8.contains(UInt8(ascii: "\r")) { return .cr }
    if content.utf8.contains(UInt8(ascii: "\n")) { return .lf }
    return .none
}

private let cacheKeyVersion = 1

/// Port of `composeCacheKey`: encodes caller-controlled segments without
/// delimiter ambiguity (`ck1:["scope","seg",...]`).
public func composeCacheKey(_ scope: String, _ segments: String...) -> String {
    composeCacheKey(scope, segments: segments)
}

public func composeCacheKey(_ scope: String, segments: [String]) -> String {
    let parts = ([scope] + segments).map(jsonStringify)
    return "ck\(cacheKeyVersion):[" + parts.joined(separator: ",") + "]"
}

/// `JSON.stringify` for a string value, matching JavaScript's escaping.
func jsonStringify(_ value: String) -> String {
    var result = "\""
    let units = Array(value.utf16)
    var i = 0
    while i < units.count {
        let unit = units[i]
        switch unit {
        case 0x22: result += "\\\""
        case 0x5C: result += "\\\\"
        case 0x08: result += "\\b"
        case 0x0C: result += "\\f"
        case 0x0A: result += "\\n"
        case 0x0D: result += "\\r"
        case 0x09: result += "\\t"
        case 0x00 ..< 0x20:
            result += String(format: "\\u%04x", unit)
        case 0xD800 ... 0xDBFF:
            if i + 1 < units.count, (0xDC00 ... 0xDFFF).contains(units[i + 1]) {
                let scalar = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(units[i + 1]) - 0xDC00)
                result.unicodeScalars.append(Unicode.Scalar(scalar)!)
                i += 1
            } else {
                result += String(format: "\\u%04x", unit)
            }
        case 0xDC00 ... 0xDFFF:
            result += String(format: "\\u%04x", unit)
        default:
            result.unicodeScalars.append(Unicode.Scalar(unit)!)
        }
        i += 1
    }
    result += "\""
    return result
}

/// Port of `parseQuotedDiffFileName`: reads one quoted Git/jsdiff filename
/// and reports where the token ends (in UTF-16 code units).
public func parseQuotedDiffFileName(_ input: String) -> (fileName: String, rawLength: Int)? {
    let units = Array(input.utf16)
    guard units.first == 0x22 else { return nil }
    var fileNameUnits: [UInt16] = []
    var index = 1
    func readOctalByte(_ at: Int) -> UInt8? {
        guard at + 2 < units.count else { return nil }
        let first = Int(units[at]) - 48
        let second = Int(units[at + 1]) - 48
        let third = Int(units[at + 2]) - 48
        if (0 ... 3).contains(first), (0 ... 7).contains(second), (0 ... 7).contains(third) {
            return UInt8(first * 64 + second * 8 + third)
        }
        return nil
    }
    while index < units.count {
        let char = units[index]
        if char == 0x22 {
            return (String(decoding: fileNameUnits, as: UTF16.self), index + 1)
        }
        if char != 0x5C {
            fileNameUnits.append(char)
            index += 1
            continue
        }
        let escapedUnit: UInt16? = index + 1 < units.count ? units[index + 1] : nil
        let named: UInt16? = switch escapedUnit {
        case 0x22: 0x22 // "
        case 0x5C: 0x5C // \
        case 0x61: 0x07 // a
        case 0x62: 0x08 // b
        case 0x74: 0x09 // t
        case 0x6E: 0x0A // n
        case 0x76: 0x0B // v
        case 0x66: 0x0C // f
        case 0x72: 0x0D // r
        default: nil
        }
        if let named {
            fileNameUnits.append(named)
            index += 2
            continue
        }
        var bytes: [UInt8] = []
        repeat {
            guard let byte = readOctalByte(index + 1) else { return nil }
            bytes.append(byte)
            index += 4
        } while index + 1 < units.count && units[index] == 0x5C && (0x30 ... 0x37).contains(units[index + 1])
        fileNameUnits.append(contentsOf: String(decoding: bytes, as: UTF8.self).utf16)
    }
    return nil
}
