// Port of `packages/diffs/src/highlighter/{languages,themes}`: resolution of
// bundled and custom languages/themes, shared across highlighter instances.

import Foundation
import SwiffsCore

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
public final class HighlighterRegistry: @unchecked Sendable {
    public static let shared = HighlighterRegistry()

    private let lock = NSRecursiveLock()
    private var customLanguages: [String: LanguageLoader] = [:]
    private var customThemes: [String: ThemeLoader] = [:]
    private var resolvedLanguages: [String: ResolvedLanguage] = [:]
    private var resolvedThemes: [String: ThemeRegistration] = [:]
    private(set) var generation = 0
    /// Languages any highlighter has attached, in first-attach order.
    private var attachedLanguageList: [String] = []
    private var attachedLanguageSet: Set<String> = []

    public init() {}

    // MARK: Languages

    /// Register a custom language loader and optionally map it to file names
    /// or extensions (`registerCustomLanguage`).
    public func registerCustomLanguage(_ lang: String, loader: @escaping LanguageLoader, extensionsOrFilenames: [String] = []) throws {
        if lang == "text" || lang == "ansi" {
            throw DiffsHighlightError("registerCustomLanguage: 'text' and 'ansi' are reserved language names")
        }
        lock.withLock {
            if customLanguages[lang] != nil {
                HighlightDiagnostics.report("registerCustomLanguage: lang: \(lang) is already registered")
                return
            }
            customLanguages[lang] = loader
            generation += 1
        }
        for ext in extensionsOrFilenames {
            FileTypes.setCustomExtension(ext, lang)
        }
    }

    /// `resolveLanguage`: loads a language's grammars (custom first, then
    /// bundled) and caches the result.
    public func resolveLanguage(_ lang: String) throws -> ResolvedLanguage {
        if let cached = lock.withLock({ resolvedLanguages[lang] }) { return cached }
        let loader = lock.withLock { customLanguages[lang] }
        let data: [LanguageRegistration]
        if let loader {
            data = try loader()
        } else if BundledData.hasLanguage(lang) {
            data = try BundledData.languageRegistrations(lang)
        } else {
            throw DiffsHighlightError("resolveLanguage: \"\(lang)\" not found in bundled or custom languages")
        }
        let resolved = ResolvedLanguage(name: lang, data: data)
        return lock.withLock {
            if let existing = resolvedLanguages[lang] { return existing }
            resolvedLanguages[lang] = resolved
            return resolved
        }
    }

    /// Records languages a highlighter attached. Upstream keeps one shared
    /// highlighter per page, so every language requested so far is available
    /// to every render (which decides whether lazily embedded code, such as
    /// Markdown fences, is highlighted). Highlighters here attach the same set.
    func recordAttachedLanguages(_ langs: [String]) {
        lock.withLock {
            for lang in langs where attachedLanguageSet.insert(lang).inserted {
                attachedLanguageList.append(lang)
            }
        }
    }

    /// Languages attached by any highlighter, from `index` on.
    func attachedLanguages(from index: Int) -> ArraySlice<String> {
        lock.withLock { attachedLanguageList[min(index, attachedLanguageList.count)...] }
    }

    public func hasResolvedLanguages(_ langs: [String]) -> Bool {
        lock.withLock { langs.allSatisfy { resolvedLanguages[$0] != nil } }
    }

    public func getResolvedLanguages(_ langs: [String]) throws -> [ResolvedLanguage] {
        try lock.withLock {
            try langs.map { lang in
                guard let resolved = resolvedLanguages[lang] else {
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
        return lock.withLock { customLanguages[lang] != nil } || BundledData.hasLanguage(lang)
    }

    public func cleanUpResolvedLanguages() {
        lock.withLock {
            resolvedLanguages.removeAll()
            generation += 1
        }
    }

    // MARK: Themes

    /// Registers a named custom theme loader (`registerCustomTheme`).
    public func registerCustomTheme(_ themeName: String, loader: @escaping ThemeLoader) {
        lock.withLock {
            if customThemes[themeName] != nil {
                HighlightDiagnostics.report("SharedHighlight.registerCustomTheme: theme name already registered \(themeName)")
                return
            }
            customThemes[themeName] = loader
            generation += 1
        }
    }

    /// Registers a theme object directly.
    public func registerCustomTheme(_ theme: ThemeRegistration) {
        registerCustomTheme(theme.name) { theme }
    }

    /// `resolveTheme`: loads and normalizes a theme by name.
    public func resolveTheme(_ themeName: String) throws -> ThemeRegistration {
        if let cached = lock.withLock({ resolvedThemes[themeName] }) { return cached }
        let loader = lock.withLock { customThemes[themeName] }
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
        return lock.withLock {
            if let existing = resolvedThemes[themeName] { return existing }
            resolvedThemes[themeName] = theme
            return theme
        }
    }

    public func resolveThemes(_ names: [String]) throws -> [ThemeRegistration] {
        try names.map(resolveTheme)
    }

    public func hasResolvedThemes(_ names: [String]) -> Bool {
        lock.withLock { names.allSatisfy { resolvedThemes[$0] != nil } }
    }

    public func getResolvedThemes(_ names: [String]) throws -> [ThemeRegistration] {
        try lock.withLock {
            try names.map { name in
                guard let theme = resolvedThemes[name] else {
                    throw DiffsHighlightError("getResolvedThemes: \(name) is not resolved")
                }
                return theme
            }
        }
    }

    public func cleanUpResolvedThemes() {
        lock.withLock {
            resolvedThemes.removeAll()
            generation += 1
        }
    }

    /// Names of every available theme (bundled and custom).
    public var availableThemes: [String] {
        let custom = lock.withLock { Array(customThemes.keys) }
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
