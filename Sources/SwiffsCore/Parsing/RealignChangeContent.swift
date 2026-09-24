// Port of `packages/diffs/src/utils/realignChangeContent.ts`.
//
// The diff library emits one change block per replaced run, ordering every
// deleted line before every added line. Renderers pair a block's lines
// positionally (deletion[i] across from addition[i] in split view), so a block
// like { deletions: 1, additions: 2 } pairs the deleted line with whichever
// addition happens to come first — even when a later addition is the edited
// version of it. These helpers re-split such blocks so the most similar lines
// pair up and the surplus renders as pure insert/delete rows at the block's
// edges.

import Foundation

// Skip realignment when a block would need more than this many line
// comparisons; pathological blocks keep the library's positional pairing.
private let maxAlignmentComparisons = 4096

// A shifted pairing must beat the positional one by this much per paired line
// before the block is re-split.
private let minImprovementPerPair = 0.5

/// Re-split count-mismatched change blocks in every hunk so paired lines are
/// chosen by content similarity instead of position. Rendered row counts are
/// unchanged.
public func realignChangeContentBySimilarity(_ diff: inout FileDiffMetadata) {
    for hunkIndex in diff.hunks.indices {
        var index = 0
        while index < diff.hunks[hunkIndex].hunkContent.count {
            defer { index += 1 }
            guard case .change(let content) = diff.hunks[hunkIndex].hunkContent[index] else { continue }
            if let replacement = realignChangeBlock(
                additionLines: diff.additionLines,
                deletionLines: diff.deletionLines,
                content
            ) {
                diff.hunks[hunkIndex].hunkContent.replaceSubrange(index ... index, with: replacement.map { .change($0) })
                index += replacement.count - 1
            }
        }
    }
}

/// During editing, slide pure insert/delete blocks made entirely of blank
/// lines to the top of the blank run they sit in.
///
/// `resolveSlide` receives each block that qualifies along with the full
/// distance to the run's top and returns how far to actually move it; 0 keeps
/// the parsed position. Without it, every qualifying block slides to the top.
public func slideBlankBoundaryBlocksUp(
    _ hunk: inout Hunk,
    additionLines: [String],
    deletionLines: [String],
    resolveSlide: ((ChangeContent, Int) -> Int)? = nil
) {
    var index = 1
    while index < hunk.hunkContent.count {
        defer { index += 1 }
        guard case .change(var block) = hunk.hunkContent[index],
              !(block.additions > 0 && block.deletions > 0),
              case .context(var previous) = hunk.hunkContent[index - 1]
        else { continue }
        let isInsert = block.additions > 0
        let lines = isInsert ? additionLines : deletionLines
        let blockStart = isInsert ? block.additionLineIndex : block.deletionLineIndex
        let blockLength = isInsert ? block.additions : block.deletions

        // Sliding through identical lines is only well-defined when the block
        // is a uniform run; require every block line to equal the first one,
        // and that line to be blank.
        let unit = blockStart >= 0 && blockStart < lines.count ? lines[blockStart] : ""
        if !JSString.trim(unit).isEmpty { continue }
        var uniform = true
        for offset in stride(from: 1, to: blockLength, by: 1) {
            let i = blockStart + offset
            if i >= lines.count || !lines[i].utf8.elementsEqual(unit.utf8) {
                uniform = false
                break
            }
        }
        if !uniform { continue }

        // Slide distance: how many trailing context lines match the block's
        // line exactly.
        var slide = 0
        while slide < previous.lines {
            let i = previous.additionLineIndex + previous.lines - 1 - slide
            guard i >= 0, i < additionLines.count, additionLines[i].utf8.elementsEqual(unit.utf8) else { break }
            slide += 1
        }
        if slide == 0 { continue }
        // Stopped by the hunk's leading edge rather than by content.
        if index == 1, slide == previous.lines { continue }
        if let resolveSlide {
            slide = resolveSlide(block, slide)
            if slide == 0 { continue }
        }

        block.additionLineIndex -= slide
        block.deletionLineIndex -= slide
        hunk.hunkContent[index] = .change(block)
        let blockAdditionEnd = block.additionLineIndex + block.additions
        let blockDeletionEnd = block.deletionLineIndex + block.deletions
        if index + 1 < hunk.hunkContent.count, case .context(var next) = hunk.hunkContent[index + 1] {
            next.lines += slide
            next.additionLineIndex = blockAdditionEnd
            next.deletionLineIndex = blockDeletionEnd
            hunk.hunkContent[index + 1] = .context(next)
        } else {
            hunk.hunkContent.insert(
                .context(ContextContent(lines: slide, additionLineIndex: blockAdditionEnd, deletionLineIndex: blockDeletionEnd)),
                at: index + 1
            )
        }
        previous.lines -= slide
        if previous.lines == 0 {
            hunk.hunkContent.remove(at: index - 1)
            index -= 1
        } else {
            hunk.hunkContent[index - 1] = .context(previous)
        }
    }
}

