// Port of vscode-textmate `theme.ts`.

import Foundation

public struct FontStyle: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let italic = FontStyle(rawValue: 1)
    public static let bold = FontStyle(rawValue: 2)
    public static let underline = FontStyle(rawValue: 4)
    public static let strikethrough = FontStyle(rawValue: 8)

    /// `FontStyle.NotSet` (-1).
    static let notSet = -1
}

/// A theme token color rule (`IRawThemeSetting`).
public struct RawThemeSetting: Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        case string(String)
        case array([String])
    }

    public var name: String?
    public var scope: Scope?
    public var fontStyle: String?
    public var foreground: String?
    public var background: String?
    /// True when the entry had a `settings` object.
    public var hasSettings: Bool

    public init(
        name: String? = nil,
        scope: Scope? = nil,
        fontStyle: String? = nil,
        foreground: String? = nil,
        background: String? = nil,
        hasSettings: Bool = true
    ) {
        self.name = name
        self.scope = scope
        self.fontStyle = fontStyle
        self.foreground = foreground
        self.background = background
        self.hasSettings = hasSettings
    }
}

final class ScopeStack {
    let parent: ScopeStack?
    let scopeName: String

    init(_ parent: ScopeStack?, _ scopeName: String) {
        self.parent = parent
        self.scopeName = scopeName
    }

    static func push(_ path: ScopeStack?, _ scopeNames: [String]) -> ScopeStack? {
        var path = path
        for name in scopeNames {
            path = ScopeStack(path, name)
        }
        return path
    }

    static func from(_ segments: [String]) -> ScopeStack? {
        var result: ScopeStack?
        for segment in segments {
            result = ScopeStack(result, segment)
        }
        return result
    }

    func push(_ scopeName: String) -> ScopeStack {
        ScopeStack(self, scopeName)
    }

    func getSegments() -> [String] {
        var result: [String] = []
        var item: ScopeStack? = self
        while let current = item {
            result.append(current.scopeName)
            item = current.parent
        }
        return result.reversed()
    }

    func extends(_ other: ScopeStack) -> Bool {
        if self === other { return true }
        guard let parent else { return false }
        return parent.extends(other)
    }

    func getExtensionIfDefined(_ base: ScopeStack?) -> [String]? {
        var result: [String] = []
        var item: ScopeStack? = self
        while let current = item, current !== base {
            result.append(current.scopeName)
            item = current.parent
        }
        return item === base ? result.reversed() : nil
    }
}

struct StyleAttributes: Equatable {
    var fontStyle: Int
    var foregroundId: Int
    var backgroundId: Int
}

struct ParsedThemeRule {
    var scope: String
    var parentScopes: [String]?
    var index: Int
    var fontStyle: Int
    var foreground: String?
    var background: String?
}

func isValidHexColor(_ hex: String) -> Bool {
    let bytes = Array(hex.utf8)
    guard bytes.first == UInt8(ascii: "#") else { return false }
    let digits = bytes.dropFirst()
    guard [3, 4, 6, 8].contains(digits.count) else { return false }
    return digits.allSatisfy { b in
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
    }
}

func parseTheme(_ settings: [RawThemeSetting]) -> [ParsedThemeRule] {
    var result: [ParsedThemeRule] = []
    for (i, entry) in settings.enumerated() {
        guard entry.hasSettings else { continue }
        var scopes: [String]
        switch entry.scope {
        case .string(let value):
            var scope = Substring(value)
            while scope.first == "," { scope = scope.dropFirst() }
            while scope.last == "," { scope = scope.dropLast() }
            scopes = scope.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        case .array(let values):
            scopes = values
        case nil:
            scopes = [""]
        }

        var fontStyle = FontStyle.notSet
        if let raw = entry.fontStyle {
            fontStyle = 0
            for segment in raw.split(separator: " ", omittingEmptySubsequences: false) {
                switch segment {
                case "italic": fontStyle |= FontStyle.italic.rawValue
                case "bold": fontStyle |= FontStyle.bold.rawValue
                case "underline": fontStyle |= FontStyle.underline.rawValue
                case "strikethrough": fontStyle |= FontStyle.strikethrough.rawValue
                default: break
                }
            }
        }
        var foreground: String?
        if let value = entry.foreground, isValidHexColor(value) { foreground = value }
        var background: String?
        if let value = entry.background, isValidHexColor(value) { background = value }

        for scopeEntry in scopes {
            let trimmed = scopeEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            let segments = trimmed.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            let scope = segments[segments.count - 1]
            var parentScopes: [String]?
            if segments.count > 1 {
                parentScopes = Array(segments[0 ..< segments.count - 1].reversed())
            }
            result.append(ParsedThemeRule(
                scope: scope,
                parentScopes: parentScopes,
                index: i,
                fontStyle: fontStyle,
                foreground: foreground,
                background: background
            ))
        }
    }
    return result
}

