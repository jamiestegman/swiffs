// Port of vscode-textmate `grammar/grammar.ts`, `tokenizeString.ts`,
// `basicScopesAttributeProvider.ts` and `encodedTokenAttributes.ts`.

import Foundation

// MARK: - Encoded token metadata

enum StandardTokenType {
    static let other = 0
    static let comment = 1
    static let string = 2
    static let regEx = 3
    static let notSet = 8
}

enum EncodedTokenMetadata {
    static func getLanguageId(_ m: UInt32) -> Int { Int(m & 0xFF) }
    static func getTokenType(_ m: UInt32) -> Int { Int((m & 0x300) >> 8) }
    static func containsBalancedBrackets(_ m: UInt32) -> Bool { (m & 0x400) != 0 }
    static func getFontStyle(_ m: UInt32) -> Int { Int((m & 0x7800) >> 11) }
    static func getForeground(_ m: UInt32) -> Int { Int((m & 0xFF8000) >> 15) }
    static func getBackground(_ m: UInt32) -> Int { Int((m & 0xFF00_0000) >> 24) }

    /// Updates the fields in `metadata`. A value of `0`, `NotSet` or `nil`
    /// indicates that the corresponding field should be left as is.
    static func set(
        _ metadata: UInt32,
        languageId: Int,
        tokenType: Int,
        containsBalancedBrackets: Bool?,
        fontStyle: Int,
        foreground: Int,
        background: Int
    ) -> UInt32 {
        var languageIdValue = getLanguageId(metadata)
        var tokenTypeValue = getTokenType(metadata)
        var balancedBit = EncodedTokenMetadata.containsBalancedBrackets(metadata) ? 1 : 0
        var fontStyleValue = getFontStyle(metadata)
        var foregroundValue = getForeground(metadata)
        var backgroundValue = getBackground(metadata)
        if languageId != 0 { languageIdValue = languageId }
        if tokenType != StandardTokenType.notSet { tokenTypeValue = tokenType }
        if let containsBalancedBrackets { balancedBit = containsBalancedBrackets ? 1 : 0 }
        if fontStyle != FontStyle.notSet { fontStyleValue = fontStyle }
        if foreground != 0 { foregroundValue = foreground }
        if background != 0 { backgroundValue = background }
        var result: Int = languageIdValue
        result |= tokenTypeValue << 8
        result |= balancedBit << 10
        result |= fontStyleValue << 11
        result |= foregroundValue << 15
        result |= backgroundValue << 24
        return UInt32(truncatingIfNeeded: result)
    }
}

// MARK: - Basic scope attributes

struct BasicScopeAttributes {
    var languageId: Int
    var tokenType: Int
}

final class BasicScopeAttributesProvider {
    let defaultAttributes: BasicScopeAttributes
    private var cache: [String: BasicScopeAttributes] = [:]
    private static let nullScopeMetadata = BasicScopeAttributes(languageId: 0, tokenType: 0)

    init(initialLanguageId: Int) {
        defaultAttributes = BasicScopeAttributes(languageId: initialLanguageId, tokenType: StandardTokenType.notSet)
    }

    func getBasicScopeAttributes(_ scopeName: String?) -> BasicScopeAttributes {
        guard let scopeName else { return Self.nullScopeMetadata }
        if let cached = cache[scopeName] { return cached }
        let value = BasicScopeAttributes(languageId: 0, tokenType: Self.toStandardTokenType(scopeName))
        cache[scopeName] = value
        return value
    }

    /// Matches `/\b(comment|string|regex|meta\.embedded)\b/`.
    private static func toStandardTokenType(_ scopeName: String) -> Int {
        let bytes = Array(scopeName.utf8)
        func isWord(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F
        }
        let candidates: [(String, Int)] = [
            ("comment", StandardTokenType.comment),
            ("string", StandardTokenType.string),
            ("regex", StandardTokenType.regEx),
            ("meta.embedded", StandardTokenType.other),
        ]
        var i = 0
        while i < bytes.count {
            if i == 0 || !isWord(bytes[i - 1]) {
                for (word, type) in candidates {
                    let w = Array(word.utf8)
                    if i + w.count <= bytes.count, Array(bytes[i ..< i + w.count]) == w {
                        let end = i + w.count
                        if end == bytes.count || !isWord(bytes[end]) {
                            return type
                        }
                    }
                }
            }
            i += 1
        }
        return StandardTokenType.notSet
    }
}

// MARK: - Balanced brackets

final class BalancedBracketSelectors {
    private var balancedBracketScopes: [ScopeMatcherFn] = []
    private var unbalancedBracketScopes: [ScopeMatcherFn] = []
    private var allowAny = false

    init(balancedBracketScopes: [String], unbalancedBracketScopes: [String]) {
        for selector in balancedBracketScopes {
            if selector == "*" {
                allowAny = true
                continue
            }
            self.balancedBracketScopes.append(contentsOf: createMatchers(selector, nameMatcher).map(\.matcher))
        }
        for selector in unbalancedBracketScopes {
            self.unbalancedBracketScopes.append(contentsOf: createMatchers(selector, nameMatcher).map(\.matcher))
        }
    }

