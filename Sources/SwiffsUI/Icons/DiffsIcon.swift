// The Diffs icon sprite (`sprite.ts`), rendered natively from the SVG paths.

import CoreGraphics
import Foundation

struct DiffsIconPath {
    var d: String
    var evenOdd: Bool
    var opacity: CGFloat
}

struct DiffsIconDefinition {
    var viewBox: CGRect
    var paths: [DiffsIconPath]
}

/// Icons from the upstream sprite sheet.
public enum DiffsIcon: String, CaseIterable, Sendable {
    case arrowRightShort = "diffs-icon-arrow-right-short"
    case brandGithub = "diffs-icon-brand-github"
    case chevron = "diffs-icon-chevron"
    case chevronsNarrow = "diffs-icon-chevrons-narrow"
    case diffSplit = "diffs-icon-diff-split"
    case diffUnified = "diffs-icon-diff-unified"
    case expand = "diffs-icon-expand"
    case expandAll = "diffs-icon-expand-all"
    case eyeSlash = "diffs-icon-eye-slash"
    case fileCode = "diffs-icon-file-code"
    case plus = "diffs-icon-plus"
    case symbolAdded = "diffs-icon-symbol-added"
    case symbolAddedDuo = "diffs-icon-symbol-added-duo"
    case symbolAddedFill = "diffs-icon-symbol-added-fill"
    case symbolDeleted = "diffs-icon-symbol-deleted"
    case symbolDeletedDuo = "diffs-icon-symbol-deleted-duo"
    case symbolDeletedFill = "diffs-icon-symbol-deleted-fill"
    case symbolDiffstat = "diffs-icon-symbol-diffstat"
    case symbolDiffstatDuo = "diffs-icon-symbol-diffstat-duo"
    case symbolDiffstatFill = "diffs-icon-symbol-diffstat-fill"
    case symbolExtracted = "diffs-icon-symbol-extracted"
    case symbolExtractedDuo = "diffs-icon-symbol-extracted-duo"
    case symbolExtractedFill = "diffs-icon-symbol-extracted-fill"
    case symbolIgnored = "diffs-icon-symbol-ignored"
    case symbolIgnoredDuo = "diffs-icon-symbol-ignored-duo"
    case symbolIgnoredFill = "diffs-icon-symbol-ignored-fill"
    case symbolInlined = "diffs-icon-symbol-inlined"
    case symbolInlinedDuo = "diffs-icon-symbol-inlined-duo"
    case symbolInlinedFill = "diffs-icon-symbol-inlined-fill"
    case symbolModified = "diffs-icon-symbol-modified"
    case symbolModifiedDuo = "diffs-icon-symbol-modified-duo"
    case symbolModifiedFill = "diffs-icon-symbol-modified-fill"
    case symbolMoved = "diffs-icon-symbol-moved"
    case symbolMovedDuo = "diffs-icon-symbol-moved-duo"
    case symbolMovedFill = "diffs-icon-symbol-moved-fill"
    case symbolRef = "diffs-icon-symbol-ref"

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var paths: [DiffsIcon: [(CGPath, Bool, CGFloat)]] = [:]
    }

    private static let cache = Cache()

    /// The icon's view box.
    public var viewBox: CGRect {
        Self.definitions[rawValue]?.viewBox ?? CGRect(x: 0, y: 0, width: 16, height: 16)
    }

    /// Parsed paths in view box coordinates (y down), with fill rule and
    /// opacity.
    func paths() -> [(CGPath, Bool, CGFloat)] {
        Self.cache.lock.withLock {
            if let cached = Self.cache.paths[self] { return cached }
            let parsed = (Self.definitions[rawValue]?.paths ?? []).map { path in
                (SVGPathParser.parse(path.d), path.evenOdd, path.opacity)
            }
            Self.cache.paths[self] = parsed
            return parsed
        }
    }

    /// Draws the icon filling `rect` with `color` (the sprite uses
    /// `fill: currentColor`).
    public func draw(in context: CGContext, rect: CGRect, color: CGColor) {
        let box = viewBox
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        for (path, evenOdd, opacity) in paths() {
            context.addPath(path)
            context.setFillColor(color.copy(alpha: color.alpha * opacity) ?? color)
            context.fillPath(using: evenOdd ? .evenOdd : .winding)
        }
        context.restoreGState()
    }
}

