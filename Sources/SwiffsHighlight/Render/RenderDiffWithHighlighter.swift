// Port of `packages/diffs/src/utils/renderDiffWithHighlighter.ts`,
// `renderFileWithHighlighter.ts` and `parseDiffDecorations.ts`.

import Foundation
import SwiffsCore

public struct RenderDiffOptions: Hashable, Sendable {
    public var theme: ThemeSelection
    public var tokenizeMaxLineLength: Int
    public var lineDiffType: LineDiffType
    public var maxLineDiffLength: Int

    public init(
        theme: ThemeSelection = .pair(DiffsConstants.defaultThemes),
        tokenizeMaxLineLength: Int = 1000,
        lineDiffType: LineDiffType = .wordAlt,
        maxLineDiffLength: Int = 1000
    ) {
        self.theme = theme
        self.tokenizeMaxLineLength = tokenizeMaxLineLength
        self.lineDiffType = lineDiffType
        self.maxLineDiffLength = maxLineDiffLength
    }
}

public struct RenderFileOptions: Hashable, Sendable {
    public var theme: ThemeSelection
    public var tokenizeMaxLineLength: Int

    public init(theme: ThemeSelection = .pair(DiffsConstants.defaultThemes), tokenizeMaxLineLength: Int = 1000) {
        self.theme = theme
        self.tokenizeMaxLineLength = tokenizeMaxLineLength
    }
}

public struct ForceDiffPlainTextOptions: Sendable {
    public var forcePlainText: Bool
    public var startingLine: Int?
    public var totalLines: Int?
    public var expandedHunks: ExpandedHunks?
    public var collapsedContextThreshold: Int

    public init(
        forcePlainText: Bool = false,
        startingLine: Int? = nil,
        totalLines: Int? = nil,
        expandedHunks: ExpandedHunks? = nil,
        collapsedContextThreshold: Int = DiffsConstants.defaultCollapsedContextThreshold
    ) {
        self.forcePlainText = forcePlainText
        self.startingLine = startingLine
        self.totalLines = totalLines
        self.expandedHunks = expandedHunks
        self.collapsedContextThreshold = collapsedContextThreshold
    }
}

/// Languages needed to highlight a diff (renames can use two).
public func getDiffLanguages(_ diff: FileDiffMetadata) -> [SupportedLanguage] {
    if let lang = diff.lang { return [lang] }
    let deletionLang = getFiletypeFromFileName(diff.prevName ?? diff.name)
    let additionLang = getFiletypeFromFileName(diff.name)
    return deletionLang == additionLang ? [additionLang] : [deletionLang, additionLang]
}

private struct HighlightSegment {
    /// Where the highlighted region starts in the bucket.
    var originalOffset: Int
    /// Where to place the highlighted line in the result.
    var targetIndex: Int
    var count: Int
}

private final class RenderBucket {
    var deletionContent = ""
    var deletionCount = 0
    var additionContent = ""
    var additionCount = 0
    var deletionDecorations: [Int: [LineRange]] = [:]
    var additionDecorations: [Int: [LineRange]] = [:]
    var deletionSegments: [HighlightSegment] = []
    var additionSegments: [HighlightSegment] = []
}

