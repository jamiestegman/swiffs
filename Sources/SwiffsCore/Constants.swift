// Port of `packages/diffs/src/constants.ts`.

import Foundation

public enum DiffsConstants {
    public static let headerPrefixSlotID = "header-prefix"
    public static let headerFilenameSuffixSlotID = "header-filename-suffix"
    public static let headerMetadataSlotID = "header-metadata"
    public static let customHeaderSlotID = "header-custom"

    public static let defaultThemes = ThemesType(dark: "pierre-dark", light: "pierre-light")

    public static let defaultCollapsedContextThreshold = 1
    public static let defaultTokenizeMaxLength = 100_000

    public static let defaultVirtualFileMetrics = VirtualFileMetrics(
        hunkLineCount: 50,
        lineHeight: 20,
        diffHeaderHeight: 44,
        spacing: 8
    )

    public static let defaultCodeViewFileMetrics: VirtualFileMetrics = {
        var metrics = defaultVirtualFileMetrics
        metrics.hunkLineCount = 1
        return metrics
    }()

    public static let defaultCodeViewLayout = CodeViewLayout(paddingTop: 8, paddingBottom: 8, gap: 8)

    public static let defaultSmoothScrollSettings = SmoothScrollSettings(
        omega: 0.015,
        positionEpsilon: 0.5,
        velocityEpsilon: 0.05
    )

    public static let defaultExpandedRegion = HunkExpansionRegion(fromStart: 0, fromEnd: 0)
    public static let defaultRenderRange = RenderRange.default
    public static let emptyRenderRange = RenderRange.empty
}

/// A light/dark pair of theme names.
public struct ThemesType: Hashable, Sendable, Codable {
    public var dark: String
    public var light: String

    public init(dark: String, light: String) {
        self.dark = dark
        self.light = light
    }
}

/// A single theme name or a light/dark pair (`DiffsThemeNames | ThemesType`).
public enum ThemeSelection: Hashable, Sendable {
    case single(String)
    case pair(ThemesType)

    /// Port of `getThemes`: the list of theme names referenced.
    public var themeNames: [String] {
        switch self {
        case .single(let name): return [name]
        case .pair(let pair): return [pair.dark, pair.light]
        }
    }
}

extension ThemeSelection: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .single(value)
    }
}