    var matchesAlways: Bool { allowAny && unbalancedBracketScopes.isEmpty }
    var matchesNever: Bool { balancedBracketScopes.isEmpty && !allowAny }

    func match(_ scopes: [String]) -> Bool {
        for excluder in unbalancedBracketScopes where excluder(scopes) { return false }
        for includer in balancedBracketScopes where includer(scopes) { return true }
        return allowAny
    }
}

// MARK: - Scope stacks

final class AttributedScopeStack {
    let parent: AttributedScopeStack?
    let scopePath: ScopeStack
    let tokenAttributes: UInt32
    /// Roots only: whether the root scope was looked up in the theme
    /// (`createRootAndLookUpScopeName`) rather than created as-is.
    let lookedUpRoot: Bool

    init(_ parent: AttributedScopeStack?, _ scopePath: ScopeStack, _ tokenAttributes: UInt32, lookedUpRoot: Bool = true) {
        self.parent = parent
        self.scopePath = scopePath
        self.tokenAttributes = tokenAttributes
        self.lookedUpRoot = lookedUpRoot
    }

    static func createRoot(_ scopeName: String, _ tokenAttributes: UInt32) -> AttributedScopeStack {
        AttributedScopeStack(nil, ScopeStack(nil, scopeName), tokenAttributes, lookedUpRoot: false)
    }

    static func createRootAndLookUpScopeName(_ scopeName: String, _ tokenAttributes: UInt32, _ grammar: Grammar) -> AttributedScopeStack {
        let rawRootMetadata = grammar.getMetadataForScope(scopeName)
        let scopePath = ScopeStack(nil, scopeName)
        let rootStyle = grammar.themeProvider.themeMatch(scopePath)
        let resolved = mergeAttributes(tokenAttributes, rawRootMetadata, rootStyle)
        return AttributedScopeStack(nil, scopePath, resolved)
    }

    var scopeName: String { scopePath.scopeName }

    static func equals(_ a: AttributedScopeStack?, _ b: AttributedScopeStack?) -> Bool {
        var a = a
        var b = b
        while true {
            if a === b { return true }
            guard let x = a, let y = b else { return a == nil && b == nil }
            if x.scopeName != y.scopeName || x.tokenAttributes != y.tokenAttributes { return false }
            a = x.parent
            b = y.parent
        }
    }

    static func mergeAttributes(_ existing: UInt32, _ basic: BasicScopeAttributes, _ style: StyleAttributes?) -> UInt32 {
        var fontStyle = FontStyle.notSet
        var foreground = 0
        var background = 0
        if let style {
            fontStyle = style.fontStyle
            foreground = style.foregroundId
            background = style.backgroundId
        }
        return EncodedTokenMetadata.set(
            existing,
            languageId: basic.languageId,
            tokenType: basic.tokenType,
            containsBalancedBrackets: nil,
            fontStyle: fontStyle,
            foreground: foreground,
            background: background
        )
    }

    func pushAttributed(_ scopePath: String?, _ grammar: Grammar) -> AttributedScopeStack {
        guard let scopePath else { return self }
        if !scopePath.utf8.contains(UInt8(ascii: " ")) {
            return AttributedScopeStack.pushAttributed(self, scopePath, grammar)
        }
        var result = self
        for scope in scopePath.split(separator: " ", omittingEmptySubsequences: false) {
            result = AttributedScopeStack.pushAttributed(result, String(scope), grammar)
        }
        return result
    }

    private static func pushAttributed(_ target: AttributedScopeStack, _ scopeName: String, _ grammar: Grammar) -> AttributedScopeStack {
        let rawMetadata = grammar.getMetadataForScope(scopeName)
        let newPath = target.scopePath.push(scopeName)
        let scopeThemeMatchResult = grammar.themeProvider.themeMatch(newPath)
        let metadata = mergeAttributes(target.tokenAttributes, rawMetadata, scopeThemeMatchResult)
        return AttributedScopeStack(target, newPath, metadata)
    }

    func getScopeNames() -> [String] {
        scopePath.getSegments()
    }
}

/// The tokenizer state carried between lines (vscode-textmate
/// `StateStackImpl`).
public final class StateStack {
    let parent: StateStack?
    let ruleId: Int
    let beginRuleCapturedEOL: Bool
    let endRule: String?
    let nameScopesList: AttributedScopeStack?
    let contentNameScopesList: AttributedScopeStack?
    let depth: Int
    fileprivate var enterPos: Int
    fileprivate var anchorPos: Int

    init(
        _ parent: StateStack?,
        _ ruleId: Int,
        _ enterPos: Int,
        _ anchorPos: Int,
        _ beginRuleCapturedEOL: Bool,
        _ endRule: String?,
        _ nameScopesList: AttributedScopeStack?,
        _ contentNameScopesList: AttributedScopeStack?
    ) {
        self.parent = parent
        self.ruleId = ruleId
        self.beginRuleCapturedEOL = beginRuleCapturedEOL
        self.endRule = endRule
        self.nameScopesList = nameScopesList
        self.contentNameScopesList = contentNameScopesList
        depth = (parent?.depth ?? 0) + 1
        self.enterPos = enterPos
        self.anchorPos = anchorPos
    }

    /// The initial state (`INITIAL` / `StateStackImpl.NULL`).
    nonisolated(unsafe) public static let initial = StateStack(nil, 0, 0, 0, false, nil, nil, nil)

