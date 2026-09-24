import Foundation
@testable import SwiffsCore

enum Fixtures {
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Describes the first difference between two values' JSON encodings, for
/// readable failure messages.
func firstDifference<T: Encodable>(_ lhs: T, _ rhs: T) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let a = try? JSONSerialization.jsonObject(with: encoder.encode(lhs), options: [.fragmentsAllowed]),
          let b = try? JSONSerialization.jsonObject(with: encoder.encode(rhs), options: [.fragmentsAllowed])
    else { return "encoding failed" }
    return diffJSON(a, b, path: "$")
}

private func diffJSON(_ a: Any, _ b: Any, path: String) -> String? {
    switch (a, b) {
    case let (a as [String: Any], b as [String: Any]):
        for key in Set(a.keys).union(b.keys).sorted() {
            guard let av = a[key] else { return "\(path).\(key): missing on actual, expected \(b[key]!)" }
            guard let bv = b[key] else { return "\(path).\(key): unexpected \(av)" }
            if let d = diffJSON(av, bv, path: "\(path).\(key)") { return d }
        }
        return nil
    case let (a as [Any], b as [Any]):
        for i in 0 ..< min(a.count, b.count) {
            if let d = diffJSON(a[i], b[i], path: "\(path)[\(i)]") { return d }
        }
        return a.count == b.count ? nil : "\(path): count \(a.count) != \(b.count)"
    case let (a as NSNumber, b as NSNumber):
        return a == b ? nil : "\(path): \(a) != \(b)"
    case let (a as String, b as String):
        return a == b ? nil : "\(path): \(a.debugDescription) != \(b.debugDescription)"
    default:
        return String(describing: a) == String(describing: b) ? nil : "\(path): \(a) != \(b)"
    }
}