// Returns the split blocks for one change block, or nil when the block is
// balanced, too large to scan, or already best paired positionally.
private func realignChangeBlock(
    additionLines: [String],
    deletionLines: [String],
    _ content: ChangeContent
) -> [ChangeContent]? {
    let deletions = content.deletions
    let additions = content.additions
    let deletionLineIndex = content.deletionLineIndex
    let additionLineIndex = content.additionLineIndex
    let pairCount = min(deletions, additions)
    let surplus = abs(additions - deletions)
    if pairCount == 0 || surplus == 0 || pairCount * (surplus + 1) > maxAlignmentComparisons {
        return nil
    }

    // Whitespace is noise for deciding which lines pair. Strip it once per
    // line here rather than per comparison.
    func line(_ lines: [String], _ index: Int) -> String {
        index >= 0 && index < lines.count ? lines[index] : ""
    }
    let strippedDeletions = (0 ..< deletions).map { stripWhitespace(line(deletionLines, deletionLineIndex + $0)) }
    let strippedAdditions = (0 ..< additions).map { stripWhitespace(line(additionLines, additionLineIndex + $0)) }

    // Score every offset of the shorter side along the longer side and keep
    // the best one only when it decisively beats the positional pairing.
    let additionsAreLonger = additions > deletions
    var bestOffset = 0
    var bestScore = -1.0
    for offset in 0 ... surplus {
        var score = 0.0
        for pair in 0 ..< pairCount {
            score += lineSimilarity(
                strippedDeletions[pair + (additionsAreLonger ? 0 : offset)],
                strippedAdditions[pair + (additionsAreLonger ? offset : 0)]
            )
        }
        if offset == 0 {
            bestScore = score + Double(pairCount) * minImprovementPerPair
        } else if score > bestScore {
            bestScore = score
            bestOffset = offset
        }
    }
    if bestOffset == 0 {
        return nil
    }

    var blocks: [ChangeContent] = []
    func pushBlock(_ blockDeletions: Int, _ blockAdditions: Int, _ blockDeletionIndex: Int, _ blockAdditionIndex: Int) {
        if blockDeletions > 0 || blockAdditions > 0 {
            blocks.append(ChangeContent(
                deletions: blockDeletions,
                deletionLineIndex: blockDeletionIndex,
                additions: blockAdditions,
                additionLineIndex: blockAdditionIndex
            ))
        }
    }
    if additionsAreLonger {
        pushBlock(0, bestOffset, deletionLineIndex, additionLineIndex)
        pushBlock(pairCount, pairCount, deletionLineIndex, additionLineIndex + bestOffset)
        pushBlock(0, additions - pairCount - bestOffset, deletionLineIndex + pairCount, additionLineIndex + bestOffset + pairCount)
    } else {
        pushBlock(bestOffset, 0, deletionLineIndex, additionLineIndex)
        pushBlock(pairCount, pairCount, deletionLineIndex + bestOffset, additionLineIndex)
        pushBlock(deletions - pairCount - bestOffset, 0, deletionLineIndex + bestOffset + pairCount, additionLineIndex + pairCount)
    }
    return blocks
}

/// Strips all JavaScript `\s` whitespace, returning UTF-16 code units (the
/// similarity metric compares code units like the upstream implementation).
private func stripWhitespace(_ line: String) -> [UInt16] {
    var result: [UInt16] = []
    result.reserveCapacity(line.utf16.count)
    for scalar in line.unicodeScalars where !JSString.isWhitespace(scalar) {
        result.append(contentsOf: String(scalar).utf16)
    }
    return result
}

// Cheap 0..1 similarity over whitespace-stripped lines: shared prefix plus
// shared suffix over the longer length.
private func lineSimilarity(_ a: [UInt16], _ b: [UInt16]) -> Double {
    if a == b { return 1 }
    let maxLength = max(a.count, b.count)
    let minLength = min(a.count, b.count)
    if minLength == 0 { return 0 }
    var prefix = 0
    while prefix < minLength, a[prefix] == b[prefix] {
        prefix += 1
    }
    var suffix = 0
    while suffix < minLength - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
        suffix += 1
    }
    return Double(prefix + suffix) / Double(maxLength)
}