/// Minimal SVG path data parser (M L H V C S Q T A Z and relative forms).
enum SVGPathParser {
    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = NumberScanner(Array(d.utf8))
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: UInt8 = 0
        while let next = scanner.nextCommandOrNumber() {
            if case .command(let c) = next {
                command = c
                if c == UInt8(ascii: "Z") || c == UInt8(ascii: "z") {
                    path.closeSubpath()
                    current = start
                    lastControl = nil
                    lastQuadControl = nil
                }
                continue
            }
            scanner.pushBack()
            let relative = command >= UInt8(ascii: "a")
            func point() -> CGPoint {
                let x = scanner.number(), y = scanner.number()
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch command | 0x20 { // lowercase
            case UInt8(ascii: "m"):
                current = point()
                start = current
                path.move(to: current)
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
                lastControl = nil
                lastQuadControl = nil
            case UInt8(ascii: "l"):
                current = point()
                path.addLine(to: current)
                lastControl = nil
                lastQuadControl = nil
            case UInt8(ascii: "h"):
                let x = scanner.number()
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
                lastQuadControl = nil
            case UInt8(ascii: "v"):
                let y = scanner.number()
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil
                lastQuadControl = nil
            case UInt8(ascii: "c"):
                let c1 = point(), c2 = point(), end = point()
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                lastQuadControl = nil
                current = end
            case UInt8(ascii: "s"):
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = point(), end = point()
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                lastQuadControl = nil
                current = end
            case UInt8(ascii: "q"):
                let c = point(), end = point()
                path.addQuadCurve(to: end, control: c)
                lastQuadControl = c
                lastControl = nil
                current = end
            case UInt8(ascii: "t"):
                let c = lastQuadControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let end = point()
                path.addQuadCurve(to: end, control: c)
                lastQuadControl = c
                lastControl = nil
                current = end
            case UInt8(ascii: "a"):
                let rx = scanner.number(), ry = scanner.number(), rotation = scanner.number()
                let largeArc = scanner.flag(), sweep = scanner.flag()
                let end = point()
                addArc(path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, largeArc: largeArc, sweep: sweep)
                current = end
                lastControl = nil
                lastQuadControl = nil
            default:
                _ = scanner.number()
            }
        }
        return path
    }

    /// Endpoint-parameterized elliptical arc to cubic beziers (SVG spec
    /// F.6.5).
    private static func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat, rotation: CGFloat, largeArc: Bool, sweep: Bool) {
        if p0 == p1 { return }
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            rx *= sqrt(lambda)
            ry *= sqrt(lambda)
        }
        let sign: CGFloat = largeArc == sweep ? -1 : 1
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coef = sign * sqrt(max(0, numerator / denominator))
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var a = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        var t = theta1
        for _ in 0 ..< segments {
            let t2 = t + step
            let alpha = 4.0 / 3.0 * tan((t2 - t) / 4)
            func pointAt(_ a: CGFloat) -> (CGPoint, CGPoint) {
                let x = rx * cos(a), y = ry * sin(a)
                let dxT = -rx * sin(a), dyT = ry * cos(a)
                let p = CGPoint(x: cosPhi * x - sinPhi * y + cx, y: sinPhi * x + cosPhi * y + cy)
                let d = CGPoint(x: cosPhi * dxT - sinPhi * dyT, y: sinPhi * dxT + cosPhi * dyT)
                return (p, d)
            }
            let (pA, dA) = pointAt(t)
            let (pB, dB) = pointAt(t2)
            path.addCurve(
                to: pB,
                control1: CGPoint(x: pA.x + alpha * dA.x, y: pA.y + alpha * dA.y),
                control2: CGPoint(x: pB.x - alpha * dB.x, y: pB.y - alpha * dB.y)
            )
            t = t2
        }
    }
}

private struct NumberScanner {
    enum Token {
        case command(UInt8)
        case number
    }

    let bytes: [UInt8]
    var index = 0
    var lastTokenStart = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    private mutating func skipSeparators() {
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x2C || bytes[index] == 0x0A || bytes[index] == 0x09 || bytes[index] == 0x0D {
            index += 1
        }
    }

    mutating func nextCommandOrNumber() -> Token? {
        skipSeparators()
        guard index < bytes.count else { return nil }
        lastTokenStart = index
        let c = bytes[index]
        if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A), c != UInt8(ascii: "e"), c != UInt8(ascii: "E") {
            index += 1
            return .command(c)
        }
        return .number
    }

    mutating func pushBack() {
        index = lastTokenStart
    }

    mutating func flag() -> Bool {
        skipSeparators()
        guard index < bytes.count else { return false }
        let value = bytes[index] == UInt8(ascii: "1")
        index += 1
        return value
    }

    mutating func number() -> CGFloat {
        skipSeparators()
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
        var seenDot = false
        var seenExp = false
        while index < bytes.count {
            let c = bytes[index]
            if c >= 0x30, c <= 0x39 {
                index += 1
            } else if c == UInt8(ascii: "."), !seenDot, !seenExp {
                seenDot = true
                index += 1
            } else if c == UInt8(ascii: "e") || c == UInt8(ascii: "E"), !seenExp {
                seenExp = true
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
            } else {
                break
            }
        }
        guard index > start else {
            index += 1
            return 0
        }
        return CGFloat(Double(String(decoding: bytes[start ..< index], as: UTF8.self)) ?? 0)
    }
}
