// Port of vscode-textmate `registry.ts` (SyncRegistry) combined with Shiki's
// `Resolver` (language lookup by scope name and `injectTo` handling).

import Foundation

final class SyncRegistry: GrammarRepository {
    private var grammars: [String: Grammar] = [:]
    let themeProvider: ThemeProvider
    private let lookupGrammar: (String) -> RawGrammar?
    private let lookupInjections: (String) -> [String]?

    init(
        theme: TextMateTheme,
        lookupGrammar: @escaping (String) -> RawGrammar?,
        lookupInjections: @escaping (String) -> [String]?
    ) {
        themeProvider = ThemeProvider(theme: theme)
        self.lookupGrammar = lookupGrammar
        self.lookupInjections = lookupInjections
    }

    func setTheme(_ theme: TextMateTheme) {
        themeProvider.theme = theme
    }

    func getColorMap() -> [String] {
        themeProvider.theme.getColorMap()
    }

    func lookup(_ scopeName: String) -> RawGrammar? {
        lookupGrammar(scopeName)
    }

    func injections(_ scopeName: String) -> [String]? {
        lookupInjections(scopeName)
    }

    func grammarForScopeName(
        _ scopeName: String,
        initialLanguage: Int,
        balancedBracketSelectors: BalancedBracketSelectors?
    ) -> Grammar? {
        if let grammar = grammars[scopeName] { return grammar }
        guard let rawGrammar = lookup(scopeName) else { return nil }
        let grammar = Grammar(
            rootScopeName: scopeName,
            grammar: rawGrammar,
            initialLanguage: initialLanguage,
            balancedBracketSelectors: balancedBracketSelectors,
            grammarRepository: self
        )
        grammars[scopeName] = grammar
        return grammar
    }

    func removeGrammar(_ scopeName: String) {
        grammars.removeValue(forKey: scopeName)
    }
}
