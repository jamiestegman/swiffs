// Theme model and Shiki's `normalizeTheme`.

import Foundation

public enum ThemeKind: String, Hashable, Sendable, Codable {
    case light, dark
}

/// A resolved (normalized) theme, equivalent to Shiki's
/// `ThemeRegistrationResolved`.
public struct ThemeRegistration: Hashable, Sendable {
    public var name: String
    public var displayName: String?
    public var type: ThemeKind
    public var fg: String
    public var bg: String
    public var settings: [RawThemeSetting]
    public var colors: [String: String]
    public var colorReplacements: [String: String]

    public init(
        name: String,
        displayName: String? = nil,
        type: ThemeKind,
        fg: String,
        bg: String,
        settings: [RawThemeSetting],
        colors: [String: String] = [:],
        colorReplacements: [String: String] = [:]
    ) {
        self.name = name
        self.displayName = displayName
        self.type = type
        self.fg = fg
        self.bg = bg
        self.settings = settings
        self.colors = colors
        self.colorReplacements = colorReplacements
    }

    /// Parses a raw (VS Code / TextMate / Shiki) theme JSON object and
    /// normalizes it like Shiki's `normalizeTheme`.
    public init(json: [String: Any], name overrideName: String? = nil) throws {
        guard let name = overrideName ?? (json["name"] as? String) else {
            throw DiffsHighlightError("Theme is missing a name")
        }
        let settingsJSON = (json["settings"] as? [Any]) ?? (json["tokenColors"] as? [Any]) ?? []
        let settings = settingsJSON.compactMap { entry -> RawThemeSetting? in
            guard let object = entry as? [String: Any] else { return nil }
            return RawThemeSetting(json: object)
        }
        var colors: [String: String] = [:]
        for (key, value) in json["colors"] as? [String: Any] ?? [:] {
            if let string = value as? String { colors[key] = string }
        }
        var colorReplacements: [String: String] = [:]
        for (key, value) in json["colorReplacements"] as? [String: Any] ?? [:] {
            if let string = value as? String { colorReplacements[key] = string }
        }
        let type = ThemeKind(rawValue: (json["type"] as? String) ?? "dark") ?? .dark
        self = ThemeRegistration.normalize(
            name: name,
            displayName: json["displayName"] as? String,
            type: type,
            fg: json["fg"] as? String,
            bg: json["bg"] as? String,
            settings: settings,
            colors: colors,
            colorReplacements: colorReplacements
        )
    }

    /// Shiki `normalizeTheme`.
    public static func normalize(
        name: String,
        displayName: String? = nil,
        type: ThemeKind,
        fg: String?,
        bg: String?,
        settings inputSettings: [RawThemeSetting],
        colors inputColors: [String: String],
        colorReplacements inputReplacements: [String: String]
    ) -> ThemeRegistration {
        var settings = inputSettings
        var colors = inputColors
        var colorReplacements = inputReplacements
        var fg = fg.flatMap { $0.isEmpty ? nil : $0 }
        var bg = bg.flatMap { $0.isEmpty ? nil : $0 }
        if fg == nil || bg == nil {
            // Theme might contain a global `tokenColor` without `name` or `scope`
            let globalSetting = settings.first { $0.name == nil && $0.scope == nil }
            if let value = globalSetting?.foreground, !value.isEmpty { fg = value }
            if let value = globalSetting?.background, !value.isEmpty { bg = value }
            // Use `editor.foreground` and `editor.background`
            if fg == nil, let value = colors["editor.foreground"], !value.isEmpty { fg = value }
            if bg == nil, let value = colors["editor.background"], !value.isEmpty { bg = value }
            // If there's no fg/bg color specified in theme, use default
            if fg == nil { fg = type == .light ? "#333333" : "#bbbbbb" }
            if bg == nil { bg = type == .light ? "#fffffe" : "#1e1e1e" }
        }
        let resolvedFg = fg!
        let resolvedBg = bg!

        if !(settings.first.map { $0.hasSettings && $0.scope == nil } ?? false) {
            settings.insert(RawThemeSetting(foreground: resolvedFg, background: resolvedBg), at: 0)
        }

        var replacementCount = 0
        var replacementMap: [String: String] = [:]
        func getReplacementColor(_ value: String) -> String {
            if let existing = replacementMap[value] { return existing }
            while true {
                replacementCount += 1
                let hexDigits = String(replacementCount, radix: 16)
                let hex = "#" + String(repeating: "0", count: max(0, 8 - hexDigits.count)) + hexDigits
                if colorReplacements["#\(hex)"] != nil { continue }
                replacementMap[value] = hex
                return hex
            }
        }

        settings = settings.map { setting in
            let replaceFg = setting.foreground.map { !$0.isEmpty && !$0.hasPrefix("#") } ?? false
            let replaceBg = setting.background.map { !$0.isEmpty && !$0.hasPrefix("#") } ?? false
            if !replaceFg, !replaceBg { return setting }
            var clone = setting
            if replaceFg {
                let replacement = getReplacementColor(setting.foreground!)
                colorReplacements[replacement] = setting.foreground!
                clone.foreground = replacement
            }
            if replaceBg {
                let replacement = getReplacementColor(setting.background!)
                colorReplacements[replacement] = setting.background!
                clone.background = replacement
            }
            return clone
        }

        for key in colors.keys.sorted() where key == "editor.foreground" || key == "editor.background" || key.hasPrefix("terminal.ansi") {
            if let value = colors[key], !value.hasPrefix("#") {
                let replacement = getReplacementColor(value)
                colorReplacements[replacement] = value
                colors[key] = replacement
            }
        }

        return ThemeRegistration(
            name: name,
            displayName: displayName,
            type: type,
            fg: resolvedFg,
            bg: resolvedBg,
            settings: settings,
            colors: colors,
            colorReplacements: colorReplacements
        )
    }

    /// Shiki's special `none` theme.
    public static let none = ThemeRegistration(name: "none", type: .dark, fg: "", bg: "", settings: [])
}

extension RawThemeSetting {
    init(json: [String: Any]) {
        var scope: Scope?
        if let string = json["scope"] as? String {
            scope = .string(string)
        } else if let array = json["scope"] as? [Any] {
            scope = .array(array.compactMap { $0 as? String })
        }
        let settings = json["settings"] as? [String: Any]
        self.init(
            name: json["name"] as? String,
            scope: scope,
            fontStyle: settings?["fontStyle"] as? String,
            foreground: settings?["foreground"] as? String,
            background: settings?["background"] as? String,
            hasSettings: settings != nil
        )
    }
}

/// Shiki `resolveColorReplacements` (theme replacements only; per-call
/// replacements are merged by the caller).
func applyColorReplacements(_ color: String?, _ replacements: [String: String]) -> String? {
    guard let color, !color.isEmpty else { return color }
    return replacements[color.lowercased()] ?? color
}