    public func equals(_ other: StateStack?) -> Bool {
        guard let other else { return false }
        return StateStack.equals(self, other)
    }

    private static func equals(_ a: StateStack, _ b: StateStack) -> Bool {
        if a === b { return true }
        if !structuralEquals(a, b) { return false }
        return AttributedScopeStack.equals(a.contentNameScopesList, b.contentNameScopesList)
    }

    private static func structuralEquals(_ a: StateStack?, _ b: StateStack?) -> Bool {
        var a = a
        var b = b
        while true {
            if a === b { return true }
            guard let x = a, let y = b else { return a == nil && b == nil }
            if x.depth != y.depth || x.ruleId != y.ruleId || x.endRule != y.endRule { return false }
            a = x.parent
            b = y.parent
        }
    }

    fileprivate func reset() {
        var element: StateStack? = self
        while let current = element {
            current.enterPos = -1
            current.anchorPos = -1
            element = current.parent
        }
    }

    func pop() -> StateStack? { parent }

    func safePop() -> StateStack { parent ?? self }

    func push(
        _ ruleId: Int,
        _ enterPos: Int,
        _ anchorPos: Int,
        _ beginRuleCapturedEOL: Bool,
        _ endRule: String?,
        _ nameScopesList: AttributedScopeStack?,
        _ contentNameScopesList: AttributedScopeStack?
    ) -> StateStack {
        StateStack(self, ruleId, enterPos, anchorPos, beginRuleCapturedEOL, endRule, nameScopesList, contentNameScopesList)
    }

    func getRule(_ grammar: Grammar) -> Rule { grammar.getRule(ruleId) }

    func withContentNameScopesList(_ contentNameScopeStack: AttributedScopeStack?) -> StateStack {
        if contentNameScopesList === contentNameScopeStack { return self }
        return parent!.push(ruleId, enterPos, anchorPos, beginRuleCapturedEOL, endRule, nameScopesList, contentNameScopeStack)
    }

    func withEndRule(_ endRule: String) -> StateStack {
        if self.endRule == endRule { return self }
        return StateStack(parent, ruleId, enterPos, anchorPos, beginRuleCapturedEOL, endRule, nameScopesList, contentNameScopesList)
    }

    /// Used to warn of endless loops.
    func hasSameRuleAs(_ other: StateStack) -> Bool {
        var element: StateStack? = self
        while let current = element, current.enterPos == other.enterPos {
            if current.ruleId == other.ruleId { return true }
            element = current.parent
        }
        return false
    }

    /// Scope names of the stack (Shiki `getScopes`).
    public var scopes: [String] {
        var result: [String] = []
        var element: StateStack? = self
        while let current = element {
            if let name = current.nameScopesList?.scopeName { result.append(name) }
            element = current.parent
        }
        return result
    }
}

// MARK: - Line tokens

final class LineTokens {
    private let balancedBracketSelectors: BalancedBracketSelectors?
    private var binaryTokens: [UInt32] = []
    private var lastTokenEndIndex = 0

    init(balancedBracketSelectors: BalancedBracketSelectors?) {
        self.balancedBracketSelectors = balancedBracketSelectors
    }

    func produce(_ stack: StateStack, _ endIndex: Int) {
        produceFromScopes(stack.contentNameScopesList, endIndex)
    }

    /// Unmerged tokens with their scopes, recorded for resolving other themes
    /// from one tokenization.
    var scopeTokens: [(start: Int, scopes: AttributedScopeStack?)]?

    func produceFromScopes(_ scopesList: AttributedScopeStack?, _ endIndex: Int) {
        if lastTokenEndIndex >= endIndex { return }
        scopeTokens?.append((lastTokenEndIndex, scopesList))
        let metadata = applyBalancedBrackets(scopesList?.tokenAttributes ?? 0, scopesList)
        if let last = binaryTokens.last, last == metadata {
            lastTokenEndIndex = endIndex
            return
        }
        binaryTokens.append(UInt32(truncatingIfNeeded: lastTokenEndIndex))
        binaryTokens.append(metadata)
        lastTokenEndIndex = endIndex
    }

    func applyBalancedBrackets(_ metadata: UInt32, _ scopesList: AttributedScopeStack?) -> UInt32 {
        var metadata = metadata
        var containsBalancedBrackets = false
        if balancedBracketSelectors?.matchesAlways == true {
            containsBalancedBrackets = true
        }
        if let selectors = balancedBracketSelectors, !selectors.matchesAlways, !selectors.matchesNever {
            let scopes = scopesList?.getScopeNames() ?? []
            containsBalancedBrackets = selectors.match(scopes)
        }
        if containsBalancedBrackets {
            metadata = EncodedTokenMetadata.set(
                metadata,
                languageId: 0,
                tokenType: StandardTokenType.notSet,
                containsBalancedBrackets: true,
                fontStyle: FontStyle.notSet,
                foreground: 0,
                background: 0
            )
        }
        return metadata
    }