/// JavaScript string comparison (`<` / `>`) is by UTF-16 code units.
func jsStringCompare(_ a: String, _ b: String) -> Int {
    var ai = a.utf16.makeIterator()
    var bi = b.utf16.makeIterator()
    while true {
        switch (ai.next(), bi.next()) {
        case (nil, nil): return 0
        case (nil, _): return -1
        case (_, nil): return 1
        case let (x?, y?):
            if x != y { return x < y ? -1 : 1 }
        }
    }
}

func strArrCmp(_ a: [String]?, _ b: [String]?) -> Int {
    if a == nil, b == nil { return 0 }
    guard let a else { return -1 }
    guard let b else { return 1 }
    if a.count == b.count {
        for i in 0 ..< a.count {
            let res = jsStringCompare(a[i], b[i])
            if res != 0 { return res }
        }
        return 0
    }
    return a.count - b.count
}

final class ColorMap {
    private let isFrozen: Bool
    private var lastColorId = 0
    private var id2color: [String] = []
    private var color2id: [String: Int] = [:]

    init(_ colorMap: [String]?) {
        if let colorMap {
            isFrozen = true
            for (i, color) in colorMap.enumerated() {
                color2id[color] = i
                id2color.append(color)
            }
        } else {
            isFrozen = false
            id2color = [""]
        }
    }

    func getId(_ color: String?) -> Int {
        guard let color else { return 0 }
        let upper = color.uppercased()
        if let value = color2id[upper], value != 0 { return value }
        if isFrozen {
            // vscode-textmate throws here; fall back to the default color.
            return 0
        }
        lastColorId += 1
        color2id[upper] = lastColorId
        if id2color.count <= lastColorId {
            id2color.append(upper)
        } else {
            id2color[lastColorId] = upper
        }
        return lastColorId
    }

    func getColorMap() -> [String] {
        id2color
    }
}

final class ThemeTrieElementRule {
    var scopeDepth: Int
    let parentScopes: [String]
    var fontStyle: Int
    var foreground: Int
    var background: Int

    init(_ scopeDepth: Int, _ parentScopes: [String]?, _ fontStyle: Int, _ foreground: Int, _ background: Int) {
        self.scopeDepth = scopeDepth
        self.parentScopes = parentScopes ?? []
        self.fontStyle = fontStyle
        self.foreground = foreground
        self.background = background
    }

    func clone() -> ThemeTrieElementRule {
        ThemeTrieElementRule(scopeDepth, parentScopes, fontStyle, foreground, background)
    }

    func acceptOverwrite(_ scopeDepth: Int, _ fontStyle: Int, _ foreground: Int, _ background: Int) {
        if self.scopeDepth <= scopeDepth {
            self.scopeDepth = scopeDepth
        }
        if fontStyle != FontStyle.notSet { self.fontStyle = fontStyle }
        if foreground != 0 { self.foreground = foreground }
        if background != 0 { self.background = background }
    }
}

final class ThemeTrieElement {
    private let mainRule: ThemeTrieElementRule
    private var rulesWithParentScopes: [ThemeTrieElementRule]
    private var children: [String: ThemeTrieElement]

