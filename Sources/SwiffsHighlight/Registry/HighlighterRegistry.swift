// Port of `packages/diffs/src/highlighter/{languages,themes}`: resolution of
// bundled and custom languages/themes, shared across highlighter instances.

import Foundation
import SwiffsCore
import Synchronization

/// Loads grammar registrations for a custom language (dependencies first).
public typealias LanguageLoader = @Sendable () throws -> [LanguageRegistration]
/// Loads a custom theme.
public typealias ThemeLoader = @Sendable () throws -> ThemeRegistration

/// A language whose grammars have been loaded (`ResolvedLanguage`).
public struct ResolvedLanguage: @unchecked Sendable {
    public var name: String
    public var data: [LanguageRegistration]
}

/// Process-wide registry of languages and themes, equivalent to the module
/// level maps in `highlighter/languages` and `highlighter/themes`.
public final class HighlighterRegistry: Sendable {
    public static let shared = HighlighterRegistry()

    private struct State {
        var customLanguages: [String: LanguageLoader] = [:]
        var customThemes: [String: ThemeLoader] = [:]
        var resolvedLanguages: [String: ResolvedLanguage] = [:]
        var resolvedThemes: [String: ThemeRegistration] = [:]
        var generation = 0
        /// Languages any highlighter has attached, in first-attach order.
        var attachedLanguageList: [String] = []
        var attachedLanguageSet: Set<String> = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Changes whenever languages or themes are registered or cleaned up.
    var generation: Int { state.withLock { $0.generation } }

    // MARK: Languages

    /// Register a custom language loader and optionally map it to file names
    /// or extensions (`registerCustomLanguage`).
    public func registerCustomLanguage(_ lang: String, loader: @escaping LanguageLoader, extensionsOrFilenames: [String] = []) throws {
        if lang == "text" || lang == "ansi" {
            throw DiffsHighlightError("registerCustomLanguage: 'text' and 'ansi' are reserved language names")
        }
        let registered = state.withLock { state in
            guard state.customLanguages[lang] == nil else { return false }
            state.customLanguages[lang] = loader
            state.generation += 1
            return true
        }
        guard registered else {
            HighlightDiagnostics.report("registerCustomLanguage: lang: \(lang) is already registered")
            return
        }
        for ext in extensionsOrFilenames {
            FileTypes.setCustomExtension(ext, lang)
        }
    }

    /// `resolveLanguage`: loads a language's grammars (custom first, then
    /// bundled) and caches the result.
    public func resolveLanguage(_ lang: String) throws -> ResolvedLanguage {
        let (cached, loader) = state.withLock { ($0.resolvedLanguages[lang], $0.customLanguages[lang]) }
        if let cached { return cached }
        let data: [LanguageRegistration]
        if let loader {
            data = try loader()
        } else if BundledData.hasLanguage(lang) {
            data = try BundledData.languageRegistrations(lang)
        } else {
            throw DiffsHighlightError("resolveLanguage: \"\(lang)\" not found in bundled or custom languages")
        }
        let resolved = ResolvedLanguage(name: lang, data: data)
        return state.withLock { state in
            if let existing = state.resolvedLanguages[lang] { return existing }
            state.resolvedLanguages[lang] = resolved
            return resolved
        }
    }

    /// Records languages a highlighter attached. Upstream keeps one shared
    /// highlighter per page, so every language requested so far is available
    /// to every render (which decides whether lazily embedded code, such as
    /// Markdown fences, is highlighted). Highlighters here attach the same set.
    func recordAttachedLanguages(_ langs: [String]) {
        state.withLock { state in
            for lang in langs where state.attachedLanguageSet.insert(lang).inserted {
                state.attachedLanguageList.append(lang)
            }
        }
    }

    /// Languages attached by any highlighter, from `index` on.
    func attachedLanguages(from index: Int) -> ArraySlice<String> {
        state.withLock { $0.attachedLanguageList[min(index, $0.attachedLanguageList.count)...] }
    }

    public func hasResolvedLanguages(_ langs: [String]) -> Bool {
        state.withLock { state in langs.allSatisfy { state.resolvedLanguages[$0] != nil } }
    }

    public func getResolvedLanguages(_ langs: [String]) throws -> [ResolvedLanguage] {
        try state.withLock { state in
            try langs.map { lang in
                guard let resolved = state.resolvedLanguages[lang] else {
                    throw DiffsHighlightError(
                        "getResolvedLanguages: \(lang) is not resolved. Please resolve languages before calling getResolvedLanguages"
                    )
                }
                return resolved
            }
        }
    }

    /// Whether a language can be resolved (bundled or registered).
    public func isKnownLanguage(_ lang: String) -> Bool {
        if lang == "text" || lang == "ansi" { return true }
        return state.withLock { $0.customLanguages[lang] != nil } || BundledData.hasLanguage(lang)
    }

