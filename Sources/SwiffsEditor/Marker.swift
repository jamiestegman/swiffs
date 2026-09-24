// Diagnostics markers (the model part of `editor/marker.ts`).

import Foundation

public enum MarkerSeverity: String, Hashable, Sendable, Codable {
    case error, warning, info, hint
}

/// A diagnostic over a document range (`Marker`).
public struct Marker: Hashable, Sendable {
    public var start: Position
    public var end: Position
    public var severity: MarkerSeverity
    public var message: String
    public var source: String?

    public init(start: Position, end: Position, severity: MarkerSeverity, message: String, source: String? = nil) {
        self.start = start
        self.end = end
        self.severity = severity
        self.message = message
        self.source = source
    }

    public var range: DocumentRange { DocumentRange(start: start, end: end) }
}
