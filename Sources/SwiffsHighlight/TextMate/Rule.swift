// Port of vscode-textmate `rule.ts` and the regex helpers from `utils.ts`.

import Foundation

let endRuleId = -1
let whileRuleId = -2

// MARK: - Regex source helpers

private func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

enum RegexSource {
    /// Matches `/\$(\d+)|\${(\d+):\/(downcase|upcase)}/`.
    static func hasCaptures(_ regexSource: String?) -> Bool {
        guard let regexSource else { return false }
        let units = Array(regexSource.utf16)
        var i = 0
        while i < units.count {
            if units[i] == 0x24 { // $
                if match(units, at: i) != nil { return true }
            }
            i += 1
        }
        return false
    }

    /// Returns (end, captureIndex, command) for a capture reference at `i`.
    private static func match(_ units: [UInt16], at i: Int) -> (end: Int, index: Int, command: String?)? {
        guard i < units.count, units[i] == 0x24 else { return nil }
        var j = i + 1
        if j < units.count, isDigit(units[j]) {
            var value = 0
            while j < units.count, isDigit(units[j]) {
                value = value &* 10 &+ Int(units[j] - 0x30)
                j += 1
            }
            return (j, value, nil)
        }
        // ${N:/downcase} or ${N:/upcase}
        guard j < units.count, units[j] == 0x7B else { return nil } // {
        j += 1
        let digitsStart = j
        var value = 0
        while j < units.count, isDigit(units[j]) {
            value = value &* 10 &+ Int(units[j] - 0x30)
            j += 1
        }
        guard j > digitsStart, j + 1 < units.count, units[j] == 0x3A, units[j + 1] == 0x2F else { return nil } // :/
        j += 2
        for command in ["downcase", "upcase"] {
            let commandUnits = Array(command.utf16)
            if j + commandUnits.count < units.count,
               Array(units[j ..< j + commandUnits.count]) == commandUnits,
               units[j + commandUnits.count] == 0x7D // }
            {
                return (j + commandUnits.count + 1, value, command)
            }
        }
        return nil
    }

    static func replaceCaptures(_ regexSource: String, _ captureSource: OnigString, _ captureIndices: [OnigCaptureIndex]) -> String {
        let units = Array(regexSource.utf16)
        var output: [UInt16] = []
        output.reserveCapacity(units.count)
        var i = 0
        while i < units.count {
            if units[i] == 0x24, let m = match(units, at: i) {
                if m.index < captureIndices.count {
                    let capture = captureIndices[m.index]
                    var result = captureSource.substring(capture.start, capture.end)
                    while result.utf16.first == 0x2E { // .
                        result = String(result.dropFirst())
                    }
                    switch m.command {
                    case "downcase": result = result.lowercased()
                    case "upcase": result = result.uppercased()
                    default: break
                    }
                    output.append(contentsOf: result.utf16)
                } else {
                    output.append(contentsOf: units[i ..< m.end])
                }
                i = m.end
                continue
            }
            output.append(units[i])
            i += 1
        }
        return String(decoding: output, as: UTF16.self)
    }
}

/// `escapeRegExpCharacters`: escapes `-\{}*+?|^$.,[]()#` and whitespace.
func escapeRegExpCharacters(_ value: String) -> String {
    var result = ""
    result.reserveCapacity(value.utf8.count)
    for scalar in value.unicodeScalars {
        switch scalar {
        case "-", "\\", "{", "}", "*", "+", "?", "|", "^", "$", ".", ",", "[", "]", "(", ")", "#":
            result.unicodeScalars.append("\\")
        default:
            if JSWhitespace.isWhitespace(scalar) {
                result.unicodeScalars.append("\\")
            }
        }
        result.unicodeScalars.append(scalar)
    }
    return result
}

enum JSWhitespace {
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09 ... 0x0D, 0x20, 0xA0, 0x1680, 0x2000 ... 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }
}

// MARK: - RegExpSource