    func getBinaryResult(_ stack: StateStack, _ lineLength: Int) -> [UInt32] {
        if binaryTokens.count >= 2, binaryTokens[binaryTokens.count - 2] == UInt32(truncatingIfNeeded: lineLength - 1) {
            binaryTokens.removeLast()
            binaryTokens.removeLast()
        }
        if binaryTokens.isEmpty {
            lastTokenEndIndex = -1
            produce(stack, lineLength)
            binaryTokens[binaryTokens.count - 2] = 0
        }
        return binaryTokens
    }
}

/// Recomputes `AttributedScopeStack` attributes under another theme, along
/// the same scope chain (`createRootAndLookUpScopeName` / `pushAttributed`).
final class ThemeAttributeResolver {
    private let theme: TextMateTheme
    private let defaultMetadata: UInt32
    private let basicAttributes: (String) -> BasicScopeAttributes
    /// Keyed by stack identity; holding the stack keeps the key unique.
    private var memo: [ObjectIdentifier: (stack: AttributedScopeStack, attributes: UInt32)] = [:]

    init(theme: TextMateTheme, defaultMetadata: UInt32, basicAttributes: @escaping (String) -> BasicScopeAttributes) {
        self.theme = theme
        self.defaultMetadata = defaultMetadata
        self.basicAttributes = basicAttributes
    }

    var colorMap: [String] { theme.getColorMap() }

    func attributes(_ stack: AttributedScopeStack?) -> UInt32 {
        guard let stack else { return 0 }
        let key = ObjectIdentifier(stack)
        if let cached = memo[key] { return cached.attributes }
        let resolved: UInt32
        if let parent = stack.parent {
            resolved = AttributedScopeStack.mergeAttributes(attributes(parent), basicAttributes(stack.scopeName), theme.match(stack.scopePath))
        } else if stack.lookedUpRoot {
            resolved = AttributedScopeStack.mergeAttributes(defaultMetadata, basicAttributes(stack.scopeName), theme.match(stack.scopePath))
        } else {
            resolved = defaultMetadata
        }
        memo[key] = (stack, resolved)
        return resolved
    }
}

// MARK: - Grammar

struct Injection {
    var debugSelector: String
    var matcher: ScopeMatcherFn
    var priority: Int
    var ruleId: Int
}

/// Provides grammars and theme matching to a `Grammar` (vscode-textmate
/// `SyncRegistry`).
protocol GrammarRepository: AnyObject {
    func lookup(_ scopeName: String) -> RawGrammar?
    func injections(_ scopeName: String) -> [String]?
    var themeProvider: ThemeProvider { get }
}

final class ThemeProvider {
    var theme: TextMateTheme

    init(theme: TextMateTheme) {
        self.theme = theme
    }

    func getDefaults() -> StyleAttributes { theme.defaults }
    func themeMatch(_ scopePath: ScopeStack) -> StyleAttributes? { theme.match(scopePath) }
}

public struct TokenizeLineResult {
    /// Pairs of (startIndex, metadata), with UTF-16 start offsets.
    public var tokens: [UInt32]
    public var ruleStack: StateStack
    public var stoppedEarly: Bool
}

public final class Grammar: RuleRegistry {
    private let rootScopeName: String
    private let balancedBracketSelectors: BalancedBracketSelectors?
    private let basicScopeAttributesProvider: BasicScopeAttributesProvider
    private var rootId = -1
    private var lastRuleId = 0
    private var ruleId2desc: [Rule?] = [nil]
    private var includedGrammars: [String: RawGrammar] = [:]
    private weak var grammarRepository: GrammarRepository?
    private let grammar: RawGrammar
    private var injections: [Injection]?
    /// Shiki assigns the language name to the grammar.
    public var name: String?

    var themeProvider: ThemeProvider { grammarRepository!.themeProvider }

    init(
        rootScopeName: String,
        grammar: RawGrammar,
        initialLanguage: Int,
        balancedBracketSelectors: BalancedBracketSelectors?,
        grammarRepository: GrammarRepository
    ) {
        self.rootScopeName = rootScopeName
        self.balancedBracketSelectors = balancedBracketSelectors
        basicScopeAttributesProvider = BasicScopeAttributesProvider(initialLanguageId: initialLanguage)
        self.grammarRepository = grammarRepository
        self.grammar = grammar.initGrammar(base: nil)
    }

    func getMetadataForScope(_ scope: String?) -> BasicScopeAttributes {
        basicScopeAttributesProvider.getBasicScopeAttributes(scope)
    }

    private func collectInjections() -> [Injection] {
        var result: [Injection] = []
        func collect(_ selector: String, _ rule: RawRule, _ repository: [String: RawRule]) {
            let matchers = createMatchers(selector, nameMatcher)
            let ruleId = RuleFactory.getCompiledRuleId(rule, self, repository)
            for matcher in matchers {
                result.append(Injection(debugSelector: selector, matcher: matcher.matcher, priority: matcher.priority, ruleId: ruleId))
            }
        }
        if let rawInjections = grammar.injections {
            for (expression, rule) in rawInjections {
                collect(expression, rule, grammar.repository)
            }
        }
        if let injectionScopeNames = grammarRepository?.injections(rootScopeName) {
            for injectionScopeName in injectionScopeNames {
                if let injectionGrammar = getExternalGrammar(injectionScopeName, nil),
                   let selector = injectionGrammar.injectionSelector
                {
                    collect(selector, injectionGrammar.selfRuleForInjection, injectionGrammar.repository)
                }
            }
        }
        // Stable sort by priority.
        return result.enumerated().sorted { lhs, rhs in
            lhs.element.priority != rhs.element.priority
                ? lhs.element.priority < rhs.element.priority
                : lhs.offset < rhs.offset
        }.map(\.element)
    }

