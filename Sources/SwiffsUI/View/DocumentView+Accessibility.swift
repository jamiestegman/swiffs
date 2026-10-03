import AppKit
import SwiffsCore

/// The document reads as a list in document order: each item's header,
/// carrying the item's expand and conflict actions, then its visible lines
/// and annotation views. Actions are custom actions, so no element needs to
/// be subclassed.
extension DocumentView {
    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .list }

    override func accessibilityChildren() -> [Any]? {
        let visible = visibleRect
        var children: [Any] = []
        let hosted = subviews.filter { !$0.isHidden }
        for item in layout.items(in: visible.minY, visible.maxY) {
            children.append(headerElement(for: item))
            let headerBottom = item.bodyTop(showsHeaders: layout.configuration.showsHeaders)
            children.append(contentsOf: hosted.filter { $0.frame.minY >= item.top && $0.frame.minY < headerBottom })
            guard let body = item.body, let geometry = item.geometry else { continue }
            let bodyTop = item.bodyTop(showsHeaders: layout.configuration.showsHeaders)
            var row = item.firstRowIndex(atOrBelow: visible.minY, showsHeaders: layout.configuration.showsHeaders)
            while row < body.rows.count, bodyTop + body.rowTops[row] < visible.maxY {
                let rowRect = CGRect(x: 0, y: bodyTop + body.rowTops[row], width: bounds.width, height: body.rowHeights[row])
                for (index, column) in geometry.columns.enumerated() {
                    if let line = textLine(row: row, column: index, in: item) {
                        let frame = CGRect(x: column.minX, y: rowRect.minY, width: column.width, height: rowRect.height)
                        children.append(lineElement(line, in: item, frame: frame))
                    }
                }
                children.append(contentsOf: hosted.filter { $0.frame.minY >= rowRect.minY && $0.frame.minY < rowRect.maxY })
                row += 1
            }
        }
        return children
    }

    private func headerElement(for item: ItemModel) -> NSAccessibilityElement {
        let content = HeaderContent(item)
        var label = content.previousName.map { "\($0) renamed to \(content.name)" } ?? content.name
        if let deletions = content.deletions, let additions = content.additions {
            label += ", \(deletions) removed, \(additions) added"
        }
        if item.isCollapsed { label += ", collapsed" }
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(.staticText)
        element.setAccessibilityParent(self)
        element.setAccessibilityLabel(label)
        element.setAccessibilityFrameInParentSpace(CGRect(x: 0, y: item.top, width: bounds.width, height: layout.configuration.showsHeaders ? Metrics.headerHeight : 0))
        element.setAccessibilityCustomActions(actions(for: item))
        return element
    }

    private func lineElement(_ line: RenderedLine, in item: ItemModel, frame: CGRect) -> NSAccessibilityElement {
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(.staticText)
        element.setAccessibilityParent(self)
        element.setAccessibilityFrameInParentSpace(frame)
        var label = "Line \(line.lineNumber)"
        if item.shape.kind == .diff {
            switch line.lineType {
            case .changeAddition: label += ", added"
            case .changeDeletion: label += ", removed"
            case .context, .contextExpanded: if item.shape.isSplit { label += line.side == .deletions ? ", old" : ", new" }
            }
        }
        element.setAccessibilityLabel(label)
        element.setAccessibilityValue(item.text(side: line.side, lineIndex: line.lineIndex))
        if layout.configuration.showsGutterAction {
            let point = selectionPoint(for: line, in: item)
            let itemID = item.id
            element.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: layout.configuration.gutterActionLabel) { [weak self] in
                guard let self else { return false }
                self.delegate?.documentView(self, didRequestGutterAction: DiffLineSelection(itemID: itemID, range: Self.range(from: point, to: point)))
                return true
            }])
        }
        return element
    }

    /// The item's separator and conflict controls, as named actions.
    private func actions(for item: ItemModel) -> [NSAccessibilityCustomAction] {
        guard let body = item.body else { return [] }
        var actions: [NSAccessibilityCustomAction] = []
        var seenHunks: Set<Int> = []
        for row in body.rows {
            for cell in row.cells {
                switch cell {
                case .separator(let separator)? where separator.expandable != nil && seenHunks.insert(separator.hunkIndex).inserted:
                    for direction in separator.expandButtons {
                        let name: String = switch direction {
                        case .up: "Expand \(separator.label) up"
                        case .down: "Expand \(separator.label) down"
                        case .both: "Expand \(separator.label)"
                        }
                        actions.append(NSAccessibilityCustomAction(name: name) { [weak self, weak item] in
                            guard let self, let item else { return false }
                            self.delegate?.documentView(self, expand: item, hunk: separator.hunkIndex, direction: direction, all: false)
                            return true
                        })
                    }
                case .injected(let injected)?:
                    guard case .mergeConflictActions(let conflict) = injected.kind else { continue }
                    let resolutions: [(MergeConflictResolution, String)] = [(.current, "Accept current change"), (.incoming, "Accept incoming change"), (.both, "Accept both changes")]
                    for (resolution, name) in resolutions {
                        actions.append(NSAccessibilityCustomAction(name: "\(name), conflict \(conflict + 1)") { [weak self, weak item] in
                            guard let self, let item else { return false }
                            self.delegate?.documentView(self, resolve: item, conflict: conflict, resolution: resolution)
                            return true
                        })
                    }
                default:
                    continue
                }
            }
        }
        return actions
    }
}
