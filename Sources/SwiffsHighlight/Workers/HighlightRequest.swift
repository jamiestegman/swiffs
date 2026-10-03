import SwiffsCore

/// What a view asks the highlighter for, so every caller asks the same way:
/// the content, its render options, and whether it is too long to highlight.
public struct DiffHighlightRequest: Equatable, Sendable {
    public var diff: FileDiffMetadata
    public var options: RenderDiffOptions
    public var forcePlainText: Bool
    let lineCount: Int

    public init(diff: FileDiffMetadata, options: RenderDiffOptions, tokenizeMaxLength: Int) {
        self.diff = diff
        self.options = options
        lineCount = max(diff.additionLines.count, diff.deletionLines.count)
        forcePlainText = lineCount > tokenizeMaxLength
    }
}

/// A file's counterpart of `DiffHighlightRequest`.
public struct FileHighlightRequest: Equatable, Sendable {
    public var file: FileContents
    public var options: RenderFileOptions
    public var forcePlainText: Bool
    let lineCount: Int

    public init(file: FileContents, options: RenderFileOptions, lineCount: Int, tokenizeMaxLength: Int) {
        self.file = file
        self.options = options
        self.lineCount = lineCount
        forcePlainText = lineCount > tokenizeMaxLength
    }
}