    public func cleanUpResolvedLanguages() {
        state.withLock { state in
            state.resolvedLanguages.removeAll()
            state.generation += 1
        }
    }

    // MARK: Themes

    /// Registers a named custom theme loader (`registerCustomTheme`).
    public func registerCustomTheme(_ themeName: String, loader: @escaping ThemeLoader) {
        let registered = state.withLock { state in
            guard state.customThemes[themeName] == nil else { return false }
            state.customThemes[themeName] = loader
            state.generation += 1
            return true
        }
        if !registered {
            HighlightDiagnostics.report("SharedHighlight.registerCustomTheme: theme name already registered \(themeName)")
        }
    }

    /// Registers a theme object directly.
    public func registerCustomTheme(_ theme: ThemeRegistration) {
        registerCustomTheme(theme.name) { theme }
    }

    /// `resolveTheme`: loads and normalizes a theme by name.
    public func resolveTheme(_ themeName: String) throws -> ThemeRegistration {
        let (cached, loader) = state.withLock { ($0.resolvedThemes[themeName], $0.customThemes[themeName]) }
        if let cached { return cached }
        var theme: ThemeRegistration
        if let loader {
            theme = try loader()
        } else if BundledData.hasTheme(themeName) {
            theme = try BundledData.theme(themeName)
        } else {
            throw DiffsHighlightError("No valid theme loader registered for \"\(themeName)\"")
        }
        if theme.name != themeName {
            throw DiffsHighlightError("resolvedTheme: themeName: \(themeName) does not match theme.name: \(theme.name)")
        }
        theme = ThemeRegistration.normalize(
            name: theme.name,
            displayName: theme.displayName,
            type: theme.type,
            fg: theme.fg,
            bg: theme.bg,
            settings: theme.settings,
            colors: theme.colors,
            colorReplacements: theme.colorReplacements
        )
        return state.withLock { state in
            if let existing = state.resolvedThemes[themeName] { return existing }
            state.resolvedThemes[themeName] = theme
            return theme
        }
    }

    public func resolveThemes(_ names: [String]) throws -> [ThemeRegistration] {
        try names.map(resolveTheme)
    }

    public func hasResolvedThemes(_ names: [String]) -> Bool {
        state.withLock { state in names.allSatisfy { state.resolvedThemes[$0] != nil } }
    }

    public func getResolvedThemes(_ names: [String]) throws -> [ThemeRegistration] {
        try state.withLock { state in
            try names.map { name in
                guard let theme = state.resolvedThemes[name] else {
                    throw DiffsHighlightError("getResolvedThemes: \(name) is not resolved")
                }
                return theme
            }
        }
    }

    public func cleanUpResolvedThemes() {
        state.withLock { state in
            state.resolvedThemes.removeAll()
            state.generation += 1
        }
    }

    /// Names of every available theme (bundled and custom).
    public var availableThemes: [String] {
        let custom = state.withLock { Array($0.customThemes.keys) }
        return BundledData.themes.map(\.id) + custom.sorted()
    }
}

/// Registers a custom CSS-variable theme (`registerCustomCSSVariableTheme`):
/// token colors resolve to the given variable defaults.
public func createCSSVariablesTheme(name: String, variableDefaults: [String: String], fontStyle: Bool = false) -> ThemeRegistration {
    // Shiki's `createCssVariablesTheme` maps scopes to `var(--diffs-token-...)`
    // references. Natively there are no CSS variables, so the defaults are
    // resolved eagerly.
    func value(_ key: String, _ fallback: String) -> String { variableDefaults[key] ?? fallback }
    let fg = value("foreground", "#000000")
    let bg = value("background", "#ffffff")
    let mapping: [(String, [String])] = [
        ("token-comment", ["comment", "punctuation.definition.comment", "string.comment"]),
        ("token-constant", ["constant", "entity.name.constant", "variable.other.constant", "variable.other.enummember", "variable.language"]),
        ("token-keyword", ["keyword", "storage.type", "storage.modifier"]),
        ("token-parameter", ["variable.parameter.function"]),
        ("token-function", ["entity.name.function", "meta.function-call", "support.function"]),
        ("token-string", ["string", "markup.fenced_code", "markup.inline"]),
        ("token-string-expression", ["string.regexp", "meta.template.expression"]),
        ("token-punctuation", ["punctuation", "meta.brace"]),
        ("token-link", ["markup.underline.link", "string.other.link"]),
    ]
    var settings: [RawThemeSetting] = [RawThemeSetting(foreground: fg, background: bg)]
    for (key, scopes) in mapping {
        if let color = variableDefaults[key] {
            settings.append(RawThemeSetting(scope: .array(scopes), foreground: color))
        }
    }
    _ = fontStyle
    return ThemeRegistration.normalize(
        name: name,
        type: .dark,
        fg: fg,
        bg: bg,
        settings: settings,
        colors: ["editor.foreground": fg, "editor.background": bg],
        colorReplacements: [:]
    )
}