    init(_ mainRule: ThemeTrieElementRule, _ rulesWithParentScopes: [ThemeTrieElementRule] = [], _ children: [String: ThemeTrieElement] = [:]) {
        self.mainRule = mainRule
        self.rulesWithParentScopes = rulesWithParentScopes
        self.children = children
    }

    private static func cmpBySpecificity(_ a: ThemeTrieElementRule, _ b: ThemeTrieElementRule) -> Int {
        if a.scopeDepth != b.scopeDepth {
            return b.scopeDepth - a.scopeDepth
        }
        var aParentIndex = 0
        var bParentIndex = 0
        while true {
            if aParentIndex < a.parentScopes.count, a.parentScopes[aParentIndex] == ">" { aParentIndex += 1 }
            if bParentIndex < b.parentScopes.count, b.parentScopes[bParentIndex] == ">" { bParentIndex += 1 }
            if aParentIndex >= a.parentScopes.count || bParentIndex >= b.parentScopes.count { break }
            let diff = b.parentScopes[bParentIndex].utf16.count - a.parentScopes[aParentIndex].utf16.count
            if diff != 0 { return diff }
            aParentIndex += 1
            bParentIndex += 1
        }
        return b.parentScopes.count - a.parentScopes.count
    }

    func match(_ scope: Substring) -> [ThemeTrieElementRule] {
        if !scope.isEmpty {
            let head: Substring
            let tail: Substring
            if let dotIndex = scope.firstIndex(of: ".") {
                head = scope[..<dotIndex]
                tail = scope[scope.index(after: dotIndex)...]
            } else {
                head = scope
                tail = ""
            }
            if let child = children[String(head)] {
                return child.match(tail)
            }
        }
        let rules = rulesWithParentScopes + [mainRule]
        // Stable sort (Array.prototype.sort is stable).
        return rules.enumerated().sorted { lhs, rhs in
            let c = ThemeTrieElement.cmpBySpecificity(lhs.element, rhs.element)
            return c != 0 ? c < 0 : lhs.offset < rhs.offset
        }.map(\.element)
    }

    func insert(_ scopeDepth: Int, _ scope: Substring, _ parentScopes: [String]?, _ fontStyle: Int, _ foreground: Int, _ background: Int) {
        if scope.isEmpty {
            doInsertHere(scopeDepth, parentScopes, fontStyle, foreground, background)
            return
        }
        let head: Substring
        let tail: Substring
        if let dotIndex = scope.firstIndex(of: ".") {
            head = scope[..<dotIndex]
            tail = scope[scope.index(after: dotIndex)...]
        } else {
            head = scope
            tail = ""
        }
        let key = String(head)
        let child: ThemeTrieElement
        if let existing = children[key] {
            child = existing
        } else {
            child = ThemeTrieElement(mainRule.clone(), rulesWithParentScopes.map { $0.clone() })
            children[key] = child
        }
        child.insert(scopeDepth + 1, tail, parentScopes, fontStyle, foreground, background)
    }

    private func doInsertHere(_ scopeDepth: Int, _ parentScopes: [String]?, _ fontStyle: Int, _ foreground: Int, _ background: Int) {
        guard let parentScopes else {
            mainRule.acceptOverwrite(scopeDepth, fontStyle, foreground, background)
            return
        }
        for rule in rulesWithParentScopes where strArrCmp(rule.parentScopes, parentScopes) == 0 {
            rule.acceptOverwrite(scopeDepth, fontStyle, foreground, background)
            return
        }
        var fontStyle = fontStyle
        var foreground = foreground
        var background = background
        if fontStyle == FontStyle.notSet { fontStyle = mainRule.fontStyle }
        if foreground == 0 { foreground = mainRule.foreground }
        if background == 0 { background = mainRule.background }
        rulesWithParentScopes.append(ThemeTrieElementRule(scopeDepth, parentScopes, fontStyle, foreground, background))
    }
}

/// A compiled TextMate theme.
final class TextMateTheme {
    private let colorMap: ColorMap
    let defaults: StyleAttributes
    private let root: ThemeTrieElement
    private var cachedMatchRoot: [String: [ThemeTrieElementRule]] = [:]