final class RegExpSource {
    private(set) var source: String
    let ruleId: Int
    let hasAnchor: Bool
    let hasBackReferences: Bool
    private var anchorCache: (a0g0: String, a0g1: String, a1g0: String, a1g1: String)?

    init(_ regExpSource: String, _ ruleId: Int) {
        let units = Array(regExpSource.utf16)
        var output: [UInt16] = []
        var lastPushedPos = 0
        var hasAnchor = false
        var pos = 0
        var rewritten = false
        while pos < units.count {
            if units[pos] == 0x5C, pos + 1 < units.count { // \
                let next = units[pos + 1]
                if next == 0x7A { // z
                    output.append(contentsOf: units[lastPushedPos ..< pos])
                    output.append(contentsOf: "$(?!\\n)(?<!\\n)".utf16)
                    lastPushedPos = pos + 2
                    rewritten = true
                } else if next == 0x41 || next == 0x47 { // A or G
                    hasAnchor = true
                }
                pos += 1
            }
            pos += 1
        }
        self.hasAnchor = hasAnchor
        if !rewritten {
            source = regExpSource
        } else {
            output.append(contentsOf: units[lastPushedPos...])
            source = String(decoding: output, as: UTF16.self)
        }
        self.ruleId = ruleId
        hasBackReferences = RegExpSource.detectBackReferences(source)
        if hasAnchor {
            anchorCache = buildAnchorCache()
        }
    }

    private static func detectBackReferences(_ source: String) -> Bool {
        let units = Array(source.utf16)
        var i = 0
        while i + 1 < units.count {
            if units[i] == 0x5C, isDigit(units[i + 1]) { return true }
            i += 1
        }
        return false
    }

    func clone() -> RegExpSource {
        RegExpSource(source, ruleId)
    }

    func setSource(_ newSource: String) {
        if source == newSource { return }
        source = newSource
        if hasAnchor {
            anchorCache = buildAnchorCache()
        }
    }

    func resolveBackReferences(_ lineText: OnigString, _ captureIndices: [OnigCaptureIndex]) -> String {
        let capturedValues = captureIndices.map { lineText.substring($0.start, $0.end) }
        let units = Array(source.utf16)
        var output: [UInt16] = []
        var i = 0
        while i < units.count {
            if units[i] == 0x5C, i + 1 < units.count, isDigit(units[i + 1]) {
                var j = i + 1
                var value = 0
                while j < units.count, isDigit(units[j]) {
                    value = value &* 10 &+ Int(units[j] - 0x30)
                    j += 1
                }
                let captured = value < capturedValues.count ? capturedValues[value] : ""
                output.append(contentsOf: escapeRegExpCharacters(captured).utf16)
                i = j
                continue
            }
            output.append(units[i])
            i += 1
        }
        return String(decoding: output, as: UTF16.self)
    }

    private func buildAnchorCache() -> (String, String, String, String) {
        let units = Array(source.utf16)
        var a0g0 = units, a0g1 = units, a1g0 = units, a1g1 = units
        var pos = 0
        while pos < units.count {
            if units[pos] == 0x5C, pos + 1 < units.count {
                let next = units[pos + 1]
                if next == 0x41 { // A
                    a0g0[pos + 1] = 0xFFFF
                    a0g1[pos + 1] = 0xFFFF
                } else if next == 0x47 { // G
                    a0g0[pos + 1] = 0xFFFF
                    a1g0[pos + 1] = 0xFFFF
                }
                pos += 1
            }
            pos += 1
        }
        return (
            String(decoding: a0g0, as: UTF16.self),
            String(decoding: a0g1, as: UTF16.self),
            String(decoding: a1g0, as: UTF16.self),
            String(decoding: a1g1, as: UTF16.self)
        )
    }

    func resolveAnchors(allowA: Bool, allowG: Bool) -> String {
        guard hasAnchor, let anchorCache else { return source }
        switch (allowA, allowG) {
        case (true, true): return anchorCache.a1g1
        case (true, false): return anchorCache.a1g0
        case (false, true): return anchorCache.a0g1
        case (false, false): return anchorCache.a0g0
        }
    }
}