extension DiffsHighlighter {
    /// Port of `renderDiffWithHighlighter`.
    public func renderDiff(
        _ diff: FileDiffMetadata,
        options: RenderDiffOptions,
        plainText: ForceDiffPlainTextOptions = ForceDiffPlainTextOptions()
    ) throws -> ThemedDiffResult {
        let forcePlainText = plainText.forcePlainText
        let startingLine = forcePlainText ? (plainText.startingLine ?? 0) : 0
        let totalLines = forcePlainText ? (plainText.totalLines ?? .max) : .max
        let isWindowedHighlight = startingLine > 0 || totalLines < .max
        let slots = ThemeSlots(options.theme)
        try attachThemes(slots.themeNames)
        let baseThemeType: ThemeKind? = {
            if case .single(let name) = slots { return try? getTheme(name).type }
            return nil
        }()

        // If we have a large file and we are rendering the WHOLE plain diff,
        // drop the line diff so things render quickly.
        let lineDiffType: LineDiffType =
            forcePlainText && !isWindowedHighlight && (diff.unifiedLineCount > 1000 || diff.splitLineCount > 1000)
                ? .none
                : options.lineDiffType

        var deletionResult = [HighlightedLine?](repeating: nil, count: diff.deletionLines.count)
        var additionResult = [HighlightedLine?](repeating: nil, count: diff.additionLines.count)

        let shouldGroupAll = !forcePlainText && !diff.isPartial
        let expandedHunksForIteration: ExpandedHunks? = forcePlainText ? plainText.expandedHunks : nil
        var buckets: [Int: RenderBucket] = [:]
        var bucketOrder: [Int] = []
        func bucket(for hunkIndex: Int) -> RenderBucket {
            let index = shouldGroupAll ? 0 : hunkIndex
            if let existing = buckets[index] { return existing }
            let created = RenderBucket()
            buckets[index] = created
            bucketOrder.append(index)
            return created
        }

        func appendContent(_ lineContent: String, _ lineIndex: Int, _ segments: inout [HighlightSegment], _ content: inout String, _ count: inout Int) {
            if isWindowedHighlight {
                if segments.isEmpty || segments[segments.count - 1].targetIndex + segments[segments.count - 1].count != lineIndex {
                    segments.append(HighlightSegment(originalOffset: count, targetIndex: lineIndex, count: 0))
                }
                segments[segments.count - 1].count += 1
            }
            content += lineContent
            count += 1
        }

        try iterateOverDiff(
            diff: diff,
            diffStyle: .both,
            startingLine: startingLine,
            totalLines: totalLines,
            expandedHunks: isWindowedHighlight ? expandedHunksForIteration : .all,
            collapsedContextThreshold: plainText.collapsedContextThreshold
        ) { props in
            let bucket = bucket(for: props.hunkIndex)
            if props.type == .change, let additionLine = props.additionLine, let deletionLine = props.deletionLine {
                computeLineDiffDecorations(
                    deletionLine: diff.deletionLines[deletionLine.lineIndex],
                    additionLine: diff.additionLines[additionLine.lineIndex],
                    deletionLineIndex: bucket.deletionCount,
                    additionLineIndex: bucket.additionCount,
                    deletionDecorations: &bucket.deletionDecorations,
                    additionDecorations: &bucket.additionDecorations,
                    lineDiffType: lineDiffType,
                    maxLineDiffLength: options.maxLineDiffLength
                )
            }
            if let deletionLine = props.deletionLine {
                appendContent(
                    diff.deletionLines[deletionLine.lineIndex], deletionLine.lineIndex,
                    &bucket.deletionSegments, &bucket.deletionContent, &bucket.deletionCount
                )
            }
            if let additionLine = props.additionLine {
                appendContent(
                    diff.additionLines[additionLine.lineIndex], additionLine.lineIndex,
                    &bucket.additionSegments, &bucket.additionContent, &bucket.additionCount
                )
            }
            return false
        }

        let languageOverride: String? = forcePlainText ? "text" : diff.lang
        let deletionLang = languageOverride ?? getFiletypeFromFileName(diff.prevName ?? diff.name)
        let additionLang = languageOverride ?? getFiletypeFromFileName(diff.name)
        if !forcePlainText {
            try prepare(langs: [deletionLang, additionLang], themes: [])
        }

        var deletionCursor = 0
        var additionCursor = 0
        for index in bucketOrder {
            let bucket = buckets[index]!
            if bucket.deletionCount == 0, bucket.additionCount == 0 { continue }
            let deletionLines = bucket.deletionContent.isEmpty ? [] : try renderLines(
                cleanLastNewline(bucket.deletionContent),
                lang: deletionLang,
                slots: slots,
                decorations: bucket.deletionDecorations,
                tokenizeMaxLineLength: options.tokenizeMaxLineLength
            )
            let additionLines = bucket.additionContent.isEmpty ? [] : try renderLines(
                cleanLastNewline(bucket.additionContent),
                lang: additionLang,
                slots: slots,
                decorations: bucket.additionDecorations,
                tokenizeMaxLineLength: options.tokenizeMaxLineLength
            )
            if shouldGroupAll {
                for (i, line) in deletionLines.enumerated() where i < deletionResult.count { deletionResult[i] = line }
                for (i, line) in additionLines.enumerated() where i < additionResult.count { additionResult[i] = line }
                continue
            }
            if !bucket.deletionSegments.isEmpty {
                for segment in bucket.deletionSegments {
                    for i in 0 ..< segment.count where segment.originalOffset + i < deletionLines.count {
                        let target = segment.targetIndex + i
                        if target < deletionResult.count { deletionResult[target] = deletionLines[segment.originalOffset + i] }
                    }
                }
            } else {
                for line in deletionLines {
                    if deletionCursor < deletionResult.count { deletionResult[deletionCursor] = line }
                    deletionCursor += 1
                }
            }
            if !bucket.additionSegments.isEmpty {
                for segment in bucket.additionSegments {
                    for i in 0 ..< segment.count where segment.originalOffset + i < additionLines.count {
                        let target = segment.targetIndex + i
                        if target < additionResult.count { additionResult[target] = additionLines[segment.originalOffset + i] }
                    }
                }
            } else {
                for line in additionLines {
                    if additionCursor < additionResult.count { additionResult[additionCursor] = line }
                    additionCursor += 1
                }
            }
        }
        return ThemedDiffResult(
            deletionLines: deletionResult,
            additionLines: additionResult,
            themes: slots,
            baseThemeType: baseThemeType
        )
    }