    private init(colorMap: ColorMap, defaults: StyleAttributes, root: ThemeTrieElement) {
        self.colorMap = colorMap
        self.defaults = defaults
        self.root = root
    }

    static func createFromRawTheme(_ settings: [RawThemeSetting], colorMap: [String]? = nil) -> TextMateTheme {
        createFromParsedTheme(parseTheme(settings), colorMap: colorMap)
    }

    static func createFromParsedTheme(_ source: [ParsedThemeRule], colorMap: [String]?) -> TextMateTheme {
        var rules = source.enumerated().sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            var r = jsStringCompare(a.scope, b.scope)
            if r == 0 { r = strArrCmp(a.parentScopes, b.parentScopes) }
            if r == 0 { r = a.index - b.index }
            return r != 0 ? r < 0 : lhs.offset < rhs.offset
        }.map(\.element)

        var defaultFontStyle = 0
        var defaultForeground = "#000000"
        var defaultBackground = "#ffffff"
        while let first = rules.first, first.scope.isEmpty {
            rules.removeFirst()
            if first.fontStyle != FontStyle.notSet { defaultFontStyle = first.fontStyle }
            if let foreground = first.foreground { defaultForeground = foreground }
            if let background = first.background { defaultBackground = background }
        }
        let colorMap = ColorMap(colorMap)
        let defaults = StyleAttributes(
            fontStyle: defaultFontStyle,
            foregroundId: colorMap.getId(defaultForeground),
            backgroundId: colorMap.getId(defaultBackground)
        )
        let root = ThemeTrieElement(ThemeTrieElementRule(0, nil, FontStyle.notSet, 0, 0), [])
        for rule in rules {
            root.insert(0, Substring(rule.scope), rule.parentScopes, rule.fontStyle, colorMap.getId(rule.foreground), colorMap.getId(rule.background))
        }
        return TextMateTheme(colorMap: colorMap, defaults: defaults, root: root)
    }

    func getColorMap() -> [String] {
        colorMap.getColorMap()
    }

    func match(_ scopePath: ScopeStack?) -> StyleAttributes? {
        guard let scopePath else { return defaults }
        let scopeName = scopePath.scopeName
        let matching: [ThemeTrieElementRule]
        if let cached = cachedMatchRoot[scopeName] {
            matching = cached
        } else {
            matching = root.match(Substring(scopeName))
            cachedMatchRoot[scopeName] = matching
        }
        guard let effectiveRule = matching.first(where: { scopePathMatchesParentScopes(scopePath.parent, $0.parentScopes) }) else {
            return nil
        }
        return StyleAttributes(
            fontStyle: effectiveRule.fontStyle,
            foregroundId: effectiveRule.foreground,
            backgroundId: effectiveRule.background
        )
    }
}

private func scopePathMatchesParentScopes(_ scopePath: ScopeStack?, _ parentScopes: [String]) -> Bool {
    if parentScopes.isEmpty { return true }
    var scopePath = scopePath
    var index = 0
    while index < parentScopes.count {
        var scopePattern = parentScopes[index]
        var scopeMustMatch = false
        if scopePattern == ">" {
            if index == parentScopes.count - 1 { return false }
            index += 1
            scopePattern = parentScopes[index]
            scopeMustMatch = true
        }
        while let current = scopePath {
            if matchesScope(current.scopeName, scopePattern) { break }
            if scopeMustMatch { return false }
            scopePath = current.parent
        }
        guard let current = scopePath else { return false }
        scopePath = current.parent
        index += 1
    }
    return true
}

private func matchesScope(_ scopeName: String, _ scopePattern: String) -> Bool {
    if scopePattern == scopeName { return true }
    guard scopeName.hasPrefix(scopePattern) else { return false }
    let utf8 = scopeName.utf8
    let index = utf8.index(utf8.startIndex, offsetBy: scopePattern.utf8.count)
    return index < utf8.endIndex && utf8[index] == UInt8(ascii: ".")
}
