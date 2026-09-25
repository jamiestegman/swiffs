// Raw TextMate grammar model (vscode-textmate `rawGrammar.ts`).
//
// Raw rules are reference types because vscode-textmate caches compiled rule
// ids directly on the raw rule objects and relies on object identity.

import Foundation

public final class RawRule {
    /// Compiled rule id, assigned by `RuleFactory.getCompiledRuleId`.
    var id: Int?

    var include: String?
    var name: String?
    var contentName: String?

    var match: String?
    var captures: RawCaptures?

    var begin: String?
    var beginCaptures: RawCaptures?

    var end: String?
    var endCaptures: RawCaptures?

    var whilePattern: String?
    var whileCaptures: RawCaptures?

    var patterns: [RawRule]?
    var repository: [String: RawRule]?

    var applyEndPatternLast: Bool = false

    init() {}

    /// Builds a rule from parsed JSON.
    init(json: [String: Any]) {
        include = json["include"] as? String
        name = json["name"] as? String
        contentName = json["contentName"] as? String
        match = RawRule.regexSource(json["match"])
        captures = RawCaptures(json: json["captures"])
        begin = RawRule.regexSource(json["begin"])
        beginCaptures = RawCaptures(json: json["beginCaptures"])
        end = RawRule.regexSource(json["end"])
        endCaptures = RawCaptures(json: json["endCaptures"])
        whilePattern = RawRule.regexSource(json["while"])
        whileCaptures = RawCaptures(json: json["whileCaptures"])
        if let patterns = json["patterns"] as? [Any] {
            self.patterns = patterns.compactMap { ($0 as? [String: Any]).map(RawRule.init(json:)) }
        }
        if let repository = json["repository"] as? [String: Any] {
            var result: [String: RawRule] = [:]
            for (key, value) in repository {
                if let object = value as? [String: Any] {
                    result[key] = RawRule(json: object)
                }
            }
            self.repository = result
        }
        if let value = json["applyEndPatternLast"] {
            applyEndPatternLast = (value as? Bool) ?? ((value as? NSNumber)?.intValue ?? 0 != 0)
        }
    }

    private static func regexSource(_ value: Any?) -> String? {
        value as? String
    }

    /// Deep clone (vscode-textmate `clone`), dropping compiled ids.
    func clone() -> RawRule {
        let copy = RawRule()
        copy.include = include
        copy.name = name
        copy.contentName = contentName
        copy.match = match
        copy.captures = captures?.clone()
        copy.begin = begin
        copy.beginCaptures = beginCaptures?.clone()
        copy.end = end
        copy.endCaptures = endCaptures?.clone()
        copy.whilePattern = whilePattern
        copy.whileCaptures = whileCaptures?.clone()
        copy.patterns = patterns?.map { $0.clone() }
        copy.repository = repository?.mapValues { $0.clone() }
        copy.applyEndPatternLast = applyEndPatternLast
        return copy
    }
}

/// Capture rules keyed by capture index.
public final class RawCaptures {
    /// (index, rule) pairs in the object's key order.
    var entries: [(key: String, rule: RawRule)]

    init(entries: [(key: String, rule: RawRule)]) {
        self.entries = entries
    }

    convenience init?(json: Any?) {
        if let object = json as? [String: Any] {
            // JavaScript `for...in` visits integer-like keys in ascending
            // numeric order first, then string keys in insertion order.
            let sortedKeys = object.keys.sorted { a, b in
                let ia = Int(a), ib = Int(b)
                switch (ia, ib) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a < b
                }
            }
            var entries: [(String, RawRule)] = []
            for key in sortedKeys {
                if let rule = object[key] as? [String: Any] {
                    entries.append((key, RawRule(json: rule)))
                }
            }
            self.init(entries: entries)
        } else if let array = json as? [Any] {
            var entries: [(String, RawRule)] = []
            for (index, value) in array.enumerated() {
                if let rule = value as? [String: Any] {
                    entries.append((String(index), RawRule(json: rule)))
                }
            }
            self.init(entries: entries)
        } else {
            return nil
        }
    }

    func clone() -> RawCaptures {
        RawCaptures(entries: entries.map { ($0.key, $0.rule.clone()) })
    }
}

/// A raw TextMate grammar.
public final class RawGrammar {
    public let scopeName: String
    var patterns: [RawRule]
    var repository: [String: RawRule]
    var injections: [(selector: String, rule: RawRule)]?
    var injectionSelector: String?
    var name: String?

    /// The `$self` rule (`repository.$self`), set by `initGrammar`.
    var selfRule: RawRule!
    /// The `$base` rule (`repository.$base`), set by `initGrammar`.
    var baseRule: RawRule!

    init(scopeName: String, patterns: [RawRule], repository: [String: RawRule]) {
        self.scopeName = scopeName
        self.patterns = patterns
        self.repository = repository
    }

    /// Parses a grammar from JSON.
    public convenience init(json: [String: Any]) throws {
        let json = nativeJSON(json) as! [String: Any]
        guard let scopeName = json["scopeName"] as? String else {
            throw DiffsHighlightError("Grammar is missing scopeName")
        }
        let patterns = (json["patterns"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).map(RawRule.init(json:)) }
        var repository: [String: RawRule] = [:]
        for (key, value) in json["repository"] as? [String: Any] ?? [:] {
            if let object = value as? [String: Any] {
                repository[key] = RawRule(json: object)
            }
        }
        self.init(scopeName: scopeName, patterns: patterns, repository: repository)
        name = json["name"] as? String
        injectionSelector = json["injectionSelector"] as? String
        if let injections = json["injections"] as? [String: Any] {
            // Preserve source order where possible: JSONSerialization loses
            // key order, so order is recovered from the raw keys list when
            // provided by the loader (see `RawGrammar.orderedInjectionKeys`).
            var list: [(String, RawRule)] = []
            let keys = (json[RawGrammar.orderedInjectionKeysField] as? [String]) ?? injections.keys.sorted()
            for key in keys {
                if let object = injections[key] as? [String: Any] {
                    list.append((key, RawRule(json: object)))
                }
            }
            self.injections = list
        }
    }

    /// Field the grammar loader may add with the injection keys in source
    /// order (JSON object key order matters for injection priority ties).
    static let orderedInjectionKeysField = "__swiffsInjectionKeys"

    /// vscode-textmate `initGrammar`: clones the grammar and sets up `$self`
    /// and `$base` in its repository.
    func initGrammar(base: RawRule?) -> RawGrammar {
        let copy = RawGrammar(
            scopeName: scopeName,
            patterns: patterns.map { $0.clone() },
            repository: repository.mapValues { $0.clone() }
        )
        copy.name = name
        copy.injectionSelector = injectionSelector
        copy.injections = injections?.map { ($0.selector, $0.rule.clone()) }
        let selfRule = RawRule()
        selfRule.patterns = copy.patterns
        selfRule.name = copy.scopeName
        copy.selfRule = selfRule
        copy.baseRule = base ?? selfRule
        copy.repository["$self"] = selfRule
        copy.repository["$base"] = copy.baseRule
        return copy
    }
}

public struct DiffsHighlightError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
