// Port of `trimPatchContext.ts`.

import Foundation

private struct TrimHunk {
    var additionStart: Int
    var deletionStart: Int
    var additionCount = 0
    var deletionCount = 0
    var hunkLines: [Substring] = []
    var contextLines: [Substring] = []
}

private enum ContextFlushMode {
    case beforeChange, leading, trailing
}

/// Trims excess context lines from a patch. Line numbers are preserved, hunk
/// headers are rewritten, and hunks are split where the context between
/// changes exceeds `contextSize * 2`.
public func trimPatchContext(_ patch: String, contextSize: Int = 10) -> String {
    var lines: [Substring] = []
    var currentHunk: TrimHunk?

    // `patch.split('\n')`: split on scalars so `\r\n` keeps its `\r`.
    let patchLines = patch.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { Substring($0) }
    for line in patchLines {
        if let header = parseHunkHeader(line) {
            if let hunk = currentHunk {
                if !hunk.hunkLines.isEmpty {
                    var hunk = hunk
                    flushContextLines(&hunk, contextSize, .trailing)
                    flushHunk(hunk, &lines)
                }
                currentHunk = nil
            }
            currentHunk = TrimHunk(additionStart: header.additionStart, deletionStart: header.deletionStart)
            continue
        }

        guard var hunk = currentHunk else {
            lines.append(line)
            continue
        }

        if line.hasPrefix(" ") {
            hunk.contextLines.append(line)
        } else if !line.isEmpty {
            if !hunk.hunkLines.isEmpty, hunk.contextLines.count > contextSize * 2 {
                let omittedContextLineCount = hunk.contextLines.count - contextSize * 2
                // `slice(-contextSize)`; `slice(-0)` keeps everything.
                let nextContextLines = contextSize == 0 ? hunk.contextLines : Array(hunk.contextLines.suffix(contextSize))
                flushContextLines(&hunk, contextSize, .trailing)
                flushHunk(hunk, &lines)
                hunk = TrimHunk(
                    additionStart: hunk.additionStart + hunk.additionCount + omittedContextLineCount,
                    deletionStart: hunk.deletionStart + hunk.deletionCount + omittedContextLineCount,
                    contextLines: nextContextLines
                )
            }
            flushContextLines(&hunk, contextSize, hunk.hunkLines.isEmpty ? .leading : .beforeChange)
            hunk.hunkLines.append(line)
            if line.hasPrefix("+") {
                hunk.additionCount += 1
            } else if line.hasPrefix("-") {
                hunk.deletionCount += 1
            }
        }
        currentHunk = hunk
    }

    if var hunk = currentHunk, !hunk.hunkLines.isEmpty {
        flushContextLines(&hunk, contextSize, .trailing)
        flushHunk(hunk, &lines)
    }

    let result = lines.joined(separator: "\n")
    // `patch.endsWith('\n')`, which `\r\n` also satisfies.
    return patch.unicodeScalars.last == "\n" ? result + "\n" : result
}

private func flushContextLines(_ hunk: inout TrimHunk, _ contextSize: Int, _ mode: ContextFlushMode) {
    if mode == .leading, hunk.contextLines.count > contextSize {
        let difference = hunk.contextLines.count - contextSize
        hunk.contextLines.removeFirst(difference)
        hunk.additionStart += difference
        hunk.deletionStart += difference
    }
    if mode == .trailing, hunk.contextLines.count > contextSize {
        hunk.contextLines.removeLast(hunk.contextLines.count - contextSize)
    }
    if !hunk.contextLines.isEmpty {
        hunk.hunkLines.append(contentsOf: hunk.contextLines)
        hunk.additionCount += hunk.contextLines.count
        hunk.deletionCount += hunk.contextLines.count
        hunk.contextLines.removeAll()
    }
}

private func flushHunk(_ hunk: TrimHunk, _ lines: inout [Substring]) {
    lines.append("@@ -\(formatHunkRange(hunk.deletionStart, hunk.deletionCount)) +\(formatHunkRange(hunk.additionStart, hunk.additionCount)) @@")
    lines.append(contentsOf: hunk.hunkLines)
}

private func formatHunkRange(_ start: Int, _ count: Int) -> String {
    count == 1 ? "\(start)" : "\(start),\(count)"
}
