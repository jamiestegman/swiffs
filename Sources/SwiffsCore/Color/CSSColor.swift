// CSS color parsing and the color math `style.css` relies on:
// `color-mix(in lab, ...)` and relative `rgb(from ... r g b / a)`.

import Foundation

/// An sRGB color with alpha, components in 0...1.
public struct RGBAColor: Hashable, Sendable, CustomStringConvertible {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let black = RGBAColor(r: 0, g: 0, b: 0)
    public static let white = RGBAColor(r: 1, g: 1, b: 1)
    public static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)

    /// Parses `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()`/`rgba()`,
    /// `transparent` and a few named colors.
    public init?(css value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("#") {
            let hex = Array(trimmed.dropFirst())
            func component(_ chars: ArraySlice<Character>) -> Double? {
                guard let v = Int(String(chars), radix: 16) else { return nil }
                return Double(v) / 255
            }
            switch hex.count {
            case 3, 4:
                let expanded = hex.flatMap { [$0, $0] }
                guard let r = component(expanded[0 ..< 2]), let g = component(expanded[2 ..< 4]), let b = component(expanded[4 ..< 6]) else { return nil }
                let a = hex.count == 4 ? (component(expanded[6 ..< 8]) ?? 1) : 1
                self.init(r: r, g: g, b: b, a: a)
            case 6, 8:
                guard let r = component(hex[0 ..< 2]), let g = component(hex[2 ..< 4]), let b = component(hex[4 ..< 6]) else { return nil }
                let a = hex.count == 8 ? (component(hex[6 ..< 8]) ?? 1) : 1
                self.init(r: r, g: g, b: b, a: a)
            default:
                return nil
            }
            return
        }
        if trimmed.hasPrefix("rgb") {
            guard let open = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")") else { return nil }
            let inner = trimmed[trimmed.index(after: open) ..< close]
            let parts = inner.replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: ",", with: " ")
                .split(separator: " ").map(String.init)
            guard parts.count >= 3 else { return nil }
            func channel(_ part: String) -> Double? {
                if part.hasSuffix("%") { return Double(part.dropLast()).map { $0 / 100 } }
                return Double(part).map { $0 / 255 }
            }
            func alpha(_ part: String) -> Double? {
                if part.hasSuffix("%") { return Double(part.dropLast()).map { $0 / 100 } }
                return Double(part)
            }
            guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
            self.init(r: r, g: g, b: b, a: parts.count > 3 ? (alpha(parts[3]) ?? 1) : 1)
            return
        }
        switch trimmed {
        case "transparent": self = .clear
        case "black": self = .black
        case "white": self = .white
        case "red": self.init(r: 1, g: 0, b: 0)
        case "green": self.init(r: 0, g: 128.0 / 255, b: 0)
        case "blue": self.init(r: 0, g: 0, b: 1)
        default: return nil
        }
    }

    /// `rgb(from <color> r g b / alpha)`.
    public func withAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(r: r, g: g, b: b, a: alpha)
    }

    /// `#rrggbb` / `#rrggbbaa` representation.
    public var hexString: String {
        func hex(_ v: Double) -> String {
            let value = Int((max(0, min(1, v)) * 255).rounded())
            let s = String(value, radix: 16)
            return s.count < 2 ? "0" + s : s
        }
        return "#" + hex(r) + hex(g) + hex(b) + (a < 1 ? hex(a) : "")
    }

    public var description: String { hexString }

    // MARK: Lab conversion (CSS Color 4)

    private static func toLinear(_ c: Double) -> Double {
        let sign: Double = c < 0 ? -1 : 1
        let abs = Swift.abs(c)
        if abs <= 0.04045 { return c / 12.92 }
        return sign * pow((abs + 0.055) / 1.055, 2.4)
    }

    private static func fromLinear(_ c: Double) -> Double {
        let sign: Double = c < 0 ? -1 : 1
        let abs = Swift.abs(c)
        if abs > 0.0031308 { return sign * (1.055 * pow(abs, 1 / 2.4) - 0.055) }
        return 12.92 * c
    }

    /// CIE Lab (D50) components.
    public struct Lab: Hashable, Sendable {
        public var l: Double
        public var a: Double
        public var b: Double
    }

    public var lab: Lab {
        let lr = Self.toLinear(r), lg = Self.toLinear(g), lb = Self.toLinear(b)
        // linear sRGB -> XYZ D65
        let x65 = 0.41239079926595934 * lr + 0.357584339383878 * lg + 0.1804807884018343 * lb
        let y65 = 0.21263900587151027 * lr + 0.715168678767756 * lg + 0.07219231536073371 * lb
        let z65 = 0.01933081871559182 * lr + 0.11919477979462598 * lg + 0.9505321522496607 * lb
        // Bradford D65 -> D50
        let x = 1.0479298208405488 * x65 + 0.022946793341019088 * y65 - 0.05019222954313557 * z65
        let y = 0.029627815688159344 * x65 + 0.990434484573249 * y65 - 0.01707382502938514 * z65
        let z = -0.009243058152591178 * x65 + 0.015055144896577895 * y65 + 0.7518742899580008 * z65
        let d50 = (0.3457 / 0.3585, 1.0, (1 - 0.3457 - 0.3585) / 0.3585)
        let epsilon = 216.0 / 24389.0
        let kappa = 24389.0 / 27.0
        func f(_ v: Double) -> Double { v > epsilon ? cbrt(v) : (kappa * v + 16) / 116 }
        let fx = f(x / d50.0), fy = f(y / d50.1), fz = f(z / d50.2)
        return Lab(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    public init(lab: Lab, alpha: Double = 1) {
        let epsilon = 216.0 / 24389.0
        let kappa = 24389.0 / 27.0
        let d50 = (0.3457 / 0.3585, 1.0, (1 - 0.3457 - 0.3585) / 0.3585)
        let fy = (lab.l + 16) / 116
        let fx = lab.a / 500 + fy
        let fz = fy - lab.b / 200
        let x = (pow(fx, 3) > epsilon ? pow(fx, 3) : (116 * fx - 16) / kappa) * d50.0
        let y = (lab.l > kappa * epsilon ? pow((lab.l + 16) / 116, 3) : lab.l / kappa) * d50.1
        let z = (pow(fz, 3) > epsilon ? pow(fz, 3) : (116 * fz - 16) / kappa) * d50.2
        // Bradford D50 -> D65
        let x65 = 0.955473421488075 * x - 0.02309845494876471 * y + 0.06325924320057072 * z
        let y65 = -0.0283697093338637 * x + 1.0099953980813041 * y + 0.021041441191917323 * z
        let z65 = 0.012314014864481998 * x - 0.020507649298898964 * y + 1.330365926242124 * z
        // XYZ D65 -> linear sRGB
        let lr = 3.2409699419045226 * x65 - 1.537383177570094 * y65 - 0.4986107602930034 * z65
        let lg = -0.9692436362808796 * x65 + 1.8759675015077202 * y65 + 0.04155505740717559 * z65
        let lb = 0.05563007969699366 * x65 - 0.20397695888897652 * y65 + 1.0569715142428786 * z65
        self.init(
            r: max(0, min(1, Self.fromLinear(lr))),
            g: max(0, min(1, Self.fromLinear(lg))),
            b: max(0, min(1, Self.fromLinear(lb))),
            a: alpha
        )
    }

    /// `color-mix(in lab, self <percentage>, other)` where `percentage` is
    /// 0...100 for `self`.
    public func mix(_ other: RGBAColor, _ percentage: Double) -> RGBAColor {
        let p1 = max(0, min(100, percentage)) / 100
        let p2 = 1 - p1
        let alpha = a * p1 + other.a * p2
        if alpha == 0 { return .clear }
        let l1 = lab, l2 = other.lab
        // Premultiplied interpolation.
        let l = (l1.l * a * p1 + l2.l * other.a * p2) / alpha
        let aa = (l1.a * a * p1 + l2.a * other.a * p2) / alpha
        let bb = (l1.b * a * p1 + l2.b * other.a * p2) / alpha
        return RGBAColor(lab: Lab(l: l, a: aa, b: bb), alpha: alpha)
    }

    /// Composites `self` over an opaque `background` (for drawing
    /// semi-transparent colors on known surfaces).
    public func over(_ background: RGBAColor) -> RGBAColor {
        let outA = a + background.a * (1 - a)
        if outA == 0 { return .clear }
        return RGBAColor(
            r: (r * a + background.r * background.a * (1 - a)) / outA,
            g: (g * a + background.g * background.a * (1 - a)) / outA,
            b: (b * a + background.b * background.a * (1 - a)) / outA,
            a: outA
        )
    }
}