final class RegExpSourceList {
    private var items: [RegExpSource] = []
    private var hasAnchors = false
    private var cached: CompiledRule?
    private var anchorCache: [Int: CompiledRule] = [:]

    func push(_ item: RegExpSource) {
        items.append(item)
        hasAnchors = hasAnchors || item.hasAnchor
    }

    func unshift(_ item: RegExpSource) {
        items.insert(item, at: 0)
        hasAnchors = hasAnchors || item.hasAnchor
    }

    var count: Int { items.count }

    func setSource(_ index: Int, _ newSource: String) {
        if items[index].source != newSource {
            cached = nil
            anchorCache.removeAll()
            items[index].setSource(newSource)
        }
    }

    func compile() -> CompiledRule {
        if let cached { return cached }
        let compiled = CompiledRule(items.map(\.source), items.map(\.ruleId))
        cached = compiled
        return compiled
    }

    func compileAG(allowA: Bool, allowG: Bool) -> CompiledRule {
        if !hasAnchors { return compile() }
        let key = (allowA ? 2 : 0) | (allowG ? 1 : 0)
        if let cached = anchorCache[key] { return cached }
        let compiled = CompiledRule(items.map { $0.resolveAnchors(allowA: allowA, allowG: allowG) }, items.map(\.ruleId))
        anchorCache[key] = compiled
        return compiled
    }
}

final class CompiledRule {
    let regExps: [String]
    let rules: [Int]
    let scanner: OnigScanner

    init(_ regExps: [String], _ rules: [Int]) {
        self.regExps = regExps
        self.rules = rules
        if let scanner = try? OnigScanner(patterns: regExps) {
            self.scanner = scanner
        } else {
            // Compile patterns individually and neutralize the invalid ones
            // so the rest of the grammar keeps working.
            let sanitized = regExps.map { pattern -> String in
                if (try? OnigScanner(patterns: [pattern])) != nil { return pattern }
                HighlightDiagnostics.report("Invalid grammar regex: \(pattern)")
                return "(?!)"
            }
            self.scanner = try! OnigScanner(patterns: sanitized)
        }
    }

    func findNextMatch(_ string: OnigString, _ startPosition: Int, _ options: OnigFindOptions) -> (ruleId: Int, captureIndices: [OnigCaptureIndex])? {
        guard let result = scanner.findNextMatch(string, startPosition, options: options) else { return nil }
        return (rules[result.index], result.captureIndices)
    }
}

public enum HighlightDiagnostics {
    public nonisolated(unsafe) static var handler: (@Sendable (String) -> Void)?

    static func report(_ message: @autoclosure () -> String) {
        handler?(message())
    }
}

// MARK: - Rules

class Rule {
    let id: Int
    private let name: String?
    private let nameIsCapturing: Bool
    private let contentName: String?
    private let contentNameIsCapturing: Bool

    init(id: Int, name: String?, contentName: String?) {
        self.id = id
        self.name = name
        nameIsCapturing = RegexSource.hasCaptures(name)
        self.contentName = contentName
        contentNameIsCapturing = RegexSource.hasCaptures(contentName)
    }

    func getName(_ lineText: OnigString?, _ captureIndices: [OnigCaptureIndex]?) -> String? {
        guard nameIsCapturing, let name, let lineText, let captureIndices else { return name }
        return RegexSource.replaceCaptures(name, lineText, captureIndices)
    }

    func getContentName(_ lineText: OnigString, _ captureIndices: [OnigCaptureIndex]) -> String? {
        guard contentNameIsCapturing, let contentName else { return contentName }
        return RegexSource.replaceCaptures(contentName, lineText, captureIndices)
    }

    func collectPatterns(_ grammar: RuleRegistry, _ out: RegExpSourceList) {
        fatalError("Not supported")
    }