    func getInjections() -> [Injection] {
        if let injections { return injections }
        let collected = collectInjections()
        injections = collected
        return collected
    }

    func registerRule<T: Rule>(_ factory: (Int) -> T) -> T {
        lastRuleId += 1
        let id = lastRuleId
        if ruleId2desc.count <= id {
            ruleId2desc.append(contentsOf: repeatElement(nil, count: id - ruleId2desc.count + 1))
        }
        let result = factory(id)
        ruleId2desc[id] = result
        return result
    }

    func getRule(_ ruleId: Int) -> Rule {
        ruleId2desc[ruleId]!
    }

    /// Returns nil for rules that are still being constructed (recursive
    /// grammars), like the JavaScript implementation's `undefined`.
    func getRuleIfExists(_ ruleId: Int) -> Rule? {
        ruleId < ruleId2desc.count ? ruleId2desc[ruleId] : nil
    }

    func getExternalGrammar(_ scopeName: String, _ repository: [String: RawRule]?) -> RawGrammar? {
        if let included = includedGrammars[scopeName] { return included }
        guard let rawIncludedGrammar = grammarRepository?.lookup(scopeName) else { return nil }
        let initialized = rawIncludedGrammar.initGrammar(base: repository?["$base"])
        includedGrammars[scopeName] = initialized
        return initialized
    }

    /// Tokenizes a line, returning binary tokens (vscode-textmate
    /// `tokenizeLine2`). `lineText` is the line without its line ending.
    public func tokenizeLine2(_ lineText: String, _ prevState: StateStack?, timeLimit: Double = 0) -> TokenizeLineResult {
        let r = tokenize(lineText, prevState, timeLimit)
        return TokenizeLineResult(
            tokens: r.lineTokens.getBinaryResult(r.ruleStack, r.lineLength),
            ruleStack: r.ruleStack,
            stoppedEarly: r.stoppedEarly
        )
    }

    /// Tokenizes a line once for the active theme and resolves the binary
    /// tokens of `extraThemes` from the same scopes. Rule matching does not
    /// depend on the theme, so each extra result equals a separate
    /// `tokenizeLine2` under that theme.
    func tokenizeLine2(_ lineText: String, _ prevState: StateStack?, timeLimit: Double = 0, extraThemes: [ThemeAttributeResolver]) -> (primary: TokenizeLineResult, extra: [[UInt32]]) {
        let r = tokenize(lineText, prevState, timeLimit, recordScopes: true)
        let scopeTokens = r.lineTokens.scopeTokens ?? []
        let primary = TokenizeLineResult(
            tokens: r.lineTokens.getBinaryResult(r.ruleStack, r.lineLength),
            ruleStack: r.ruleStack,
            stoppedEarly: r.stoppedEarly
        )
        let extra = extraThemes.map { resolver -> [UInt32] in
            var tokens: [UInt32] = []
            tokens.reserveCapacity(scopeTokens.count * 2)
            for (start, scopes) in scopeTokens {
                let metadata = r.lineTokens.applyBalancedBrackets(resolver.attributes(scopes), scopes)
                if let last = tokens.last, last == metadata { continue }
                tokens.append(UInt32(truncatingIfNeeded: start))
                tokens.append(metadata)
            }
            // `getBinaryResult`.
            if tokens.count >= 2, tokens[tokens.count - 2] == UInt32(truncatingIfNeeded: r.lineLength - 1) {
                tokens.removeLast(2)
            }
            if tokens.isEmpty {
                let scopes = r.ruleStack.contentNameScopesList
                tokens = [0, r.lineTokens.applyBalancedBrackets(resolver.attributes(scopes), scopes)]
            }
            return tokens
        }
        return (primary, extra)
    }

    /// Resolves token attributes under another theme.
    func attributeResolver(for theme: TextMateTheme) -> ThemeAttributeResolver {
        let raw = basicScopeAttributesProvider.defaultAttributes
        let defaults = theme.defaults
        let defaultMetadata = EncodedTokenMetadata.set(
            0,
            languageId: raw.languageId,
            tokenType: raw.tokenType,
            containsBalancedBrackets: nil,
            fontStyle: defaults.fontStyle,
            foreground: defaults.foregroundId,
            background: defaults.backgroundId
        )
        return ThemeAttributeResolver(theme: theme, defaultMetadata: defaultMetadata) { [unowned self] scope in
            self.getMetadataForScope(scope)
        }
    }

