// Ports of `utils/parseLineType.ts`, `utils/getLineAnnotationName.ts` and
// `utils/setLanguageOverride.ts`.

import Foundation

/// A patch line split into its content and type (`ParsedLine`).
public struct ParsedLine: Hashable, Sendable {
    public var line: String
    /// Never `.expanded`.
    public var type: HunkLineType

    public init(line: String, type: HunkLineType) {
        self.line = line
        self.type = type
    }
}

/// Classifies a patch line by its first character (`parseLineType`); nil for
/// lines that do not start with `+`, `-`, space or `\`.
public func parseLineType(_ line: String) -> ParsedLine? {
    guard let first = line.utf16.first else { return nil }
    let type: HunkLineType
    switch first {
    case 0x20: type = .context
    case 0x5C: type = .metadata
    case 0x2B: type = .addition
    case 0x2D: type = .deletion
    default: return nil
    }
    let processed = String(decoding: line.utf16.dropFirst(), as: UTF16.self)
    // An empty line becomes a newline so the row is still highlighted.
    return ParsedLine(line: processed.isEmpty ? "\n" : processed, type: type)
}

/// The slot name for an annotation (`getLineAnnotationName`).
public func getLineAnnotationName<Metadata>(_ annotation: LineAnnotation<Metadata>) -> String {
    "annotation-\(annotation.lineNumber)"
}

public func getLineAnnotationName<Metadata>(_ annotation: DiffLineAnnotation<Metadata>) -> String {
    "annotation-\(annotation.side.rawValue)-\(annotation.lineNumber)"
}

/// Returns a copy with the language overridden (`setLanguageOverride`).
public func setLanguageOverride(_ file: FileContents, _ lang: SupportedLanguage) -> FileContents {
    var copy = file
    copy.lang = lang
    return copy
}

public func setLanguageOverride(_ diff: FileDiffMetadata, _ lang: SupportedLanguage) -> FileDiffMetadata {
    var copy = diff
    copy.lang = lang
    return copy
}