    func compile(_ grammar: RuleRegistry, _ endRegexSource: String?) -> CompiledRule {
        fatalError("Not supported")
    }

    func compileAG(_ grammar: RuleRegistry, _ endRegexSource: String?, allowA: Bool, allowG: Bool) -> CompiledRule {
        fatalError("Not supported")
    }
}

final class CaptureRule: Rule {
    let retokenizeCapturedWithRuleId: Int

    init(id: Int, name: String?, contentName: String?, retokenizeCapturedWithRuleId: Int) {
        self.retokenizeCapturedWithRuleId = retokenizeCapturedWithRuleId
        super.init(id: id, name: name, contentName: contentName)
    }
}

final class MatchRule: Rule {
    private let match: RegExpSource
    let captures: [CaptureRule?]
    private var cachedCompiledPatterns: RegExpSourceList?

    init(id: Int, name: String?, match: String, captures: [CaptureRule?]) {
        self.match = RegExpSource(match, id)
        self.captures = captures
        super.init(id: id, name: name, contentName: nil)
    }

    override func collectPatterns(_ grammar: RuleRegistry, _ out: RegExpSourceList) {
        out.push(match)
    }

    override func compile(_ grammar: RuleRegistry, _ endRegexSource: String?) -> CompiledRule {
        cachedPatterns(grammar).compile()
    }

    override func compileAG(_ grammar: RuleRegistry, _ endRegexSource: String?, allowA: Bool, allowG: Bool) -> CompiledRule {
        cachedPatterns(grammar).compileAG(allowA: allowA, allowG: allowG)
    }

    private func cachedPatterns(_ grammar: RuleRegistry) -> RegExpSourceList {
        if let cachedCompiledPatterns { return cachedCompiledPatterns }
        let list = RegExpSourceList()
        collectPatterns(grammar, list)
        cachedCompiledPatterns = list
        return list
    }
}

final class IncludeOnlyRule: Rule {
    let hasMissingPatterns: Bool
    let patterns: [Int]
    private var cachedCompiledPatterns: RegExpSourceList?

    init(id: Int, name: String?, contentName: String?, patterns: CompiledPatterns) {
        self.patterns = patterns.patterns
        hasMissingPatterns = patterns.hasMissingPatterns
        super.init(id: id, name: name, contentName: contentName)
    }

    override func collectPatterns(_ grammar: RuleRegistry, _ out: RegExpSourceList) {
        for pattern in patterns {
            grammar.getRule(pattern).collectPatterns(grammar, out)
        }
    }

    override func compile(_ grammar: RuleRegistry, _ endRegexSource: String?) -> CompiledRule {
        cachedPatterns(grammar).compile()
    }

    override func compileAG(_ grammar: RuleRegistry, _ endRegexSource: String?, allowA: Bool, allowG: Bool) -> CompiledRule {
        cachedPatterns(grammar).compileAG(allowA: allowA, allowG: allowG)
    }

    private func cachedPatterns(_ grammar: RuleRegistry) -> RegExpSourceList {
        if let cachedCompiledPatterns { return cachedCompiledPatterns }
        let list = RegExpSourceList()
        collectPatterns(grammar, list)
        cachedCompiledPatterns = list
        return list
    }
}

final class BeginEndRule: Rule {
    private let begin: RegExpSource
    let beginCaptures: [CaptureRule?]
    private let end: RegExpSource
    let endHasBackReferences: Bool
    let endCaptures: [CaptureRule?]
    let applyEndPatternLast: Bool
    let hasMissingPatterns: Bool
    let patterns: [Int]
    private var cachedCompiledPatterns: RegExpSourceList?

