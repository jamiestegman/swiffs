// Port of Shiki's ANSI highlighting (`code-to-tokens-ansi.ts` and the
// bundled `ansi-sequence-parser`).

import Foundation

private let namedColors = [
    "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
    "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightMagenta", "brightCyan", "brightWhite",
]

private let decorationNames: [Int: String] = [
    1: "bold", 2: "dim", 3: "italic", 4: "underline", 7: "reverse", 8: "hidden", 9: "strikethrough",
]

/// Default ANSI palette (VS Code compatible fallbacks).
private let defaultAnsiColors: [String: String] = [
    "black": "#000000", "red": "#cd3131", "green": "#0DBC79", "yellow": "#E5E510",
    "blue": "#2472C8", "magenta": "#BC3FBC", "cyan": "#11A8CD", "white": "#E5E5E5",
    "brightBlack": "#666666", "brightRed": "#F14C4C", "brightGreen": "#23D18B", "brightYellow": "#F5F543",
    "brightBlue": "#3B8EEA", "brightMagenta": "#D670D6", "brightCyan": "#29B8DB", "brightWhite": "#FFFFFF",
]

enum AnsiColor: Hashable {
    case named(String)
    case rgb([Int])
    case table(Int)
}

struct AnsiToken {
    var value: String
    var foreground: AnsiColor?
    var background: AnsiColor?
    var decorations: Set<String>
}

final class AnsiSequenceParser {
    private var foreground: AnsiColor?
    private var background: AnsiColor?
    private var decorations: Set<String> = []

    private enum Command {
        case resetAll, resetForeground, resetBackground
        case resetDecoration(String), setDecoration(String)
        case setForeground(AnsiColor), setBackground(AnsiColor)
    }

    private static func parseColor(_ sequence: inout [String]) -> AnsiColor? {
        guard !sequence.isEmpty else { return nil }
        let colorMode = sequence.removeFirst()
        if colorMode == "2" {
            let parts = sequence.prefix(3).map { parseIntPrefix($0) }
            sequence.removeFirst(min(3, sequence.count))
            if parts.count != 3 || parts.contains(where: { $0 == nil }) { return nil }
            return .rgb(parts.map { $0! })
        } else if colorMode == "5" {
            guard !sequence.isEmpty else { return nil }
            let index = sequence.removeFirst()
            if !index.isEmpty { return .table(Int(Double(index) ?? .nan)) }
        }
        return nil
    }

    /// `Number.parseInt` semantics for decimal prefixes.
    private static func parseIntPrefix(_ value: String) -> Int? {
        let trimmed = value.drop { $0 == " " || $0 == "\t" }
        var digits = ""
        var iterator = trimmed.makeIterator()
        var first = true
        while let c = iterator.next() {
            if first, c == "-" || c == "+" { digits.append(c); first = false; continue }
            first = false
            if c.isASCII, c.isNumber { digits.append(c) } else { break }
        }
        return Int(digits)
    }

    private static func parseSequence(_ input: [String]) -> [Command] {
        var sequence = input
        var commands: [Command] = []
        while !sequence.isEmpty {
            let code = sequence.removeFirst()
            if code.isEmpty { continue }
            guard let codeInt = parseIntPrefix(code) else { continue }
            if codeInt == 0 {
                commands.append(.resetAll)
            } else if codeInt <= 9 {
                if let decoration = decorationNames[codeInt] { commands.append(.setDecoration(decoration)) }
            } else if codeInt <= 29 {
                if let decoration = decorationNames[codeInt - 20] {
                    commands.append(.resetDecoration(decoration))
                    if decoration == "dim" { commands.append(.resetDecoration("bold")) }
                }
            } else if codeInt <= 37 {
                commands.append(.setForeground(.named(namedColors[codeInt - 30])))
            } else if codeInt == 38 {
                if let color = parseColor(&sequence) { commands.append(.setForeground(color)) }
            } else if codeInt == 39 {
                commands.append(.resetForeground)
            } else if codeInt <= 47 {
                commands.append(.setBackground(.named(namedColors[codeInt - 40])))
            } else if codeInt == 48 {
                if let color = parseColor(&sequence) { commands.append(.setBackground(color)) }
            } else if codeInt == 49 {
                commands.append(.resetBackground)
            } else if codeInt == 53 {
                commands.append(.setDecoration("overline"))
            } else if codeInt == 55 {
                commands.append(.resetDecoration("overline"))
            } else if codeInt >= 90, codeInt <= 97 {
                commands.append(.setForeground(.named(namedColors[codeInt - 90 + 8])))
            } else if codeInt >= 100, codeInt <= 107 {
                commands.append(.setBackground(.named(namedColors[codeInt - 100 + 8])))
            }
        }
        return commands
    }

