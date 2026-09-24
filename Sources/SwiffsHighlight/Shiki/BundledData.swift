// Access to the grammars and themes bundled with SwiffsHighlight (Shiki's
// `bundledLanguages` / `bundledThemes` plus the Pierre themes).

import Foundation

public struct BundledLanguageInfo: Hashable, Sendable, Codable {
    /// Language id (e.g. `typescript`).
    public var id: String
    /// Display name (e.g. `TypeScript`).
    public var name: String
    public var aliases: [String]
    /// Grammar registrations to load, in order (dependencies first, the
    /// language itself last).
    public var load: [String]
}

public struct BundledThemeInfo: Hashable, Sendable, Codable {
    public var id: String
    public var displayName: String?
    public var type: ThemeKind?
}

public enum BundledData {
    private static let languagesURL = Bundle.module.url(forResource: "Languages", withExtension: nil)!
    private static let themesURL = Bundle.module.url(forResource: "Themes", withExtension: nil)!

    /// All bundled languages.
    public static let languages: [BundledLanguageInfo] = {
        let data = try! Data(contentsOf: languagesURL.appendingPathComponent("index.json"))
        return try! JSONDecoder().decode([BundledLanguageInfo].self, from: data)
    }()

    /// All bundled themes (Pierre themes first).
    public static let themes: [BundledThemeInfo] = {
        let data = try! Data(contentsOf: themesURL.appendingPathComponent("index.json"))
        return try! JSONDecoder().decode([BundledThemeInfo].self, from: data)
    }()

    private static let languagesByIdOrAlias: [String: BundledLanguageInfo] = {
        var result: [String: BundledLanguageInfo] = [:]
        for info in languages {
            result[info.id] = info
        }
        for info in languages {
            for alias in info.aliases where result[alias] == nil {
                result[alias] = info
            }
        }
        return result
    }()

    public static func languageInfo(_ idOrAlias: String) -> BundledLanguageInfo? {
        languagesByIdOrAlias[idOrAlias]
    }

    public static func hasLanguage(_ idOrAlias: String) -> Bool {
        languagesByIdOrAlias[idOrAlias] != nil
    }

    public static func hasTheme(_ name: String) -> Bool {
        themes.contains { $0.id == name }
    }

    /// Loads the raw grammar JSON for a registration name.
    public static func grammarJSON(_ registrationName: String) throws -> [String: Any] {
        let url = languagesURL.appendingPathComponent("\(registrationName).json")
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DiffsHighlightError("Invalid grammar JSON for \(registrationName)")
        }
        return object
    }

    /// Loads the registrations needed for a language (dependencies first).
    public static func languageRegistrations(_ idOrAlias: String) throws -> [LanguageRegistration] {
        guard let info = languageInfo(idOrAlias) else {
            throw DiffsHighlightError("resolveLanguage: \"\(idOrAlias)\" not found in bundled or custom languages")
        }
        return try info.load.map { try LanguageRegistration(json: grammarJSON($0)) }
    }

    /// Loads and normalizes a bundled theme.
    public static func theme(_ name: String) throws -> ThemeRegistration {
        let url = themesURL.appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DiffsHighlightError("No valid theme loader registered for \"\(name)\"")
        }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DiffsHighlightError("Invalid theme JSON for \(name)")
        }
        return try ThemeRegistration(json: object)
    }
}
