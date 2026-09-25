// Parsed JSON from `JSONSerialization` holds bridged `NSString`s, which are
// slow to hash and scan on the tokenizer's hot paths (scope names, patterns,
// theme selectors). Grammars and themes copy their JSON into native Swift
// strings once when loaded.

import Foundation

/// A deep copy of parsed JSON with every string (and key) in native storage.
func nativeJSON(_ value: Any) -> Any {
    switch value {
    case let string as String:
        return nativeString(string)
    case let array as [Any]:
        return array.map(nativeJSON)
    case let object as [String: Any]:
        var copy: [String: Any] = [:]
        copy.reserveCapacity(object.count)
        for (key, value) in object {
            copy[nativeString(key)] = nativeJSON(value)
        }
        return copy
    default:
        return value
    }
}

private func nativeString(_ string: String) -> String {
    String(decoding: Array(string.utf8), as: UTF8.self)
}