    init(
        id: Int,
        name: String?,
        contentName: String?,
        begin: String,
        beginCaptures: [CaptureRule?],
        end: String?,
        endCaptures: [CaptureRule?],
        applyEndPatternLast: Bool,
        patterns: CompiledPatterns
    ) {
        self.begin = RegExpSource(begin, id)
        self.beginCaptures = beginCaptures
        let endSource = (end?.isEmpty == false) ? end! : "\u{FFFF}"
        self.end = RegExpSource(endSource, endRuleId)
        endHasBackReferences = self.end.hasBackReferences
        self.endCaptures = endCaptures
        self.applyEndPatternLast = applyEndPatternLast
        self.patterns = patterns.patterns
        hasMissingPatterns = patterns.hasMissingPatterns
        super.init(id: id, name: name, contentName: contentName)
    }

    func getEndWithResolvedBackReferences(_ lineText: OnigString, _ captureIndices: [OnigCaptureIndex]) -> String {
        end.resolveBackReferences(lineText, captureIndices)
    }

    override func collectPatterns(_ grammar: RuleRegistry, _ out: RegExpSourceList) {
        out.push(begin)
    }

    override func compile(_ grammar: RuleRegistry, _ endRegexSource: String?) -> CompiledRule {
        cachedPatterns(grammar, endRegexSource).compile()
    }

    override func compileAG(_ grammar: RuleRegistry, _ endRegexSource: String?, allowA: Bool, allowG: Bool) -> CompiledRule {
        cachedPatterns(grammar, endRegexSource).compileAG(allowA: allowA, allowG: allowG)
    }

    private func cachedPatterns(_ grammar: RuleRegistry, _ endRegexSource: String?) -> RegExpSourceList {
        let list: RegExpSourceList
        if let cachedCompiledPatterns {
            list = cachedCompiledPatterns
        } else {
            list = RegExpSourceList()
            for pattern in patterns {
                grammar.getRule(pattern).collectPatterns(grammar, list)
            }
            if applyEndPatternLast {
                list.push(end.hasBackReferences ? end.clone() : end)
            } else {
                list.unshift(end.hasBackReferences ? end.clone() : end)
            }
            cachedCompiledPatterns = list
        }
        if end.hasBackReferences, let endRegexSource {
            if applyEndPatternLast {
                list.setSource(list.count - 1, endRegexSource)
            } else {
                list.setSource(0, endRegexSource)
            }
        }
        return list
    }
}

final class BeginWhileRule: Rule {
    private let begin: RegExpSource
    let beginCaptures: [CaptureRule?]
    let whileCaptures: [CaptureRule?]
    private let whileSource: RegExpSource
    let whileHasBackReferences: Bool
    let hasMissingPatterns: Bool
    let patterns: [Int]
    private var cachedCompiledPatterns: RegExpSourceList?
    private var cachedCompiledWhilePatterns: RegExpSourceList?

    init(
        id: Int,
        name: String?,
        contentName: String?,
        begin: String,
        beginCaptures: [CaptureRule?],
        whilePattern: String,
        whileCaptures: [CaptureRule?],
        patterns: CompiledPatterns
    ) {
        self.begin = RegExpSource(begin, id)
        self.beginCaptures = beginCaptures
        self.whileCaptures = whileCaptures
        whileSource = RegExpSource(whilePattern, whileRuleId)
        whileHasBackReferences = whileSource.hasBackReferences
        self.patterns = patterns.patterns
        hasMissingPatterns = patterns.hasMissingPatterns
        super.init(id: id, name: name, contentName: contentName)
    }

    func getWhileWithResolvedBackReferences(_ lineText: OnigString, _ captureIndices: [OnigCaptureIndex]) -> String {
        whileSource.resolveBackReferences(lineText, captureIndices)
    }

    override func collectPatterns(_ grammar: RuleRegistry, _ out: RegExpSourceList) {
        out.push(begin)
    }

    override func compile(_ grammar: RuleRegistry, _ endRegexSource: String?) -> CompiledRule {
        cachedPatterns(grammar).compile()
    }

    override func compileAG(_ grammar: RuleRegistry, _ endRegexSource: String?, allowA: Bool, allowG: Bool) -> CompiledRule {
        cachedPatterns(grammar).compileAG(allowA: allowA, allowG: allowG)
    }

