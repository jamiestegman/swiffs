// Port of vscode-textmate `matcher.ts` (scope selector matching).

import Foundation

typealias ScopeMatcherFn = ([String]) -> Bool

struct MatcherWithPriority {
    var matcher: ScopeMatcherFn
    var priority: Int
}

private func isWordChar(_ c: UInt8) -> Bool {
    (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
}

/// Tokenizes with `/([LR]:|[\w\.:][\w\.:\-]*|[\,\|\-\(\)])/g`.
private func tokenizeSelector(_ input: String) -> [String] {
    let bytes = Array(input.utf8)
    var tokens: [String] = []
    var i = 0
    while i < bytes.count {
        let c = bytes[i]
        if (c == UInt8(ascii: "L") || c == UInt8(ascii: "R")), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: ":") {
            tokens.append(String(decoding: bytes[i ..< i + 2], as: UTF8.self))
            i += 2
            continue
        }
        if isWordChar(c) || c == UInt8(ascii: ".") || c == UInt8(ascii: ":") {
            var end = i + 1
            while end < bytes.count {
                let d = bytes[end]
                if isWordChar(d) || d == UInt8(ascii: ".") || d == UInt8(ascii: ":") || d == UInt8(ascii: "-") {
                    end += 1
                } else {
                    break
                }
            }
            tokens.append(String(decoding: bytes[i ..< end], as: UTF8.self))
            i = end
            continue
        }
        if c == UInt8(ascii: ",") || c == UInt8(ascii: "|") || c == UInt8(ascii: "-") || c == UInt8(ascii: "(") || c == UInt8(ascii: ")") {
            tokens.append(String(UnicodeScalar(c)))
        }
        i += 1
    }
    return tokens
}

private func isIdentifier(_ token: String?) -> Bool {
    guard let token else { return false }
    return token.utf8.contains { isWordChar($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: ":") }
}

func createMatchers(_ selector: String, _ matchesName: @escaping ([String], [String]) -> Bool) -> [MatcherWithPriority] {
    var results: [MatcherWithPriority] = []
    let tokens = tokenizeSelector(selector)
    var position = 0
    func next() -> String? {
        guard position < tokens.count else { return nil }
        defer { position += 1 }
        return tokens[position]
    }
    var token = next()

    func parseOperand() -> ScopeMatcherFn? {
        if token == "-" {
            token = next()
            let expressionToNegate = parseOperand()
            return { input in
                guard let expressionToNegate else { return false }
                return !expressionToNegate(input)
            }
        }
        if token == "(" {
            token = next()
            let expressionInParents = parseInnerExpression()
            if token == ")" {
                token = next()
            }
            return expressionInParents
        }
        if isIdentifier(token) {
            var identifiers: [String] = []
            repeat {
                identifiers.append(token!)
                token = next()
            } while isIdentifier(token)
            return { input in matchesName(identifiers, input) }
        }
        return nil
    }

    func parseConjunction() -> ScopeMatcherFn {
        var matchers: [ScopeMatcherFn] = []
        var matcher = parseOperand()
        while let current = matcher {
            matchers.append(current)
            matcher = parseOperand()
        }
        return { input in matchers.allSatisfy { $0(input) } }
    }

    func parseInnerExpression() -> ScopeMatcherFn {
        var matchers: [ScopeMatcherFn] = []
        var matcher: ScopeMatcherFn? = parseConjunction()
        while let current = matcher {
            matchers.append(current)
            if token == "|" || token == "," {
                repeat {
                    token = next()
                } while token == "|" || token == ","
            } else {
                break
            }
            matcher = parseConjunction()
        }
        return { input in matchers.contains { $0(input) } }
    }

    while token != nil {
        var priority = 0
        if let current = token, current.utf8.count == 2, current.utf8.last == UInt8(ascii: ":") {
            switch current.utf8.first {
            case UInt8(ascii: "R"): priority = 1
            case UInt8(ascii: "L"): priority = -1
            default: break
            }
            token = next()
        }
        let matcher = parseConjunction()
        results.append(MatcherWithPriority(matcher: matcher, priority: priority))
        if token != "," {
            break
        }
        token = next()
    }
    return results
}

/// vscode-textmate `nameMatcher`.
func nameMatcher(_ identifiers: [String], _ scopes: [String]) -> Bool {
    if scopes.count < identifiers.count { return false }
    var lastIndex = 0
    return identifiers.allSatisfy { identifier in
        var i = lastIndex
        while i < scopes.count {
            if scopesAreMatching(scopes[i], identifier) {
                lastIndex = i + 1
                return true
            }
            i += 1
        }
        return false
    }
}

func scopesAreMatching(_ thisScopeName: String, _ scopeName: String) -> Bool {
    if thisScopeName.isEmpty { return false }
    if thisScopeName == scopeName { return true }
    let len = scopeName.utf8.count
    let bytes = thisScopeName.utf8
    guard bytes.count > len, thisScopeName.utf8.starts(with: scopeName.utf8) else { return false }
    return bytes[bytes.index(bytes.startIndex, offsetBy: len)] == UInt8(ascii: ".")
}