    /// Port of `renderFileWithHighlighter`.
    public func renderFile(
        _ file: FileContents,
        options: RenderFileOptions,
        forcePlainText: Bool = false,
        startingLine requestedStartingLine: Int? = nil,
        totalLines requestedTotalLines: Int? = nil,
        lines precomputedLines: [String]? = nil
    ) throws -> ThemedFileResult {
        let startingLine = forcePlainText ? (requestedStartingLine ?? 0) : 0
        let totalLines = forcePlainText ? (requestedTotalLines ?? .max) : .max
        let isWindowedHighlight = startingLine > 0 || totalLines < .max
        let slots = ThemeSlots(options.theme)
        try attachThemes(slots.themeNames)
        let lang = forcePlainText ? "text" : (file.lang ?? getFiletypeFromFileName(file.name))
        if !forcePlainText {
            try prepare(langs: [lang], themes: [])
        }
        let baseThemeType: ThemeKind? = {
            if case .single(let name) = slots { return try? getTheme(name).type }
            return nil
        }()
        var source: String
        if isWindowedHighlight {
            let lines = precomputedLines ?? linesFromFileContents(file.contents)
            if lines.isEmpty {
                source = ""
            } else {
                let end = min(startingLine &+ totalLines, lines.count)
                source = startingLine < end ? lines[startingLine ..< end].joined() : ""
            }
        } else {
            source = file.contents
        }
        source = normalizeHighlightLineEndings(source)
        let highlighted = try renderLines(source, lang: lang, slots: slots, decorations: [:], tokenizeMaxLineLength: options.tokenizeMaxLineLength)
        var result: [HighlightedLine?]
        if isWindowedHighlight {
            result = [HighlightedLine?](repeating: nil, count: startingLine)
            result.append(contentsOf: highlighted.map { Optional($0) })
        } else {
            result = highlighted.map { Optional($0) }
        }
        return ThemedFileResult(lines: result, themes: slots, baseThemeType: baseThemeType)
    }

    /// Tokenizes `code` and builds highlighted lines with decorations.
    func renderLines(
        _ code: String,
        lang: String,
        slots: ThemeSlots,
        decorations: [Int: [LineRange]],
        tokenizeMaxLineLength: Int
    ) throws -> [HighlightedLine] {
        let tokenLines = try tokenize(code, lang: lang, themes: slots, tokenizeMaxLineLength: tokenizeMaxLineLength)
        var result: [HighlightedLine] = []
        result.reserveCapacity(tokenLines.count)
        for (lineIndex, tokens) in tokenLines.enumerated() {
            var text = ""
            var highlighted: [HighlightedToken] = []
            highlighted.reserveCapacity(tokens.count)
            var offset = 0
            for token in tokens {
                let length = token.content.utf16.count
                if length == 0 { continue }
                text += token.content
                highlighted.append(HighlightedToken(start: offset, end: offset + length, styles: token.styles))
                offset += length
            }
            result.append(HighlightedLine(text: text, tokens: highlighted, diffSpans: decorations[lineIndex] ?? []))
        }
        return result
    }
}