    private func tokenize(_ lineText: String, _ prevState: StateStack?, _ timeLimit: Double, recordScopes: Bool = false) -> (lineLength: Int, lineTokens: LineTokens, ruleStack: StateStack, stoppedEarly: Bool) {
        if rootId == -1 {
            rootId = RuleFactory.getCompiledRuleId(grammar.selfRule, self, grammar.repository)
            _ = getInjections()
        }
        var isFirstLine: Bool
        let state: StateStack
        if let prevState, prevState !== StateStack.initial {
            isFirstLine = false
            prevState.reset()
            state = prevState
        } else {
            isFirstLine = true
            let rawDefaultMetadata = basicScopeAttributesProvider.defaultAttributes
            let defaultStyle = themeProvider.getDefaults()
            let defaultMetadata = EncodedTokenMetadata.set(
                0,
                languageId: rawDefaultMetadata.languageId,
                tokenType: rawDefaultMetadata.tokenType,
                containsBalancedBrackets: nil,
                fontStyle: defaultStyle.fontStyle,
                foreground: defaultStyle.foregroundId,
                background: defaultStyle.backgroundId
            )
            let rootScopeName = getRule(rootId).getName(nil, nil)
            let scopeList: AttributedScopeStack
            if let rootScopeName, !rootScopeName.isEmpty {
                scopeList = AttributedScopeStack.createRootAndLookUpScopeName(rootScopeName, defaultMetadata, self)
            } else {
                scopeList = AttributedScopeStack.createRoot("unknown", defaultMetadata)
            }
            state = StateStack(nil, rootId, -1, -1, false, nil, scopeList, scopeList)
        }
        let onigLineText = OnigString(lineText + "\n")
        let lineLength = onigLineText.utf16Length
        let lineTokens = LineTokens(balancedBracketSelectors: balancedBracketSelectors)
        if recordScopes { lineTokens.scopeTokens = [] }
        let r = tokenizeString(self, onigLineText, isFirstLine, 0, state, lineTokens, checkWhileConditions: true, timeLimit: timeLimit)
        return (lineLength, lineTokens, r.stack, r.stoppedEarly)
    }
}

extension RawGrammar {
    /// vscode-textmate passes the (uncloned-by-initGrammar) injection grammar
    /// object itself as the injection rule: a rule with the grammar's
    /// patterns and repository.
    var selfRuleForInjection: RawRule {
        selfRule
    }
}

// MARK: - tokenizeString

private func tokenizeString(
    _ grammar: Grammar,
    _ lineText: OnigString,
    _ isFirstLine: Bool,
    _ linePos: Int,
    _ stack: StateStack,
    _ lineTokens: LineTokens,
    checkWhileConditions: Bool,
    timeLimit: Double
) -> (stack: StateStack, stoppedEarly: Bool) {
    let lineLength = lineText.utf16Length
    var stop = false
    var anchorPosition = -1
    var stack = stack
    var linePos = linePos
    var isFirstLine = isFirstLine

    if checkWhileConditions {
        let whileCheckResult = checkWhileConditionsFn(grammar, lineText, isFirstLine, linePos, stack, lineTokens)
        stack = whileCheckResult.stack
        linePos = whileCheckResult.linePos
        isFirstLine = whileCheckResult.isFirstLine
        anchorPosition = whileCheckResult.anchorPosition
    }

    let startTime = Date().timeIntervalSince1970 * 1000
    while !stop {
        if timeLimit != 0 {
            let elapsed = Date().timeIntervalSince1970 * 1000 - startTime
            if elapsed > timeLimit {
                return (stack, true)
            }
        }
        scanNext()
    }
    return (stack, false)

    func scanNext() {
        guard let r = matchRuleOrInjections(grammar, lineText, isFirstLine, linePos, stack, anchorPosition) else {
            lineTokens.produce(stack, lineLength)
            stop = true
            return
        }
        let captureIndices = r.captureIndices
        let matchedRuleId = r.matchedRuleId
        let hasAdvanced = !captureIndices.isEmpty ? captureIndices[0].end > linePos : false

        if matchedRuleId == endRuleId {
            // We matched the `end` for this rule => pop it
            let poppedRule = stack.getRule(grammar) as! BeginEndRule
            lineTokens.produce(stack, captureIndices[0].start)
            stack = stack.withContentNameScopesList(stack.nameScopesList)
            handleCaptures(grammar, lineText, isFirstLine, stack, lineTokens, poppedRule.endCaptures, captureIndices)
            lineTokens.produce(stack, captureIndices[0].end)

            // pop
            let popped = stack
            stack = stack.parent!
            anchorPosition = popped.anchorPos

            if !hasAdvanced, popped.enterPos == linePos {
                // Grammar pushed & popped a rule without advancing
                stack = popped
                lineTokens.produce(stack, lineLength)
                stop = true
                return
            }
        } else {
            // We matched a rule!
            let rule = grammar.getRule(matchedRuleId)
            lineTokens.produce(stack, captureIndices[0].start)
            let beforePush = stack
            // push it on the stack rule
            let scopeName = rule.getName(lineText, captureIndices)
            let nameScopesList = stack.contentNameScopesList!.pushAttributed(scopeName, grammar)
            stack = stack.push(
                matchedRuleId,
                linePos,
                anchorPosition,
                captureIndices[0].end == lineLength,
                nil,
                nameScopesList,
                nameScopesList
            )

            if let pushedRule = rule as? BeginEndRule {
                handleCaptures(grammar, lineText, isFirstLine, stack, lineTokens, pushedRule.beginCaptures, captureIndices)
                lineTokens.produce(stack, captureIndices[0].end)
                anchorPosition = captureIndices[0].end

                let contentName = pushedRule.getContentName(lineText, captureIndices)
                let contentNameScopesList = nameScopesList.pushAttributed(contentName, grammar)
                stack = stack.withContentNameScopesList(contentNameScopesList)

                if pushedRule.endHasBackReferences {
                    stack = stack.withEndRule(pushedRule.getEndWithResolvedBackReferences(lineText, captureIndices))
                }

                if !hasAdvanced, beforePush.hasSameRuleAs(stack) {
                    // Grammar pushed the same rule without advancing
                    stack = stack.pop()!
                    lineTokens.produce(stack, lineLength)
                    stop = true
                    return
                }
            } else if let pushedRule = rule as? BeginWhileRule {
                handleCaptures(grammar, lineText, isFirstLine, stack, lineTokens, pushedRule.beginCaptures, captureIndices)
                lineTokens.produce(stack, captureIndices[0].end)
                anchorPosition = captureIndices[0].end
                let contentName = pushedRule.getContentName(lineText, captureIndices)
                let contentNameScopesList = nameScopesList.pushAttributed(contentName, grammar)
                stack = stack.withContentNameScopesList(contentNameScopesList)

                if pushedRule.whileHasBackReferences {
                    stack = stack.withEndRule(pushedRule.getWhileWithResolvedBackReferences(lineText, captureIndices))
                }

                if !hasAdvanced, beforePush.hasSameRuleAs(stack) {
                    stack = stack.pop()!
                    lineTokens.produce(stack, lineLength)
                    stop = true
                    return
                }
            } else {
                let matchingRule = rule as! MatchRule
                handleCaptures(grammar, lineText, isFirstLine, stack, lineTokens, matchingRule.captures, captureIndices)
                lineTokens.produce(stack, captureIndices[0].end)

                // pop rule immediately since it is a MatchRule
                stack = stack.pop()!

                if !hasAdvanced {
                    // Grammar is not advancing, nor is it pushing/popping
                    stack = stack.safePop()
                    lineTokens.produce(stack, lineLength)
                    stop = true
                    return
                }
            }
        }

        if captureIndices[0].end > linePos {
            // Advance stream
            linePos = captureIndices[0].end
            isFirstLine = false
        }
    }
}

