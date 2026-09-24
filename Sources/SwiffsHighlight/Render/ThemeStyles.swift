// Port of `getHighlighterThemeStyles`: the theme colors that feed the
// stylesheet variables (`--diffs-fg`, `--diffs-bg`, git colors).

import Foundation
import SwiffsCore

extension ThemeRegistration {
    /// The theme's `fg`/`bg` and git decoration colors (`getGitVariables`).
    public var colorInputs: ThemeColorInputs {
        func color(_ value: String?) -> RGBAColor? {
            guard let value, !value.isEmpty else { return nil }
            let replaced = colorReplacements[value.lowercased()] ?? value
            return RGBAColor(css: replaced)
        }
        return ThemeColorInputs(
            fg: color(fg) ?? (type == .dark ? .white : .black),
            bg: color(bg) ?? (type == .dark ? .black : .white),
            additionColor: color(colors["gitDecoration.addedResourceForeground"] ?? colors["terminal.ansiGreen"]),
            deletionColor: color(colors["gitDecoration.deletedResourceForeground"] ?? colors["terminal.ansiRed"]),
            modifiedColor: color(colors["gitDecoration.modifiedResourceForeground"] ?? colors["terminal.ansiBlue"])
        )
    }
}

/// Resolved theme colors for both color schemes (`--diffs-light*` /
/// `--diffs-dark*`), or a single theme that pins the scheme.
public struct ResolvedDiffsTheme: Hashable, Sendable {
    public var light: ThemeColorInputs
    public var dark: ThemeColorInputs
    /// The single theme's type (`baseThemeType`); forces the color scheme.
    public var baseThemeType: ThemeKind?
    public var slots: ThemeSlots

    public init(light: ThemeColorInputs, dark: ThemeColorInputs, baseThemeType: ThemeKind?, slots: ThemeSlots) {
        self.light = light
        self.dark = dark
        self.baseThemeType = baseThemeType
        self.slots = slots
    }

    /// Resolves themes through a registry.
    public static func resolve(_ selection: ThemeSelection, registry: HighlighterRegistry = .shared) throws -> ResolvedDiffsTheme {
        switch selection {
        case .single(let name):
            let theme = try registry.resolveTheme(name)
            let inputs = theme.colorInputs
            return ResolvedDiffsTheme(light: inputs, dark: inputs, baseThemeType: theme.type, slots: .single(name))
        case .pair(let pair):
            let dark = try registry.resolveTheme(pair.dark)
            let light = try registry.resolveTheme(pair.light)
            return ResolvedDiffsTheme(light: light.colorInputs, dark: dark.colorInputs, baseThemeType: nil, slots: .pair(dark: pair.dark, light: pair.light))
        }
    }

    /// Whether the dark branch of `light-dark()` applies.
    public func isDark(themeType: ThemeType, systemIsDark: Bool) -> Bool {
        if let baseThemeType { return baseThemeType == .dark }
        switch themeType {
        case .dark: return true
        case .light: return false
        case .system: return systemIsDark
        }
    }

    /// Palette for the active scheme.
    public func palette(themeType: ThemeType, systemIsDark: Bool, overrides: DiffsColorOverrides = DiffsColorOverrides()) -> DiffsPalette {
        let dark = isDark(themeType: themeType, systemIsDark: systemIsDark)
        return DiffsPalette(theme: dark ? self.dark : light, isDark: dark, overrides: overrides)
    }

    /// Index into `HighlightedToken.styles` for the active scheme.
    public func styleIndex(isDark: Bool) -> Int {
        switch slots {
        case .single: return 0
        case .pair: return isDark ? 0 : 1
        }
    }
}
