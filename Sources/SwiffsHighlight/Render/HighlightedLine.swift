// Highlighted output types: the native equivalent of the HAST line nodes that
// `renderDiffWithHighlighter` / `renderFileWithHighlighter` produce.

import Foundation
import SwiffsCore

/// Style of a token for one theme.
public struct TokenStyle: Hashable, Sendable {
    /// Token color as emitted by the theme (e.g. `#E1E4E8`); nil means the
    /// theme's default foreground.
    public var color: String?
    public var fontStyle: FontStyle

    public init(color: String? = nil, fontStyle: FontStyle = []) {
        self.color = color
        self.fontStyle = fontStyle
    }
}

/// A token within a line. Offsets are UTF-16 code units into the line text.
public struct HighlightedToken: Hashable, Sendable {
    public var start: Int
    public var end: Int
    /// One style per theme slot (`[style]` for a single theme,
    /// `[dark, light]` for a theme pair).
    public var styles: [TokenStyle]

    public init(start: Int, end: Int, styles: [TokenStyle]) {
        self.start = start
        self.end = end
        self.styles = styles
    }
}

/// A UTF-16 range within a line.
public struct LineRange: Hashable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public var length: Int { end - start }
}

/// One highlighted line (the equivalent of a `[data-line]` node).
public struct HighlightedLine: Hashable, Sendable {
    /// The line's text without its trailing line break.
    public var text: String
    public var tokens: [HighlightedToken]
    /// Intra-line change emphasis ranges (`[data-diff-span]`).
    public var diffSpans: [LineRange]

    public init(text: String, tokens: [HighlightedToken], diffSpans: [LineRange] = []) {
        self.text = text
        self.tokens = tokens
        self.diffSpans = diffSpans
    }

    /// A plain (unhighlighted) line.
    public static func plain(_ text: String, slots: Int) -> HighlightedLine {
        let length = text.utf16.count
        let tokens = length == 0 ? [] : [HighlightedToken(start: 0, end: length, styles: Array(repeating: TokenStyle(), count: slots))]
        return HighlightedLine(text: text, tokens: tokens)
    }
}

/// Theme slot description for highlighted output.
public enum ThemeSlots: Hashable, Sendable {
    case single(String)
    /// `[dark, light]`
    case pair(dark: String, light: String)

    public init(_ selection: ThemeSelection) {
        switch selection {
        case .single(let name): self = .single(name)
        case .pair(let pair): self = .pair(dark: pair.dark, light: pair.light)
        }
    }

    public var themeNames: [String] {
        switch self {
        case .single(let name): return [name]
        case .pair(let dark, let light): return [dark, light]
        }
    }

    public var count: Int { themeNames.count }
}

/// Result of highlighting a file (`ThemedFileResult`).
public struct ThemedFileResult: Sendable {
    /// Highlighted lines indexed by line index (nil outside a windowed
    /// render).
    public var lines: [HighlightedLine?]
    public var themes: ThemeSlots
    /// The theme type when a single theme is used.
    public var baseThemeType: ThemeKind?
}

/// Result of highlighting a diff (`ThemedDiffResult`).
public struct ThemedDiffResult: Sendable {
    /// Indexed by `FileDiffMetadata.deletionLines` index.
    public var deletionLines: [HighlightedLine?]
    /// Indexed by `FileDiffMetadata.additionLines` index.
    public var additionLines: [HighlightedLine?]
    public var themes: ThemeSlots
    public var baseThemeType: ThemeKind?
}
