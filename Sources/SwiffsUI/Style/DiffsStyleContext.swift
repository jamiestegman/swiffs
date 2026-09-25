// Resolved appearance for drawing: fonts, CSS-equivalent metrics and colors.

import AppKit
import CoreText
import SwiffsCore
import SwiffsHighlight

/// Fonts, metrics and palette for one appearance.
final class DiffsStyleContext {
    let typography: DiffsTypography
    let palette: DiffsPalette
    let theme: ResolvedDiffsTheme
    let isDark: Bool
    /// Index into `HighlightedToken.styles`.
    let styleIndex: Int

    let regularFont: CTFont
    let boldFont: CTFont
    let italicFont: CTFont
    let boldItalicFont: CTFont
    let headerFont: NSFont
    let headerBoldFont: NSFont

    /// Width of `0` in the code font (CSS `1ch`).
    let ch: CGFloat
    let lineHeight: CGFloat
    /// Offset from the top of a row to the text baseline.
    let baseline: CGFloat
    /// Font content area height (inline box background height).
    let contentHeight: CGFloat
    let ascent: CGFloat
    let descent: CGFloat

    private var colorCache: [String: CGColor] = [:]
    private var tokenAttributesCache: [TokenAttributesKey: CFDictionary] = [:]

    private struct TokenAttributesKey: Hashable {
        var style: TokenStyle
        var dimmed: Bool
    }

    init(typography: DiffsTypography, theme: ResolvedDiffsTheme, themeType: ThemeType, systemIsDark: Bool, overrides: DiffsColorOverrides) {
        self.typography = typography
        self.theme = theme
        let isDark = theme.isDark(themeType: themeType, systemIsDark: systemIsDark)
        self.isDark = isDark
        palette = DiffsPalette(theme: isDark ? theme.dark : theme.light, isDark: isDark, overrides: overrides)
        styleIndex = theme.styleIndex(isDark: isDark)

        let base = typography.codeFont
        let manager = NSFontManager.shared
        regularFont = base as CTFont
        boldFont = manager.convert(base, toHaveTrait: .boldFontMask) as CTFont
        italicFont = Self.italic(base) as CTFont
        boldItalicFont = Self.italic(manager.convert(base, toHaveTrait: .boldFontMask)) as CTFont
        headerFont = typography.headerFont
        headerBoldFont = manager.convert(typography.headerFont, toHaveTrait: .boldFontMask)

        var glyph = CGGlyph(0)
        var zero: UniChar = 0x30
        CTFontGetGlyphsForCharacters(regularFont, &zero, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regularFont, .horizontal, &glyph, &advance, 1)
        ch = advance.width > 0 ? advance.width : typography.codeFont.pointSize * 0.6
        lineHeight = typography.lineHeight
        ascent = CTFontGetAscent(regularFont)
        descent = CTFontGetDescent(regularFont)
        contentHeight = ascent + descent
        // CSS centers the font's content area within the line box
        // (half-leading on each side).
        baseline = ((typography.lineHeight - (ascent + descent)) / 2 + ascent).rounded()
    }

    private static func italic(_ font: NSFont) -> NSFont {
        let manager = NSFontManager.shared
        let converted = manager.convert(font, toHaveTrait: .italicFontMask)
        if manager.traits(of: converted).contains(.italicFontMask) { return converted }
        // Monospaced fonts without an italic face get an oblique matrix,
        // like the browser's synthesized italics.
        let matrix = AffineTransform(m11: 1, m12: 0, m21: 0.2, m22: 1, tX: 0, tY: 0)
        let descriptor = font.fontDescriptor.withMatrix(matrix)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    func font(for style: FontStyle) -> CTFont {
        switch (style.contains(.bold), style.contains(.italic)) {
        case (true, true): return boldItalicFont
        case (true, false): return boldFont
        case (false, true): return italicFont
        default: return regularFont
        }
    }

    func cgColor(_ color: RGBAColor) -> CGColor {
        CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a)
    }

    /// Attributes shared by every code line: font, default color, tab stops.
    private(set) lazy var baseTextAttributes: CFDictionary = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = CGFloat(typography.tabSize) * ch
        paragraph.tabStops = []
        paragraph.lineBreakMode = .byCharWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: regularFont,
            .foregroundColor: cgColor(palette.fg),
            .paragraphStyle: paragraph,
            .ligature: 0,
        ]
        return attributes as CFDictionary
    }()

    /// Attributes for a token style, created once per style.
    func tokenAttributes(_ tokenStyle: TokenStyle, dimmed: Bool) -> CFDictionary {
        let key = TokenAttributesKey(style: tokenStyle, dimmed: dimmed)
        if let cached = tokenAttributesCache[key] { return cached }
        var color = tokenColor(tokenStyle.color)
        if dimmed { color = color.copy(alpha: color.alpha * 0.6) ?? color }
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
        if !tokenStyle.fontStyle.isEmpty {
            attributes[.font] = font(for: tokenStyle.fontStyle)
            if tokenStyle.fontStyle.contains(.underline) {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = color
            }
            if tokenStyle.fontStyle.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = color
            }
        }
        let dictionary = attributes as CFDictionary
        tokenAttributesCache[key] = dictionary
        return dictionary
    }

    /// Resolves a theme token color string (`#RRGGBB[AA]`).
    func tokenColor(_ value: String?) -> CGColor {
        guard let value else { return cgColor(palette.fg) }
        if let cached = colorCache[value] { return cached }
        let color = RGBAColor(css: value).map(cgColor) ?? cgColor(palette.fg)
        colorCache[value] = color
        return color
    }
}
