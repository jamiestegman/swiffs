// Item editing in `CodeView` (`attachItemEditor` / `syncItemEditors`): each
// `edit: true` item gets one editor, recycled while virtualization unmounts
// the item and completed when edit mode ends or the item is removed.

import AppKit
import SwiffsCore
import SwiffsEditor

/// The finished edit of a CodeView item.
public enum CodeViewItemEditComplete<Metadata> {
    case file(FileEditCompleteEvent<Metadata>)
    case diff(FileDiffEditCompleteEvent<Metadata>)
}

/// The editor of one item.
@MainActor
final class CodeViewItemEditor {
    let editor: AnyObject
    let complete: () -> Void
    let discard: () -> Void
    let recycle: () -> Void
    let attach: (DiffsDocumentView) -> Void
    var attached = false

    init(editor: AnyObject, complete: @escaping () -> Void, discard: @escaping () -> Void, recycle: @escaping () -> Void, attach: @escaping (DiffsDocumentView) -> Void) {
        self.editor = editor
        self.complete = complete
        self.discard = discard
        self.recycle = recycle
        self.attach = attach
    }
}

extension CodeView {
    /// The live editor of an edit-mode item (`getEditor`), a
    /// `DiffsEditor<LineAnnotation<Metadata>>` or
    /// `DiffsEditor<DiffLineAnnotation<Metadata>>`.
    public func getEditor(_ itemID: String) -> AnyObject? {
        itemEditors[itemID]?.editor
    }

    private func editStateKey(_ item: Item) -> String {
        getEditStateKey?(item) ?? "codeview:\(editStateScope):\(item.id)"
    }

    func attachItemEditorIfNeeded(_ item: Item, view: DiffsDocumentView) {
        guard item.edit, !item.collapsed else { return }
        if let record = itemEditors[item.id] {
            if !record.attached {
                record.attach(view)
                record.attached = true
            }
            return
        }
        let id = item.id
        let key = editStateKey(item)
        let onChange: (DiffsEditorChangeEvent) -> Void = { [weak self] event in
            guard let self, let context = self.itemContext(id) else { return }
            self.onItemEditChange?(event, context)
        }
        let record: CodeViewItemEditor
        switch item.content {
        case .diff:
            let editor = DiffsEditor<DiffLineAnnotation<Metadata>>(options: editorOptions, editStateKey: key)
            editor.onChange = onChange
            record = CodeViewItemEditor(
                editor: editor,
                complete: { editor.complete() },
                discard: { editor.cleanUp(.discard) },
                recycle: { editor.cleanUp(.recycle) },
                attach: { [weak self] view in
                    guard let diffView = view as? FileDiffView<Metadata> else { return }
                    diffView.onEditComplete = { event in
                        guard let self, let context = self.itemContext(id) ?? self.removedContext(id, isDiff: true) else { return .reject }
                        return self.onItemEditComplete?(.diff(event), context) ?? .reject
                    }
                    _ = editor.edit(diffView)
                }
            )
        case .file:
            let editor = DiffsEditor<LineAnnotation<Metadata>>(options: editorOptions, editStateKey: key)
            editor.onChange = onChange
            record = CodeViewItemEditor(
                editor: editor,
                complete: { editor.complete() },
                discard: { editor.cleanUp(.discard) },
                recycle: { editor.cleanUp(.recycle) },
                attach: { [weak self] view in
                    guard let fileView = view as? FileView<Metadata> else { return }
                    fileView.onEditComplete = { event in
                        guard let self, let context = self.itemContext(id) ?? self.removedContext(id, isDiff: false) else { return .reject }
                        return self.onItemEditComplete?(.file(event), context) ?? .reject
                    }
                    _ = editor.edit(fileView)
                }
            )
        }
        itemEditors[id] = record
        record.attach(view)
        record.attached = true
    }

    private func removedContext(_ id: String, isDiff: Bool) -> CodeViewItemContext? {
        CodeViewItemContext(id: id, isDiff: isDiff)
    }

    func recycleItemEditor(_ id: String) {
        guard let record = itemEditors[id], record.attached else { return }
        record.recycle()
        record.attached = false
    }

    /// Completes sessions whose item left edit mode or was removed, and
    /// suspends collapsed items (`syncItemEditors`).
    /// Ends every edit session without installing results (`reset`).
    func discardItemEditors() {
        let records = itemEditors
        itemEditors.removeAll()
        for (id, record) in records {
            if !record.attached, let view = mountedView(id) {
                record.attach(view)
                record.attached = true
            }
            record.discard()
            record.attached = false
        }
    }

    func syncItemEditors(removed: [String: Item]) {
        guard !itemEditors.isEmpty else { return }
        var completions: [(String, CodeViewItemEditor)] = []
        for (id, record) in itemEditors {
            if removed[id] == nil, let item = currentItem(id) {
                if item.edit {
                    if item.collapsed, record.attached {
                        record.recycle()
                        record.attached = false
                    }
                    continue
                }
            }
            completions.append((id, record))
        }
        for (id, record) in completions {
            itemEditors.removeValue(forKey: id)
            if !record.attached, let view = mountedView(id) {
                // Re-attach to complete through the mounted view.
                record.attach(view)
                record.attached = true
            }
            if record.attached {
                record.complete()
                record.attached = false
            } else {
                // The item is unmounted: its retained state is dropped.
                record.recycle()
            }
        }
    }
}