    func parse(_ value: String) -> [AnsiToken] {
        let units = Array(value.utf16)
        var tokens: [AnsiToken] = []
        var position = 0
        repeat {
            // findSequence
            var sequence: [String]?
            var startPosition = units.count
            var nextPosition = units.count
            if let nextEscape = units[position...].firstIndex(of: 0x1B),
               nextEscape + 1 < units.count, units[nextEscape + 1] == 0x5B, // [
               let nextClose = units[nextEscape...].firstIndex(of: 0x6D) // m
            {
                sequence = String(decoding: units[(nextEscape + 2) ..< nextClose], as: UTF16.self)
                    .split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                startPosition = nextEscape
                nextPosition = nextClose + 1
            }
            let textEnd = sequence != nil ? startPosition : units.count
            if textEnd > position {
                tokens.append(AnsiToken(
                    value: String(decoding: units[position ..< textEnd], as: UTF16.self),
                    foreground: foreground,
                    background: background,
                    decorations: decorations
                ))
            }
            if let sequence {
                let commands = Self.parseSequence(sequence)
                for command in commands {
                    switch command {
                    case .resetAll:
                        foreground = nil
                        background = nil
                        decorations.removeAll()
                    case .resetForeground: foreground = nil
                    case .resetBackground: background = nil
                    case .resetDecoration(let value): decorations.remove(value)
                    default: break
                    }
                }
                for command in commands {
                    switch command {
                    case .setForeground(let color): foreground = color
                    case .setBackground(let color): background = color
                    case .setDecoration(let value): decorations.insert(value)
                    default: break
                    }
                }
            }
            position = nextPosition
        } while position < units.count
        return tokens
    }
}

private final class AnsiColorPalette {
    private let named: [String: String]
    private lazy var table: [String] = {
        var table = namedColors.map { named[$0] ?? "" }
        let levels = [0, 95, 135, 175, 215, 255]
        for r in 0 ..< 6 {
            for g in 0 ..< 6 {
                for b in 0 ..< 6 {
                    table.append(Self.rgb([levels[r], levels[g], levels[b]]))
                }
            }
        }
        var level = 8
        for _ in 0 ..< 24 {
            table.append(Self.rgb([level, level, level]))
            level += 10
        }
        return table
    }()

    init(named: [String: String]) {
        self.named = named
    }

    static func rgb(_ rgb: [Int]) -> String {
        "#" + rgb.map { value in
            let hex = String(max(0, min(value, 255)), radix: 16)
            return hex.count < 2 ? "0" + hex : hex
        }.joined()
    }

    func value(_ color: AnsiColor) -> String? {
        switch color {
        case .named(let name): return named[name]
        case .rgb(let rgb): return Self.rgb(rgb)
        case .table(let index): return index >= 0 && index < table.count ? table[index] : nil
        }
    }
}

/// Adds 50% alpha to a hex color string.
func dimColor(_ color: String) -> String {
    let utf8 = Array(color.utf8)
    guard let hashIndex = utf8.firstIndex(of: UInt8(ascii: "#")) else { return color }
    var hex = ""
    for b in utf8[(hashIndex + 1)...] {
        let isHex = (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
        if !isHex || hex.count == 8 { break }
        hex.append(Character(UnicodeScalar(b)))
    }
    guard hex.count >= 3 else { return color }
    let chars = Array(hex)
    func halfAlpha(_ value: String) -> String {
        let alpha = Int((Double(Int(value, radix: 16) ?? 0) / 2).rounded())
        let result = String(alpha, radix: 16)
        return result.count < 2 ? "0" + result : result
    }
    switch chars.count {
    case 8: return "#\(String(chars[0 ..< 6]))\(halfAlpha(String(chars[6 ..< 8])))"
    case 6, 7: return "#\(String(chars[0 ..< 6]))80"
    case 4:
        let (r, g, b, a) = (chars[0], chars[1], chars[2], chars[3])
        return "#\(r)\(r)\(g)\(g)\(b)\(b)\(halfAlpha("\(a)\(a)"))"
    case 3:
        let (r, g, b) = (chars[0], chars[1], chars[2])
        return "#\(r)\(r)\(g)\(g)\(b)\(b)80"
    default: return color
    }
}

/// Shiki `tokenizeAnsiWithTheme`.
func tokenizeAnsiWithTheme(_ code: String, theme: ThemeRegistration) -> [[ThemedToken]] {
    var named: [String: String] = [:]
    for name in namedColors {
        let key = "terminal.ansi" + name.prefix(1).uppercased() + name.dropFirst()
        named[name] = (theme.colors[key].flatMap { $0.isEmpty ? nil : $0 }) ?? defaultAnsiColors[name]
    }
    let palette = AnsiColorPalette(named: named)
    let parser = AnsiSequenceParser()
    return shikiSplitLines(code).map { line, offset in
        parser.parse(line).map { token in
            var color: String?
            if token.decorations.contains("reverse") {
                color = token.background.flatMap { palette.value($0) } ?? theme.bg
            } else {
                color = token.foreground.flatMap { palette.value($0) } ?? theme.fg
            }
            color = applyColorReplacements(color, theme.colorReplacements)
            if token.decorations.contains("dim"), let current = color {
                color = dimColor(current)
            }
            var fontStyle: FontStyle = []
            if token.decorations.contains("bold") { fontStyle.insert(.bold) }
            if token.decorations.contains("italic") { fontStyle.insert(.italic) }
            if token.decorations.contains("underline") { fontStyle.insert(.underline) }
            if token.decorations.contains("strikethrough") { fontStyle.insert(.strikethrough) }
            return ThemedToken(content: token.value, offset: offset, color: color, fontStyle: fontStyle)
        }
    }
}
