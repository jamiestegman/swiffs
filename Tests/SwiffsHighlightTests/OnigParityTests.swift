import Foundation
import Testing
@testable import SwiffsHighlight

/// Replays scanner calls recorded from vscode-oniguruma (the engine Shiki
/// uses upstream) against `OnigScanner`.
struct OnigParityTests {
    struct Fixture: Decodable {
        var scanners: [[String]]
        var strings: [String]
        /// `[scanner, string, start, options, index, captures...]`.
        var calls: [[Int]]
    }

    static let fixture: Fixture = {
        let url = RenderParityTests.fixturesDirectory.appendingPathComponent("onig.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    /// The recorded form of a match: index, then each capture as start/end,
    /// or `-1, -1` when empty.
    static func encode(_ match: OnigMatch?) -> [Int] {
        guard let match else { return [-1] }
        var result = [match.index]
        for capture in match.captureIndices {
            if capture.end - capture.start == 0 {
                result += [-1, -1]
            } else {
                result += [capture.start, capture.end]
            }
        }
        return result
    }

    static func replay(order: [Int]) throws -> [String] {
        let fixture = Self.fixture
        var scanners: [Int: OnigScanner] = [:]
        var strings: [Int: OnigString] = [:]
        var mismatches: [String] = []
        for callIndex in order {
            let call = fixture.calls[callIndex]
            let scanner = try scanners[call[0]] ?? OnigScanner(patterns: fixture.scanners[call[0]])
            scanners[call[0]] = scanner
            let string = strings[call[1]] ?? OnigString(fixture.strings[call[1]])
            strings[call[1]] = string
            let actual = encode(scanner.findNextMatch(string, call[2], options: OnigFindOptions(rawValue: call[3])))
            let expected = Array(call[4...])
            if actual != expected {
                mismatches.append("call \(callIndex): scanner \(call[0]) at \(call[2]) in \(fixture.strings[call[1]].debugDescription): \(actual) != \(expected)")
            }
        }
        return mismatches
    }

    @Test func scannerCallsMatchVscodeOniguruma() throws {
        let mismatches = try Self.replay(order: Array(Self.fixture.calls.indices))
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches:\n\(mismatches.prefix(8).joined(separator: "\n"))")
    }

    /// Search results are cached per scanner and string; any call order must
    /// give the same answers.
    @Test func shuffledCallsMatchVscodeOniguruma() throws {
        var generator = SplitMix64(seed: 42)
        let order = Array(Self.fixture.calls.indices).shuffled(using: &generator)
        let mismatches = try Self.replay(order: order)
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches:\n\(mismatches.prefix(8).joined(separator: "\n"))")
    }
}

/// Deterministic generator for reproducible shuffles.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