    private func cachedPatterns(_ grammar: RuleRegistry) -> RegExpSourceList {
        if let cachedCompiledPatterns { return cachedCompiledPatterns }
        let list = RegExpSourceList()
        for pattern in patterns {
            grammar.getRule(pattern).collectPatterns(grammar, list)
        }
        cachedCompiledPatterns = list
        return list
    }

    func compileWhileAG(_ grammar: RuleRegistry, _ endRegexSource: String?, allowA: Bool, allowG: Bool) -> CompiledRule {
        cachedWhilePatterns(endRegexSource).compileAG(allowA: allowA, allowG: allowG)
    }

    private func cachedWhilePatterns(_ endRegexSource: String?) -> RegExpSourceList {
        let list: RegExpSourceList
        if let cachedCompiledWhilePatterns {
            list = cachedCompiledWhilePatterns
        } else {
            list = RegExpSourceList()
            list.push(whileSource.hasBackReferences ? whileSource.clone() : whileSource)
            cachedCompiledWhilePatterns = list
        }
        if whileSource.hasBackReferences {
            list.setSource(0, endRegexSource ?? "\u{FFFF}")
        }
        return list
    }
}

struct CompiledPatterns {
    var patterns: [Int]
    var hasMissingPatterns: Bool
}

/// The rule registry + external grammar lookup a `RuleFactory` needs.
protocol RuleRegistry: AnyObject {
    func registerRule<T: Rule>(_ factory: (Int) -> T) -> T
    func getRule(_ ruleId: Int) -> Rule
    func getRuleIfExists(_ ruleId: Int) -> Rule?
    func getExternalGrammar(_ scopeName: String, _ repository: [String: RawRule]?) -> RawGrammar?
}

// MARK: - Includes

enum IncludeReference {
    case base
    case selfReference
    case relative(ruleName: String)
    case topLevel(scopeName: String)
    case topLevelRepository(scopeName: String, ruleName: String)
}

func parseInclude(_ include: String) -> IncludeReference {
    if include == "$base" { return .base }
    if include == "$self" { return .selfReference }
    guard let sharp = include.firstIndex(of: "#") else {
        return .topLevel(scopeName: include)
    }
    if sharp == include.startIndex {
        return .relative(ruleName: String(include[include.index(after: sharp)...]))
    }
    return .topLevelRepository(
        scopeName: String(include[..<sharp]),
        ruleName: String(include[include.index(after: sharp)...])
    )
}

// MARK: - RuleFactory

enum RuleFactory {
    static func createCaptureRule(_ helper: RuleRegistry, name: String?, contentName: String?, retokenizeCapturedWithRuleId: Int) -> CaptureRule {
        helper.registerRule { id in
            CaptureRule(id: id, name: name, contentName: contentName, retokenizeCapturedWithRuleId: retokenizeCapturedWithRuleId)
        }
    }

    static func getCompiledRuleId(_ desc: RawRule, _ helper: RuleRegistry, _ repository: [String: RawRule]) -> Int {
        if let id = desc.id { return id }
        _ = helper.registerRule { id -> Rule in
            desc.id = id
            if let match = desc.match {
                return MatchRule(
                    id: id,
                    name: desc.name,
                    match: match,
                    captures: compileCaptures(desc.captures, helper, repository)
                )
            }
            guard let begin = desc.begin else {
                var repository = repository
                if let own = desc.repository {
                    repository.merge(own) { _, new in new }
                }
                var patterns = desc.patterns
                if patterns == nil, let include = desc.include {
                    let rule = RawRule()
                    rule.include = include
                    patterns = [rule]
                }
                return IncludeOnlyRule(
                    id: id,
                    name: desc.name,
                    contentName: desc.contentName,
                    patterns: compilePatterns(patterns, helper, repository)
                )
            }
            if let whilePattern = desc.whilePattern {
                return BeginWhileRule(
                    id: id,
                    name: desc.name,
                    contentName: desc.contentName,
                    begin: begin,
                    beginCaptures: compileCaptures(desc.beginCaptures ?? desc.captures, helper, repository),
                    whilePattern: whilePattern,
                    whileCaptures: compileCaptures(desc.whileCaptures ?? desc.captures, helper, repository),
                    patterns: compilePatterns(desc.patterns, helper, repository)
                )
            }
            return BeginEndRule(
                id: id,
                name: desc.name,
                contentName: desc.contentName,
                begin: begin,
                beginCaptures: compileCaptures(desc.beginCaptures ?? desc.captures, helper, repository),
                end: desc.end,
                endCaptures: compileCaptures(desc.endCaptures ?? desc.captures, helper, repository),
                applyEndPatternLast: desc.applyEndPatternLast,
                patterns: compilePatterns(desc.patterns, helper, repository)
            )
        }
        return desc.id!
    }

