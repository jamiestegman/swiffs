// Port of Shiki's primitive highlighter (`@shikijs/primitive`):
// language/theme registries, `codeToTokensBase`, `codeToTokensWithThemes`
// and `alignThemesTokenization`.

import Foundation

/// A language grammar registration (Shiki `LanguageRegistration`).
public final class LanguageRegistration {
    public let name: String
    public let scopeName: String
    public let displayName: String?
    public let aliases: [String]
    public let embeddedLangs: [String]
    public let embeddedLangsLazy: [String]
    public let injectTo: [String]
    public let balancedBracketSelectors: [String]?
    public let unbalancedBracketSelectors: [String]?
    let grammar: RawGrammar

    public init(json: [String: Any]) throws {
        grammar = try RawGrammar(json: json)
        guard let name = json["name"] as? String else {
            throw DiffsHighlightError("Language registration is missing a name")
        }
        self.name = name
        scopeName = grammar.scopeName
        displayName = json["displayName"] as? String
        aliases = json["aliases"] as? [String] ?? []
        embeddedLangs = (json["embeddedLangs"] as? [String]) ?? (json["embeddedLanguages"] as? [String]) ?? []
        embeddedLangsLazy = json["embeddedLangsLazy"] as? [String] ?? []
        injectTo = json["injectTo"] as? [String] ?? []
        balancedBracketSelectors = json["balancedBracketSelectors"] as? [String]
        unbalancedBracketSelectors = json["unbalancedBracketSelectors"] as? [String]
    }
}

/// A themed token (Shiki `ThemedToken`), with UTF-16 offsets.
public struct ThemedToken: Hashable, Sendable {
    public var content: String
    /// UTF-16 offset of the token in the full input.
    public var offset: Int
    public var color: String?
    public var fontStyle: FontStyle

    public init(content: String, offset: Int, color: String? = nil, fontStyle: FontStyle = []) {
        self.content = content
        self.offset = offset
        self.color = color
        self.fontStyle = fontStyle
    }
}

/// A token highlighted with several themes at once (Shiki
/// `ThemedTokenWithVariants`).
public struct ThemedTokenWithVariants: Hashable, Sendable {
    public struct Variant: Hashable, Sendable {
        public var color: String?
        public var fontStyle: FontStyle
    }

    public var content: String
    public var offset: Int
    /// Keyed by the theme slot (e.g. `dark` / `light`).
    public var variants: [String: Variant]
}

public struct TokenizeOptions: Sendable {
    /// Lines at or over this length (UTF-16 units) are not tokenized; 0
    /// disables the limit.
    public var tokenizeMaxLineLength: Int
    /// Time limit per line in milliseconds; 0 disables the limit.
    public var tokenizeTimeLimit: Double
    public var colorReplacements: [String: String]

    public init(tokenizeMaxLineLength: Int = 0, tokenizeTimeLimit: Double = 500, colorReplacements: [String: String] = [:]) {
        self.tokenizeMaxLineLength = tokenizeMaxLineLength
        self.tokenizeTimeLimit = tokenizeTimeLimit
        self.colorReplacements = colorReplacements
    }
}

/// Check if the language is plaintext that is ignored by Shiki.
public func isPlainLang(_ lang: String?) -> Bool {
    guard let lang, !lang.isEmpty else { return true }
    return ["plaintext", "txt", "text", "plain"].contains(lang)
}

/// Check if the language is specially handled or bypassed by Shiki.
public func isSpecialLang(_ lang: String?) -> Bool {
    lang == "ansi" || isPlainLang(lang)
}