private func checkWhileConditionsFn(
    _ grammar: Grammar,
    _ lineText: OnigString,
    _ isFirstLine: Bool,
    _ linePos: Int,
    _ stack: StateStack,
    _ lineTokens: LineTokens
) -> (stack: StateStack, linePos: Int, anchorPosition: Int, isFirstLine: Bool) {
    var anchorPosition = stack.beginRuleCapturedEOL ? 0 : -1
    var linePos = linePos
    var isFirstLine = isFirstLine
    var stack = stack

    var whileRules: [(rule: BeginWhileRule, stack: StateStack)] = []
    var node: StateStack? = stack
    while let current = node {
        if let rule = current.getRule(grammar) as? BeginWhileRule {
            whileRules.append((rule, current))
        }
        node = current.pop()
    }

    while let whileRule = whileRules.popLast() {
        let ruleScanner = whileRule.rule.compileWhileAG(
            grammar,
            whileRule.stack.endRule,
            allowA: isFirstLine,
            allowG: linePos == anchorPosition
        )
        if let r = ruleScanner.findNextMatch(lineText, linePos, []) {
            if r.ruleId != whileRuleId {
                // we shouldn't end up here
                stack = whileRule.stack.pop()!
                break
            }
            if !r.captureIndices.isEmpty {
                lineTokens.produce(whileRule.stack, r.captureIndices[0].start)
                handleCaptures(grammar, lineText, isFirstLine, whileRule.stack, lineTokens, whileRule.rule.whileCaptures, r.captureIndices)
                lineTokens.produce(whileRule.stack, r.captureIndices[0].end)
                anchorPosition = r.captureIndices[0].end
                if r.captureIndices[0].end > linePos {
                    linePos = r.captureIndices[0].end
                    isFirstLine = false
                }
            }
        } else {
            stack = whileRule.stack.pop()!
            break
        }
    }
    return (stack, linePos, anchorPosition, isFirstLine)
}

private struct MatchResult {
    var captureIndices: [OnigCaptureIndex]
    var matchedRuleId: Int
    var priorityMatch = false
}

private func matchRuleOrInjections(
    _ grammar: Grammar,
    _ lineText: OnigString,
    _ isFirstLine: Bool,
    _ linePos: Int,
    _ stack: StateStack,
    _ anchorPosition: Int
) -> MatchResult? {
    // Look for normal grammar rule
    let matchResult = matchRule(grammar, lineText, isFirstLine, linePos, stack, anchorPosition)

    // Look for injected rules
    let injections = grammar.getInjections()
    if injections.isEmpty {
        return matchResult
    }
    guard let injectionResult = matchInjections(injections, grammar, lineText, isFirstLine, linePos, stack, anchorPosition) else {
        return matchResult
    }
    guard let matchResult else { return injectionResult }

    // Decide if `matchResult` or `injectionResult` should win
    let matchResultScore = matchResult.captureIndices[0].start
    let injectionResultScore = injectionResult.captureIndices[0].start
    if injectionResultScore < matchResultScore || (injectionResult.priorityMatch && injectionResultScore == matchResultScore) {
        return injectionResult
    }
    return matchResult
}

