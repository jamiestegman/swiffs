// A Shiki highlighter plus the "attached" bookkeeping from
// `shared_highlighter.ts` / `attachResolvedLanguages.ts` /
// `attachResolvedThemes.ts`.

import Foundation
import SwiffsCore

/// A highlighter instance that lazily attaches languages and themes from a
/// `HighlighterRegistry`. Not thread safe: confine each instance to one
/// thread or actor (see `HighlightWorkerPool`).
public final class DiffsHighlighter {
    public let registry: HighlighterRegistry
    let highlighter = Highlighter()
    private var attachedLanguages: Set<String> = []
    private var attachedThemes: Set<String> = []
    private var attachedGeneration: Int
    /// When set, `renderDiff` tokenizes the deletion side on this
    /// highlighter while this one tokenizes the addition side. It must not be
    /// used elsewhere during the call.
    public var sideHighlighter: DiffsHighlighter?

    public init(registry: HighlighterRegistry = .shared) {
        self.registry = registry
        attachedGeneration = registry.generation
    }

    private func invalidateIfNeeded() {
        // Custom registrations changed: drop attachment caches so languages
        // and themes are re-resolved.
        if attachedGeneration != registry.generation {
            attachedGeneration = registry.generation
            attachedThemes.removeAll()
        }
    }

    public func areLanguagesAttached(_ langs: [String]) -> Bool {
        langs.allSatisfy { $0 == "text" || $0 == "ansi" || attachedLanguages.contains($0) }
    }

    public func areThemesAttached(_ themes: [String]) -> Bool {
        invalidateIfNeeded()
        return themes.allSatisfy { attachedThemes.contains($0) }
    }

    /// Resolves (if needed) and attaches the given languages.
    public func attachLanguages(_ langs: [String]) throws {
        for lang in Set(langs) where lang != "text" && lang != "ansi" && !attachedLanguages.contains(lang) {
            let resolved = try registry.resolveLanguage(lang)
            let declares = resolved.data.contains { $0.name == lang || $0.aliases.contains(lang) }
            if !declares {
                throw DiffsHighlightError(
                    "attachResolvedLanguages: No returned grammar declares \"\(lang)\" as its name or an alias."
                )
            }
            highlighter.loadLanguages(resolved.data)
            attachedLanguages.insert(lang)
        }
    }

    /// Resolves (if needed) and attaches the given themes.
    public func attachThemes(_ themes: [String]) throws {
        invalidateIfNeeded()
        for name in themes where !attachedThemes.contains(name) {
            highlighter.loadTheme(try registry.resolveTheme(name))
            attachedThemes.insert(name)
        }
    }

    /// `getSharedHighlighter({ themes, langs })`: ensures the languages and
    /// themes are attached. Unknown languages are ignored (they render as
    /// plain text).
    public func prepare(langs: [String], themes: [String]) throws {
        try attachThemes(themes)
        try attachLanguages(langs.filter { registry.isKnownLanguage($0) })
    }

    public func getTheme(_ name: String) throws -> ThemeRegistration {
        try highlighter.getTheme(name)
    }

    /// Tokenizes code for the given theme slots (the native equivalent of
    /// `codeToHast` with `defaultColor: false`). Returns one token list per
    /// line; each token has one style per theme slot.
    func tokenize(_ code: String, lang: String, themes: ThemeSlots, tokenizeMaxLineLength: Int) throws -> [[(content: String, styles: [TokenStyle])]] {
        let lines = try tokenizeLines(code, lang: lang, themes: themes, tokenizeMaxLineLength: tokenizeMaxLineLength)
        // codeToHast's default `mergeWhitespaces: true`.
        return mergeWhitespaceTokens(lines, multiTheme: themes.count > 1)
    }

    /// Unattached languages render as plain text.
    func streamLanguage(_ lang: String) -> String {
        (lang == "ansi" || attachedLanguages.contains(lang) || isPlainLang(lang)) ? lang : "text"
    }

