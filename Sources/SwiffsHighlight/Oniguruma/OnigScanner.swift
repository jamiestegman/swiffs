// Swift binding for Oniguruma mirroring vscode-oniguruma's `OnigScanner` /
// `OnigString` (the regex layer vscode-textmate and Shiki are built on).
//
// Offsets exposed to callers are UTF-16 code unit offsets (like JavaScript
// strings); Oniguruma itself runs on UTF-8.

import COniguruma
import Foundation

private let onigInitialized: Bool = {
    var encoding: OnigEncoding? = swiffs_onig_encoding_utf8()
    return withUnsafeMutablePointer(to: &encoding) { pointer in
        onig_initialize(pointer, 1) == ONIG_NORMAL
    }
}()

public struct OnigError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public var pattern: String
    public var description: String { "\(message) in pattern: \(pattern)" }
}

/// Options for `OnigScanner.findNextMatch` (vscode-textmate `FindOption`).
public struct OnigFindOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let notBeginString = OnigFindOptions(rawValue: 1)
    public static let notEndString = OnigFindOptions(rawValue: 2)
    public static let notBeginPosition = OnigFindOptions(rawValue: 4)

    var onigOptions: OnigOptionType {
        var options = OnigOptionType(ONIG_OPTION_NONE)
        if contains(.notBeginString) { options |= OnigOptionType(ONIG_OPTION_NOT_BEGIN_STRING) }
        if contains(.notEndString) { options |= OnigOptionType(ONIG_OPTION_NOT_END_STRING) }
        if contains(.notBeginPosition) { options |= OnigOptionType(ONIG_OPTION_NOT_BEGIN_POSITION) }
        return options
    }
}

/// A string prepared for scanning: UTF-8 bytes plus UTF-16 offset maps.
public final class OnigString {
    nonisolated(unsafe) private static var lastID = 0

    public let content: String
    let id: Int
    let utf8: [UInt8]
    /// UTF-16 code units of the content (JavaScript string view).
    let utf16: [UInt16]
    private let utf16ToUtf8: [Int32]?
    private let utf8ToUtf16: [Int32]?

    public var utf16Length: Int { utf16.count }

    public init(_ content: String) {
        OnigString.lastID &+= 1
        id = OnigString.lastID
        self.content = content
        let utf8 = Array(content.utf8)
        let utf16 = Array(content.utf16)
        self.utf8 = utf8
        self.utf16 = utf16
        if utf8.count == utf16.count {
            utf16ToUtf8 = nil
            utf8ToUtf16 = nil
        } else {
            var u16to8 = [Int32](repeating: 0, count: utf16.count + 1)
            var u8to16 = [Int32](repeating: 0, count: utf8.count + 1)
            u16to8[utf16.count] = Int32(utf8.count)
            u8to16[utf8.count] = Int32(utf16.count)
            var i8 = 0
            var i16 = 0
            for scalar in content.unicodeScalars {
                let v = scalar.value
                let byteCount = v <= 0x7F ? 1 : v <= 0x7FF ? 2 : v <= 0xFFFF ? 3 : 4
                u16to8[i16] = Int32(i8)
                if v > 0xFFFF {
                    u16to8[i16 + 1] = Int32(i8)
                }
                for b in 0 ..< byteCount {
                    u8to16[i8 + b] = Int32(i16)
                }
                i8 += byteCount
                i16 += v > 0xFFFF ? 2 : 1
            }
            utf16ToUtf8 = u16to8
            utf8ToUtf16 = u8to16
        }
    }

    @inline(__always)
    func convertUtf8OffsetToUtf16(_ offset: Int) -> Int {
        guard let map = utf8ToUtf16 else { return offset }
        if offset < 0 { return 0 }
        if offset > utf8.count { return utf16.count }
        return Int(map[offset])
    }

    @inline(__always)
    func convertUtf16OffsetToUtf8(_ offset: Int) -> Int {
        guard let map = utf16ToUtf8 else { return offset }
        if offset < 0 { return 0 }
        if offset > utf16.count { return utf8.count }
        return Int(map[offset])
    }

    /// `String.prototype.substring` over UTF-16 offsets.
    func substring(_ start: Int, _ end: Int) -> String {
        let s = max(0, min(start, end, utf16.count))
        let e = max(0, min(max(start, end), utf16.count))
        return String(decoding: utf16[s ..< e], as: UTF16.self)
    }
}

public struct OnigCaptureIndex: Hashable, Sendable {
    public var start: Int
    public var end: Int
    public var length: Int { end - start }
}

public struct OnigMatch: Sendable {
    public var index: Int
    public var captureIndices: [OnigCaptureIndex]
}

/// Compiles a list of patterns and finds the earliest match among them.
public final class OnigScanner {
    private final class Regex {
        let regex: OnigRegex
        let region: UnsafeMutablePointer<OnigRegion>
        let hasGAnchor: Bool
        var lastSearchStrCacheId = 0
        var lastSearchPosition = 0
        var lastSearchOption: OnigOptionType = OnigOptionType(ONIG_OPTION_NONE)
        var lastSearchMatched = false

        init(regex: OnigRegex, hasGAnchor: Bool) {
            self.regex = regex
            self.region = onig_region_new()
            self.hasGAnchor = hasGAnchor
        }

        deinit {
            // The regex itself is freed with the scanner's regset.
            onig_region_free(region, 1)
        }
    }

    private let regexes: [Regex]
    /// All patterns, searched together for short strings.
    private let regset: OpaquePointer?
    public let patterns: [String]