/// Shiki `splitLines`: returns (line, UTF-16 offset) pairs.
public func shikiSplitLines(_ code: String, preserveEnding: Bool = false) -> [(line: String, offset: Int)] {
    if code.isEmpty { return [("", 0)] }
    var lines: [(String, Int)] = []
    let units = Array(code.utf16)
    var start = 0
    var offset = 0
    var i = 0
    while i < units.count {
        if units[i] == 0x0A {
            var contentEnd = i
            if contentEnd > start, units[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            let line = preserveEnding
                ? String(decoding: units[start ... i], as: UTF16.self)
                : String(decoding: units[start ..< contentEnd], as: UTF16.self)
            lines.append((line, offset))
            offset += i + 1 - start
            start = i + 1
        }
        i += 1
    }
    lines.append((String(decoding: units[start...], as: UTF16.self), offset))
    return lines
}

/// The Shiki highlighter: owns loaded languages and themes and tokenizes
/// code. Not thread safe; use one instance per thread/actor.
public final class Highlighter {
    private var langs: [String: LanguageRegistration] = [:]
    private var scopeToLang: [String: LanguageRegistration] = [:]
    private var injectionsByScope: [String: [String]] = [:]
    private var alias: [String: String] = [:]
    private var resolvedGrammars: [String: Grammar] = [:]
    private var themes: [String: ThemeRegistration] = [:]
    private var textmateThemes: [String: TextMateTheme] = [:]
    private var lastTheme: String?
    private var syncRegistry: SyncRegistry!

    public init() {
        syncRegistry = SyncRegistry(
            theme: TextMateTheme.createFromRawTheme([]),
            lookupGrammar: { [unowned self] scopeName in self.scopeToLang[scopeName]?.grammar },
            lookupInjections: { [unowned self] scopeName in self.getInjections(scopeName) }
        )
    }

    // MARK: Languages

    private func addLanguage(_ lang: LanguageRegistration) {
        langs[lang.name] = lang
        for alias in lang.aliases {
            langs[alias] = lang
        }
        scopeToLang[lang.scopeName] = lang
        for target in lang.injectTo {
            injectionsByScope[target, default: []].append(lang.scopeName)
        }
    }

    private func getInjections(_ scopeName: String) -> [String] {
        let parts = scopeName.split(separator: ".", omittingEmptySubsequences: false)
        var injections: [String] = []
        for i in 1 ... max(parts.count, 1) {
            let sub = parts.prefix(i).joined(separator: ".")
            injections.append(contentsOf: injectionsByScope[sub] ?? [])
        }
        return injections
    }

    public func resolveLangAlias(_ name: String) -> String {
        var name = name
        var seen: Set<String> = [name]
        while let next = alias[name] {
            name = next
            if seen.contains(name) { break }
            seen.insert(name)
        }
        return name
    }

    public func getGrammar(_ name: String) -> Grammar? {
        resolvedGrammars[resolveLangAlias(name)]
    }

    /// Loads languages (and makes their grammars available for embedding).
    /// Embedded languages must be passed in the same call or loaded earlier.
    public func loadLanguages(_ newLangs: [LanguageRegistration]) {
        for lang in newLangs {
            addLanguage(lang)
        }
        for lang in newLangs {
            loadLanguage(lang)
        }
    }

    private func loadLanguage(_ lang: LanguageRegistration) {
        if getGrammar(lang.name) != nil { return }
        let embeddedLazilyBy = langs.values.filter { $0.embeddedLangsLazy.contains(lang.name) }
        addLanguage(lang)
        let selectors = BalancedBracketSelectors(
            balancedBracketScopes: lang.balancedBracketSelectors ?? ["*"],
            unbalancedBracketScopes: lang.unbalancedBracketSelectors ?? []
        )
        guard let grammar = syncRegistry.grammarForScopeName(lang.scopeName, initialLanguage: 1, balancedBracketSelectors: selectors) else {
            return
        }
        grammar.name = lang.name
        resolvedGrammars[lang.name] = grammar
        for alias in lang.aliases {
            self.alias[alias] = lang.name
        }
        // Grammars that lazily embed this language must be recreated so they
        // pick it up.
        var reloaded: Set<String> = []
        for embedder in embeddedLazilyBy where embedder !== lang && !reloaded.contains(embedder.name) {
            reloaded.insert(embedder.name)
            resolvedGrammars.removeValue(forKey: embedder.name)
            syncRegistry.removeGrammar(embedder.scopeName)
            loadLanguage(embedder)
        }
    }

    public var loadedLanguages: [String] {
        Array(Set(Array(resolvedGrammars.keys) + Array(alias.keys)))
    }

    public func isLanguageLoaded(_ name: String) -> Bool {
        getGrammar(name) != nil
    }

    // MARK: Themes

    public func loadTheme(_ theme: ThemeRegistration) {
        themes[theme.name] = theme
        textmateThemes.removeValue(forKey: theme.name)
        if lastTheme == theme.name { lastTheme = nil }
    }

    public func getTheme(_ name: String) throws -> ThemeRegistration {
        if name == "none" { return .none }
        guard let theme = themes[name] else {
            throw DiffsHighlightError("Theme `\(name)` not found, you may need to load it first")
        }
        return theme
    }

    public var loadedThemes: [String] { Array(themes.keys) }

    public func isThemeLoaded(_ name: String) -> Bool { themes[name] != nil }

    /// Activates a theme, returning it and the color map.
    public func setTheme(_ name: String) throws -> (theme: ThemeRegistration, colorMap: [String]) {
        let theme = try getTheme(name)
        if lastTheme != name {
            let textmateTheme: TextMateTheme
            if let cached = textmateThemes[name] {
                textmateTheme = cached
            } else {
                textmateTheme = TextMateTheme.createFromRawTheme(theme.settings)
                textmateThemes[name] = textmateTheme
            }
            syncRegistry.setTheme(textmateTheme)
            lastTheme = name
        }
        return (theme, syncRegistry.getColorMap())
    }

    // MARK: Tokenization

    /// Shiki `codeToTokensBase`.
    public func codeToTokensBase(_ code: String, lang: String, theme themeName: String, options: TokenizeOptions = TokenizeOptions()) throws -> [[ThemedToken]] {
        if isPlainLang(resolveLangAlias(lang)) || themeName == "none" {
            return shikiSplitLines(code).map { [ThemedToken(content: $0.line, offset: $0.offset)] }
        }
        let (theme, colorMap) = try setTheme(themeName)
        guard let grammar = getGrammar(lang) else {
            throw DiffsHighlightError("Language `\(lang)` not found, you may need to load it first")
        }
        return tokenizeWithTheme(code, grammar: grammar, theme: theme, colorMap: colorMap, options: options).tokens
    }

    /// `codeToTokensBase` with `grammarState`: starts from `grammarState`
    /// (the initial state when nil) and returns the state after the last
    /// line. Plain languages have no grammar state.
    public func codeToTokensBase(
        _ code: String,
        lang: String,
        theme themeName: String,
        options: TokenizeOptions = TokenizeOptions(),
        grammarState: StateStack?
    ) throws -> (tokens: [[ThemedToken]], grammarState: StateStack?) {
        if isPlainLang(resolveLangAlias(lang)) || themeName == "none" {
            return (shikiSplitLines(code).map { [ThemedToken(content: $0.line, offset: $0.offset)] }, nil)
        }
        let (theme, colorMap) = try setTheme(themeName)
        guard let grammar = getGrammar(lang) else {
            throw DiffsHighlightError("Language `\(lang)` not found, you may need to load it first")
        }
        let result = tokenizeWithTheme(code, grammar: grammar, theme: theme, colorMap: colorMap, options: options, initialState: grammarState ?? .initial)
        return (result.tokens, result.stateStack)
    }

    func tokenizeWithTheme(
        _ code: String,
        grammar: Grammar,
        theme: ThemeRegistration,
        colorMap: [String],
        options: TokenizeOptions,
        initialState: StateStack = .initial
    ) -> (tokens: [[ThemedToken]], stateStack: StateStack) {
        var colorReplacements = theme.colorReplacements
        for (key, value) in options.colorReplacements {
            colorReplacements[key] = value
        }
        let lines = shikiSplitLines(code)
        var stateStack = initialState
        var final: [[ThemedToken]] = []
        final.reserveCapacity(lines.count)
        for (line, lineOffset) in lines {
            if line.isEmpty {
                final.append([])
                continue
            }
            let lineLength = line.utf16.count
            if options.tokenizeMaxLineLength > 0, lineLength >= options.tokenizeMaxLineLength {
                final.append([ThemedToken(content: line, offset: lineOffset, color: "", fontStyle: [])])
                continue
            }
            let result = grammar.tokenizeLine2(line, stateStack, timeLimit: options.tokenizeTimeLimit)
            final.append(Self.themedTokens(result.tokens, units: Array(line.utf16), lineOffset: lineOffset, colorMap: colorMap, colorReplacements: colorReplacements))
            stateStack = result.ruleStack
        }
        return (final, stateStack)
    }

    /// Shiki's per-line conversion of binary tokens to themed tokens.
    private static func themedTokens(_ tokens: [UInt32], units: [UInt16], lineOffset: Int, colorMap: [String], colorReplacements: [String: String]) -> [ThemedToken] {
        let lineLength = units.count
        let tokensLength = tokens.count / 2
        var actual: [ThemedToken] = []
        actual.reserveCapacity(tokensLength)
        for j in 0 ..< tokensLength {
            let startIndex = Int(tokens[2 * j])
            let nextStartIndex = j + 1 < tokensLength ? Int(tokens[2 * j + 2]) : lineLength
            if startIndex == nextStartIndex { continue }
            let metadata = tokens[2 * j + 1]
            let colorId = EncodedTokenMetadata.getForeground(metadata)
            let rawColor: String? = colorId < colorMap.count && !colorMap[colorId].isEmpty ? colorMap[colorId] : nil
            let color = applyColorReplacements(rawColor, colorReplacements)
            let fontStyle = FontStyle(rawValue: EncodedTokenMetadata.getFontStyle(metadata))
            let start = min(startIndex, units.count)
            let end = min(max(nextStartIndex, start), units.count)
            actual.append(ThemedToken(
                content: String(decoding: units[start ..< end], as: UTF16.self),
                offset: lineOffset + startIndex,
                color: color,
                fontStyle: fontStyle
            ))
        }
        return actual
    }

    /// `tokenizeWithTheme` for several themes from one tokenization: the
    /// grammar runs once under the first theme, and the other themes resolve
    /// colors from the same scopes. Equivalent to one run per theme.
    func tokenizeWithThemes(_ code: String, grammar: Grammar, themeNames: [String], options: TokenizeOptions) throws -> [[[ThemedToken]]] {
        guard let firstName = themeNames.first else { return [] }
        var entries: [(theme: ThemeRegistration, textmate: TextMateTheme, replacements: [String: String])] = []
        for name in themeNames {
            let theme = try getTheme(name)
            let textmate: TextMateTheme
            if let cached = textmateThemes[name] {
                textmate = cached
            } else {
                textmate = TextMateTheme.createFromRawTheme(theme.settings)
                textmateThemes[name] = textmate
            }
            var replacements = theme.colorReplacements
            for (key, value) in options.colorReplacements { replacements[key] = value }
            entries.append((theme, textmate, replacements))
        }
        let (_, primaryColorMap) = try setTheme(firstName)
        let resolvers = entries.dropFirst().map { grammar.attributeResolver(for: $0.textmate) }
        let colorMaps = [primaryColorMap] + resolvers.map(\.colorMap)
        let lines = shikiSplitLines(code)
        var results: [[[ThemedToken]]] = entries.map { _ in [] }
        var stateStack = StateStack.initial
        for (line, lineOffset) in lines {
            if line.isEmpty {
                for index in results.indices { results[index].append([]) }
                continue
            }
            if options.tokenizeMaxLineLength > 0, line.utf16.count >= options.tokenizeMaxLineLength {
                for index in results.indices { results[index].append([ThemedToken(content: line, offset: lineOffset, color: "", fontStyle: [])]) }
                continue
            }
            let result = grammar.tokenizeLine2(line, stateStack, timeLimit: options.tokenizeTimeLimit, extraThemes: Array(resolvers))
            let units = Array(line.utf16)
            let perTheme = [result.primary.tokens] + result.extra
            for index in results.indices {
                results[index].append(Self.themedTokens(perTheme[index], units: units, lineOffset: lineOffset, colorMap: colorMaps[index], colorReplacements: entries[index].replacements))
            }
            stateStack = result.primary.ruleStack
        }
        return results
    }

    /// Shiki `codeToTokensWithThemes`: tokenizes with each theme and aligns
    /// the token boundaries. `themes` maps slot names (e.g. `dark`, `light`)
    /// to theme names, in order.
    public func codeToTokensWithThemes(
        _ code: String,
        lang: String,
        themes: [(slot: String, theme: String)],
        options: TokenizeOptions = TokenizeOptions()
    ) throws -> [[ThemedTokenWithVariants]] {
        let themed: [[[ThemedToken]]]
        if !isPlainLang(resolveLangAlias(lang)), !themes.contains(where: { $0.theme == "none" }), let grammar = getGrammar(lang) {
            themed = try tokenizeWithThemes(code, grammar: grammar, themeNames: themes.map(\.theme), options: options)
        } else {
            themed = try themes.map { entry in
                try codeToTokensBase(code, lang: lang, theme: entry.theme, options: options)
            }
        }
        let aligned = alignThemesTokenization(themed)
        guard let first = aligned.first else { return [] }
        return first.enumerated().map { lineIndex, line in
            line.enumerated().map { tokenIndex, token in
                var variants: [String: ThemedTokenWithVariants.Variant] = [:]
                for (themeIndex, tokens) in aligned.enumerated() {
                    let t = tokens[lineIndex][tokenIndex]
                    variants[themes[themeIndex].slot] = .init(color: t.color, fontStyle: t.fontStyle)
                }
                return ThemedTokenWithVariants(content: token.content, offset: token.offset, variants: variants)
            }
        }
    }
}

/// Break tokens from multiple themes into the same tokenization.
public func alignThemesTokenization(_ themes: [[[ThemedToken]]]) -> [[[ThemedToken]]] {
    guard let firstTheme = themes.first else { return [] }
    var outThemes: [[[ThemedToken]]] = themes.map { _ in [] }
    let count = themes.count
    for i in 0 ..< firstTheme.count {
        let lines = themes.map { i < $0.count ? $0[i] : [] }
        var outLines: [[ThemedToken]] = lines.map { _ in [] }
        var indexes = lines.map { _ in 0 }
        var current: [ThemedToken?] = lines.map { $0.first }
        while current.allSatisfy({ $0 != nil }) {
            let minLength = current.map { $0!.content.utf16.count }.min()!
            for n in 0 ..< count {
                let token = current[n]!
                let length = token.content.utf16.count
                if length == minLength {
                    outLines[n].append(token)
                    indexes[n] += 1
                    current[n] = indexes[n] < lines[n].count ? lines[n][indexes[n]] : nil
                } else {
                    let units = Array(token.content.utf16)
                    var head = token
                    head.content = String(decoding: units[..<minLength], as: UTF16.self)
                    outLines[n].append(head)
                    var tail = token
                    tail.content = String(decoding: units[minLength...], as: UTF16.self)
                    tail.offset = token.offset + minLength
                    current[n] = tail
                }
            }
        }
        for n in 0 ..< count {
            outThemes[n].append(outLines[n])
        }
    }
    return outThemes
}
