import Foundation
import Testing
@testable import SwiffsCore

struct ColorTests {
    /// Reference values from colorjs.io (`Color.mix(a, b, 1 - p, { space: "lab", premultiplied: true })`,
    /// clipped to sRGB).
    static let references: [(String, String, Double, [Int], Double)] = [
        ("#0a0a0a", "white", 92, [29, 29, 29], 1), ("#ffffff", "black", 98.5, [251, 251, 251], 1),
        ("#0a0a0a", "#ff6762", 80, [55, 31, 29], 1), ("#fff", "#0dbe4e", 88, [233, 248, 233], 1),
        ("#1e1e1e", "#69b1ff", 75, [51, 63, 79], 1), ("#fafafa", "#0a0a0a", 65, [157, 157, 157], 1),
        ("#24292e", "#e1e4e8", 65, [96, 100, 105], 1), ("#282a36", "#50fa7b", 80, [54, 79, 69], 1),
        ("#ffffff", "#ff2e3f", 12, [255, 84, 84], 1), ("#123456", "#abcdef", 50, [94, 124, 159], 1),
        ("#00000080", "#ffffff", 50, [162, 162, 162], 0.751), ("#f00", "#00f", 30, [156, 0, 183], 1),
    ]

    @Test func colorMixInLabMatchesReference() {
        for (a, b, p, rgb, alpha) in Self.references {
            let mixed = RGBAColor(css: a)!.mix(RGBAColor(css: b)!, p)
            let actual = [mixed.r, mixed.g, mixed.b].map { Int(($0 * 255).rounded()) }
            #expect(actual == rgb, "\(a) \(p)% \(b)")
            #expect(abs(mixed.a - alpha) < 0.002)
        }
    }

    @Test func parsesCSSColors() {
        #expect(RGBAColor(css: "#abc")?.hexString == "#aabbcc")
        #expect(RGBAColor(css: "#11223344")?.hexString == "#11223344")
        #expect(RGBAColor(css: "rgb(255, 0, 0)")?.hexString == "#ff0000")
        #expect(RGBAColor(css: "rgba(0 0 0 / 50%)")?.a == 0.5)
        #expect(RGBAColor(css: "transparent")?.a == 0)
        #expect(RGBAColor(css: "nonsense") == nil)
    }
}