    private static func compileCaptures(_ captures: RawCaptures?, _ helper: RuleRegistry, _ repository: [String: RawRule]) -> [CaptureRule?] {
        guard let captures else { return [] }
        var maximumCaptureId = 0
        for entry in captures.entries {
            if let numeric = Int(entry.key), numeric > maximumCaptureId {
                maximumCaptureId = numeric
            }
        }
        var result = [CaptureRule?](repeating: nil, count: maximumCaptureId + 1)
        for entry in captures.entries {
            guard let numeric = Int(entry.key), numeric >= 0 else { continue }
            var retokenizeCapturedWithRuleId = 0
            if entry.rule.patterns != nil {
                retokenizeCapturedWithRuleId = getCompiledRuleId(entry.rule, helper, repository)
            }
            result[numeric] = createCaptureRule(
                helper,
                name: entry.rule.name,
                contentName: entry.rule.contentName,
                retokenizeCapturedWithRuleId: retokenizeCapturedWithRuleId
            )
        }
        return result
    }

    private static func compilePatterns(_ patterns: [RawRule]?, _ helper: RuleRegistry, _ repository: [String: RawRule]) -> CompiledPatterns {
        var result: [Int] = []
        for pattern in patterns ?? [] {
            var ruleId = -1
            if let include = pattern.include {
                switch parseInclude(include) {
                case .base, .selfReference:
                    if let rule = repository[include] {
                        ruleId = getCompiledRuleId(rule, helper, repository)
                    }
                case .relative(let ruleName):
                    if let localIncludedRule = repository[ruleName] {
                        ruleId = getCompiledRuleId(localIncludedRule, helper, repository)
                    }
                case .topLevel(let scopeName):
                    if let externalGrammar = helper.getExternalGrammar(scopeName, repository) {
                        ruleId = getCompiledRuleId(externalGrammar.selfRule, helper, externalGrammar.repository)
                    }
                case .topLevelRepository(let scopeName, let ruleName):
                    if let externalGrammar = helper.getExternalGrammar(scopeName, repository),
                       let externalIncludedRule = externalGrammar.repository[ruleName]
                    {
                        ruleId = getCompiledRuleId(externalIncludedRule, helper, externalGrammar.repository)
                    }
                }
            } else {
                ruleId = getCompiledRuleId(pattern, helper, repository)
            }
            if ruleId != -1 {
                let rule = helper.getRuleIfExists(ruleId)
                var skipRule = false
                if let includeOnly = rule as? IncludeOnlyRule {
                    skipRule = includeOnly.hasMissingPatterns && includeOnly.patterns.isEmpty
                } else if let beginEnd = rule as? BeginEndRule {
                    skipRule = beginEnd.hasMissingPatterns && beginEnd.patterns.isEmpty
                } else if let beginWhile = rule as? BeginWhileRule {
                    skipRule = beginWhile.hasMissingPatterns && beginWhile.patterns.isEmpty
                }
                if skipRule { continue }
                result.append(ruleId)
            }
        }
        return CompiledPatterns(patterns: result, hasMissingPatterns: (patterns?.count ?? 0) != result.count)
    }
}