    /// Tokenizes without merging whitespace tokens.
    func tokenizeLines(_ code: String, lang: String, themes: ThemeSlots, tokenizeMaxLineLength: Int) throws -> [[(content: String, styles: [TokenStyle])]] {
        let options = TokenizeOptions(tokenizeMaxLineLength: tokenizeMaxLineLength, tokenizeTimeLimit: 0)
        let effectiveLang = streamLanguage(lang)
        if effectiveLang == "ansi" {
            return try tokenizeAnsi(code, themes: themes)
        }
        switch themes {
        case .single(let name):
            let tokens = try highlighter.codeToTokensBase(code, lang: effectiveLang, theme: name, options: options)
            return tokens.map { line in
                line.map { token in
                    (token.content, [TokenStyle(color: token.color.flatMap { $0.isEmpty ? nil : $0 }, fontStyle: token.fontStyle)])
                }
            }
        case .pair(let dark, let light):
            let tokens = try highlighter.codeToTokensWithThemes(
                code,
                lang: effectiveLang,
                themes: [("dark", dark), ("light", light)],
                options: options
            )
            return tokens.map { line in
                line.map { token in
                    let darkStyle = token.variants["dark"]
                    let lightStyle = token.variants["light"]
                    return (token.content, [
                        TokenStyle(color: darkStyle?.color.flatMap { $0.isEmpty ? nil : $0 }, fontStyle: darkStyle?.fontStyle ?? []),
                        TokenStyle(color: lightStyle?.color.flatMap { $0.isEmpty ? nil : $0 }, fontStyle: lightStyle?.fontStyle ?? []),
                    ])
                }
            }
        }
    }

    private func tokenizeAnsi(_ code: String, themes: ThemeSlots) throws -> [[(content: String, styles: [TokenStyle])]] {
        let themeRegistrations = try themes.themeNames.map { try highlighter.getTheme($0) }
        let perTheme = themeRegistrations.map { tokenizeAnsiWithTheme(code, theme: $0) }
        let aligned = alignThemesTokenization(perTheme)
        guard let first = aligned.first else { return [] }
        return first.enumerated().map { lineIndex, line in
            line.enumerated().map { tokenIndex, token in
                (token.content, aligned.map { tokens in
                    let t = tokens[lineIndex][tokenIndex]
                    return TokenStyle(color: t.color, fontStyle: t.fontStyle)
                })
            }
        }
    }
}

/// Shiki `mergeWhitespaceTokens`: whitespace-only tokens are merged into the
/// following token. Multi-theme tokens carry no `fontStyle` field after
/// flattening, so they always merge.
func mergeWhitespaceTokens(_ lines: [[(content: String, styles: [TokenStyle])]], multiTheme: Bool) -> [[(content: String, styles: [TokenStyle])]] {
    func isWhitespaceOnly(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy(JSWhitespace.isWhitespace)
    }
    func couldMerge(_ styles: [TokenStyle]) -> Bool {
        if multiTheme { return true }
        guard let style = styles.first else { return true }
        return !(style.fontStyle.contains(.underline) || style.fontStyle.contains(.strikethrough))
    }
    return lines.map { line in
        var newLine: [(content: String, styles: [TokenStyle])] = []
        newLine.reserveCapacity(line.count)
        var carryOnContent = ""
        for (index, token) in line.enumerated() {
            let merge = couldMerge(token.styles)
            if merge, isWhitespaceOnly(token.content), index + 1 < line.count {
                carryOnContent += token.content
            } else if !carryOnContent.isEmpty {
                if merge {
                    newLine.append((carryOnContent + token.content, token.styles))
                } else {
                    newLine.append((carryOnContent, token.styles.map { _ in TokenStyle() }))
                    newLine.append(token)
                }
                carryOnContent = ""
            } else {
                newLine.append(token)
            }
        }
        return newLine
    }
}