private func matchRule(
    _ grammar: Grammar,
    _ lineText: OnigString,
    _ isFirstLine: Bool,
    _ linePos: Int,
    _ stack: StateStack,
    _ anchorPosition: Int
) -> MatchResult? {
    let rule = stack.getRule(grammar)
    let ruleScanner = rule.compileAG(grammar, stack.endRule, allowA: isFirstLine, allowG: linePos == anchorPosition)
    guard let r = ruleScanner.findNextMatch(lineText, linePos, []) else { return nil }
    return MatchResult(captureIndices: r.captureIndices, matchedRuleId: r.ruleId)
}

private func matchInjections(
    _ injections: [Injection],
    _ grammar: Grammar,
    _ lineText: OnigString,
    _ isFirstLine: Bool,
    _ linePos: Int,
    _ stack: StateStack,
    _ anchorPosition: Int
) -> MatchResult? {
    // The lower the better
    var bestMatchRating = Int.max
    var bestMatchCaptureIndices: [OnigCaptureIndex]?
    var bestMatchRuleId = 0
    var bestMatchResultPriority = 0

    let scopes = stack.contentNameScopesList!.getScopeNames()
    for injection in injections {
        if !injection.matcher(scopes) {
            // injection selector doesn't match stack
            continue
        }
        let rule = grammar.getRule(injection.ruleId)
        let ruleScanner = rule.compileAG(grammar, nil, allowA: isFirstLine, allowG: linePos == anchorPosition)
        guard let matchResult = ruleScanner.findNextMatch(lineText, linePos, []) else { continue }
        let matchRating = matchResult.captureIndices[0].start
        if matchRating >= bestMatchRating {
            // Injections are sorted by priority, so the previous injection had
            // a better or equal priority
            continue
        }
        bestMatchRating = matchRating
        bestMatchCaptureIndices = matchResult.captureIndices
        bestMatchRuleId = matchResult.ruleId
        bestMatchResultPriority = injection.priority
        if bestMatchRating == linePos {
            // No more need to look at the rest of the injections.
            break
        }
    }
    guard let bestMatchCaptureIndices else { return nil }
    return MatchResult(
        captureIndices: bestMatchCaptureIndices,
        matchedRuleId: bestMatchRuleId,
        priorityMatch: bestMatchResultPriority == -1
    )
}

private final class LocalStackElement {
    let scopes: AttributedScopeStack
    let endPos: Int

    init(_ scopes: AttributedScopeStack, _ endPos: Int) {
        self.scopes = scopes
        self.endPos = endPos
    }
}

private func handleCaptures(
    _ grammar: Grammar,
    _ lineText: OnigString,
    _ isFirstLine: Bool,
    _ stack: StateStack,
    _ lineTokens: LineTokens,
    _ captures: [CaptureRule?],
    _ captureIndices: [OnigCaptureIndex]
) {
    if captures.isEmpty { return }
    let len = min(captures.count, captureIndices.count)
    var localStack: [LocalStackElement] = []
    let maxEnd = captureIndices[0].end

    for i in 0 ..< len {
        guard let captureRule = captures[i] else { continue }
        let captureIndex = captureIndices[i]
        if captureIndex.length == 0 {
            // Nothing really captured
            continue
        }
        if captureIndex.start > maxEnd {
            // Capture going beyond consumed string
            break
        }

        // pop captures while needed
        while let last = localStack.last, last.endPos <= captureIndex.start {
            // pop!
            lineTokens.produceFromScopes(last.scopes, last.endPos)
            localStack.removeLast()
        }

        if let last = localStack.last {
            lineTokens.produceFromScopes(last.scopes, captureIndex.start)
        } else {
            lineTokens.produce(stack, captureIndex.start)
        }

        if captureRule.retokenizeCapturedWithRuleId != 0 {
            // the capture requires additional matching
            let scopeName = captureRule.getName(lineText, captureIndices)
            let nameScopesList = stack.contentNameScopesList!.pushAttributed(scopeName, grammar)
            let contentName = captureRule.getContentName(lineText, captureIndices)
            let contentNameScopesList = nameScopesList.pushAttributed(contentName, grammar)

            let stackClone = stack.push(
                captureRule.retokenizeCapturedWithRuleId,
                captureIndex.start,
                -1,
                false,
                nil,
                nameScopesList,
                contentNameScopesList
            )
            let onigSubStr = OnigString(lineText.substring(0, captureIndex.end))
            _ = tokenizeString(
                grammar,
                onigSubStr,
                isFirstLine && captureIndex.start == 0,
                captureIndex.start,
                stackClone,
                lineTokens,
                checkWhileConditions: false,
                timeLimit: 0
            )
            continue
        }

        if let captureRuleScopeName = captureRule.getName(lineText, captureIndices) {
            // push
            let base = localStack.last?.scopes ?? stack.contentNameScopesList!
            let captureRuleScopesList = base.pushAttributed(captureRuleScopeName, grammar)
            localStack.append(LocalStackElement(captureRuleScopesList, captureIndex.end))
        }
    }

    while let last = localStack.popLast() {
        // pop!
        lineTokens.produceFromScopes(last.scopes, last.endPos)
    }
}