// Shiki does not treat a lone carriage return as a line break. Normalize only
// the text sent to the highlighter.
private func normalizeHighlightLineEndings(_ contents: String) -> String {
    guard contents.utf8.contains(UInt8(ascii: "\r")) else { return contents }
    var units: [UInt16] = []
    let source = Array(contents.utf16)
    units.reserveCapacity(source.count)
    for (i, unit) in source.enumerated() {
        if unit == 0x0D, i + 1 >= source.count || source[i + 1] != 0x0A {
            units.append(0x0A)
        } else {
            units.append(unit)
        }
    }
    return String(decoding: units, as: UTF16.self)
}

// MARK: - Line diff decorations

private func computeLineDiffDecorations(
    deletionLine: String,
    additionLine: String,
    deletionLineIndex: Int,
    additionLineIndex: Int,
    deletionDecorations: inout [Int: [LineRange]],
    additionDecorations: inout [Int: [LineRange]],
    lineDiffType: LineDiffType,
    maxLineDiffLength: Int
) {
    if lineDiffType == .none { return }
    let deletion = cleanLastNewline(deletionLine)
    let addition = cleanLastNewline(additionLine)
    // If we have really long lines, we probably shouldn't compute diffs.
    if deletion.utf16.count > maxLineDiffLength || addition.utf16.count > maxLineDiffLength {
        return
    }
    let lineDiff = lineDiffType == .char ? diffChars(deletion, addition) : diffWordsWithSpace(deletion, addition)
    var deletionSpans: [(Bool, Int)] = []
    var additionSpans: [(Bool, Int)] = []
    let enableJoin = lineDiffType == .wordAlt
    for (index, item) in lineDiff.enumerated() {
        let isLastItem = index == lineDiff.count - 1
        if !item.added, !item.removed {
            pushOrJoinSpan(item, &deletionSpans, enableJoin: enableJoin, isNeutral: true, isLastItem: isLastItem)
            pushOrJoinSpan(item, &additionSpans, enableJoin: enableJoin, isNeutral: true, isLastItem: isLastItem)
        } else if item.removed {
            pushOrJoinSpan(item, &deletionSpans, enableJoin: enableJoin, isLastItem: isLastItem)
        } else {
            pushOrJoinSpan(item, &additionSpans, enableJoin: enableJoin, isLastItem: isLastItem)
        }
    }
    var spanIndex = 0
    for (highlighted, length) in deletionSpans {
        if highlighted {
            deletionDecorations[deletionLineIndex, default: []].append(LineRange(start: spanIndex, end: spanIndex + length))
        }
        spanIndex += length
    }
    spanIndex = 0
    for (highlighted, length) in additionSpans {
        if highlighted {
            additionDecorations[additionLineIndex, default: []].append(LineRange(start: spanIndex, end: spanIndex + length))
        }
        spanIndex += length
    }
}

/// Port of `pushOrJoinSpan`: spans are (highlighted, UTF-16 length). A single
/// character neutral gap after a highlighted span is joined into it.
private func pushOrJoinSpan(_ item: ChangeObject, _ arr: inout [(Bool, Int)], enableJoin: Bool, isNeutral: Bool = false, isLastItem: Bool = false) {
    let length = item.value.utf16.count
    guard let last = arr.last, !isLastItem, enableJoin else {
        arr.append((!isNeutral, length))
        return
    }
    let isLastItemNeutral = !last.0
    if isNeutral == isLastItemNeutral || (isNeutral && length == 1 && !isLastItemNeutral) {
        arr[arr.count - 1].1 += length
        return
    }
    arr.append((!isNeutral, length))
}
