// Accessibility for the code grid. Upstream's editable content element is a
// labeled `role="textbox"` with `aria-multiline`; read-only content is plain
// DOM text. The grid reports itself as a text area either way: editable (with
// the document's value, selection and line mapping) while an editor is
// attached, read-only otherwise.

import AppKit
import SwiffsCore
import SwiffsEditor

extension CodeGridView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    override func accessibilityValue() -> Any? { accessibilityText }

    override func isAccessibilityEnabled() -> Bool { true }

    override func accessibilityNumberOfCharacters() -> Int {
        accessibilityText.utf16.count
    }

    override func accessibilitySelectedText() -> String? {
        let range = accessibilitySelectedTextRange()
        return accessibilityString(for: range)
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        guard let client = editing.client, let selection = client.editorSelections.last else { return NSRange(location: 0, length: 0) }
        let start = client.editorOffset(of: selection.range.start)
        let end = client.editorOffset(of: selection.range.end)
        return NSRange(location: start, length: end - start)
    }

    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        editing.client?.editorSelectOffsets(range.location, range.location + range.length)
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        guard let client = editing.client, let selection = client.editorSelections.last else { return 0 }
        return selection.focus.line
    }

    override func accessibilityLine(for index: Int) -> Int {
        guard let client = editing.client else { return lineStarts.lastIndex { $0 <= index } ?? 0 }
        return client.editorPosition(ofOffset: index).line
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        let text = accessibilityText as NSString
        if let client = editing.client {
            let start = client.editorOffset(of: Position(line: line, character: 0))
            let next = client.editorOffset(of: Position(line: line + 1, character: 0))
            let end = next > start ? next : text.length
            return NSRange(location: start, length: max(0, end - start))
        }
        let starts = lineStarts
        guard line >= 0, line < starts.count else { return NSRange(location: NSNotFound, length: 0) }
        let end = line + 1 < starts.count ? starts[line + 1] : text.length
        return NSRange(location: starts[line], length: end - starts[line])
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let text = accessibilityText as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return nil }
        return text.substring(with: range)
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let client = editing.client, let window else { return .zero }
        let start = client.editorPosition(ofOffset: range.location)
        let end = client.editorPosition(ofOffset: NSMaxRange(range))
        guard let first = editorCaretRect(start), let last = editorCaretRect(end) else { return .zero }
        let rect = first.union(last)
        return window.convertToScreen(convert(rect, to: nil))
    }

    /// Hunk separator expand controls (`role="button"` upstream).
    override func accessibilityChildren() -> [Any]? {
        guard let first = columns.first else { return [] }
        var children: [Any] = []
        for (rowIndex, row) in model.rows.enumerated() {
            for cell in row.cells {
                guard case .separator(let separator)? = cell, separator.expandable != nil else { continue }
                for (direction, rect) in separatorFrames(separator, row: rowIndex, column: first).buttons {
                    let label: String
                    switch direction {
                    case .up: label = "Expand up"
                    case .down: label = "Expand down"
                    case .both: label = "Expand all"
                    }
                    let hunkIndex = separator.hunkIndex
                    let element = GridAccessibilityButton(label: label, parent: self, frame: rect) { [weak self] in
                        guard let self else { return }
                        self.delegate?.grid(self, expandHunk: hunkIndex, direction: direction, all: direction == .both)
                    }
                    children.append(element)
                }
                break
            }
        }
        return children
    }

    /// Posts an accessibility notification while an editor is attached.
    func postEditorAccessibilityNotification(_ notification: NSAccessibility.Notification) {
        guard isEditing else { return }
        NSAccessibility.post(element: self, notification: notification)
    }

    /// The document text while editing; otherwise the text of the first
    /// column's lines.
    private var accessibilityText: String {
        if let client = editing.client { return client.editorText }
        return readOnlyLines.joined(separator: "\n")
    }

    private var readOnlyLines: [String] {
        guard !columns.isEmpty else { return [] }
        return model.rows.indices.compactMap { row in textLine(row: row, column: 0).map { lineProvider?.line(side: $0.side, lineIndex: $0.lineIndex).text ?? "" } }
    }

    private var lineStarts: [Int] {
        var starts: [Int] = []
        var offset = 0
        for line in readOnlyLines {
            starts.append(offset)
            offset += line.utf16.count + 1
        }
        return starts
    }
}

/// An accessible control drawn by the grid.
/// Only used on the main thread by AppKit accessibility.
final class GridAccessibilityButton: NSAccessibilityElement, @unchecked Sendable {
    private let press: @MainActor () -> Void
    private let frameInGrid: CGRect
    private weak var grid: NSView?

    init(label: String, parent: NSView, frame: CGRect, press: @escaping @MainActor () -> Void) {
        self.press = press
        frameInGrid = frame
        grid = parent
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityParent(parent)
    }

    override func accessibilityFrame() -> NSRect {
        MainActor.assumeIsolated {
            guard let grid, let window = grid.window else { return .zero }
            return window.convertToScreen(grid.convert(frameInGrid, to: nil))
        }
    }

    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated { press() }
        return true
    }
}