    public init(patterns: [String]) throws {
        _ = onigInitialized
        self.patterns = patterns
        var compiled: [Regex] = []
        compiled.reserveCapacity(patterns.count)
        for pattern in patterns {
            let bytes = Array(pattern.utf8)
            var regex: OnigRegex?
            var errorInfo = OnigErrorInfo()
            let status = bytes.withUnsafeBufferPointer { buffer -> Int32 in
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
            guard status == ONIG_NORMAL, let regex else {
                var message = [UInt8](repeating: 0, count: Int(ONIG_MAX_ERROR_MESSAGE_LEN))
                _ = withUnsafeMutablePointer(to: &errorInfo) { info in
                    message.withUnsafeMutableBufferPointer { buffer in
                        swiffs_onig_error_code_to_str(buffer.baseAddress!, status, info)
                    }
                }
                let text = String(decoding: message.prefix { $0 != 0 }, as: UTF8.self)
                throw OnigError(message: text, pattern: pattern)
            }
            compiled.append(Regex(regex: regex, hasGAnchor: Self.hasGAnchor(bytes)))
        }
        regexes = compiled
        var regs: [OnigRegex?] = compiled.map(\.regex)
        var set: OpaquePointer?
        let status = regs.withUnsafeMutableBufferPointer { buffer in
            onig_regset_new(&set, Int32(buffer.count), buffer.baseAddress)
        }
        if status == ONIG_NORMAL {
            regset = set
        } else {
            // Keep ownership with the scanner; free individually on deinit.
            regset = nil
        }
    }

    deinit {
        if let regset {
            onig_regset_free(regset)
        } else {
            for regex in regexes { onig_free(regex.regex) }
        }
    }

    private static func hasGAnchor(_ bytes: [UInt8]) -> Bool {
        var pos = 0
        while pos < bytes.count {
            if bytes[pos] == UInt8(ascii: "\\"), pos + 1 < bytes.count, bytes[pos + 1] == UInt8(ascii: "G") {
                return true
            }
            pos += 1
        }
        return false
    }

    /// Finds the earliest match of any pattern at or after `startPosition`
    /// (a UTF-16 offset). Ties are broken by pattern order.
    public func findNextMatch(_ string: OnigString, _ startPosition: Int, options: OnigFindOptions = []) -> OnigMatch? {
        let position = string.convertUtf16OffsetToUtf8(startPosition)
        let onigOptions = options.onigOptions
        return string.utf8.withUnsafeBufferPointer { buffer -> OnigMatch? in
            // Oniguruma needs a valid pointer even for empty strings.
            var empty: UInt8 = 0
            let base = buffer.baseAddress ?? withUnsafeMutablePointer(to: &empty) { UnsafePointer($0) }
            let length = buffer.count
            // vscode-oniguruma: the RegSet API is faster for short strings;
            // for longer ones per-pattern caching pays off.
            if length < 1000, let regset = self.regset {
                var matchPosition: Int32 = 0
                let index = onig_regset_search(regset, base, base + length, base + position, base + length, ONIG_REGSET_POSITION_LEAD, onigOptions, &matchPosition)
                guard index >= 0, let region = onig_regset_get_region(regset, index) else { return nil }
                return makeMatch(Int(index), region.pointee, string)
            }
            var bestLocation = 0
            var bestIndex = -1
            for (index, regex) in regexes.enumerated() {
                guard let region = search(regex, string.id, base, length, position, onigOptions),
                      region.pointee.num_regs > 0
                else { continue }
                let location = Int(region.pointee.beg[0])
                if bestIndex == -1 || location < bestLocation {
                    bestLocation = location
                    bestIndex = index
                }
                if location == position { break }
            }
            guard bestIndex >= 0 else { return nil }
            return makeMatch(bestIndex, regexes[bestIndex].region.pointee, string)
        }
    }

    private func makeMatch(_ index: Int, _ region: OnigRegion, _ string: OnigString) -> OnigMatch {
        var captures: [OnigCaptureIndex] = []
        captures.reserveCapacity(Int(region.num_regs))
        for i in 0 ..< Int(region.num_regs) {
            let beg = Int(region.beg[i])
            let end = Int(region.end[i])
            captures.append(OnigCaptureIndex(
                start: string.convertUtf8OffsetToUtf16(beg),
                end: string.convertUtf8OffsetToUtf16(end)
            ))
        }
        return OnigMatch(index: index, captureIndices: captures)
    }

    private func search(
        _ regex: Regex,
        _ strCacheId: Int,
        _ base: UnsafePointer<UInt8>,
        _ length: Int,
        _ position: Int,
        _ option: OnigOptionType
    ) -> UnsafeMutablePointer<OnigRegion>? {
        if !regex.hasGAnchor,
           regex.lastSearchStrCacheId == strCacheId,
           regex.lastSearchOption == option,
           regex.lastSearchPosition <= position
        {
            if !regex.lastSearchMatched { return nil }
            if Int(regex.region.pointee.beg[0]) >= position { return regex.region }
        }
        regex.lastSearchStrCacheId = strCacheId
        regex.lastSearchPosition = position
        regex.lastSearchOption = option
        let status = onig_search(
            regex.regex,
            base,
            base + length,
            base + position,
            base + length,
            regex.region,
            option
        )
        if status == ONIG_MISMATCH || status < 0 {
            regex.lastSearchMatched = false
            return nil
        }
        regex.lastSearchMatched = true
        return regex.region
    }
}
