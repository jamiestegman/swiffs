// Port of `editor/searchPanel.ts`: the find/replace panel shown over an
// editor (Cmd+F, Cmd+Alt+F).

import AppKit
import SwiffsCore
import SwiffsEditor

/// Callbacks the editor provides to the panel (`SearchPanelOptions`).
@MainActor
struct EditorSearchHooks {
    var search: (SearchParams) -> [(start: Int, end: Int)]
    var scrollToMatch: ((start: Int, end: Int), Bool) -> Void
    var applyReplace: ([ResolvedTextEdit]) -> Void
    var replacementText: (SearchParams, Int, Int) -> String
    /// Reports matches; returns the current match (`onUpdate`).
    var onUpdate: ([(start: Int, end: Int)], Bool) -> (start: Int, end: Int)?
    var onClose: () -> Void
}

final class EditorSearchPanel: NSView, NSTextFieldDelegate {
    enum Mode { case find, replace }

    private let hooks: EditorSearchHooks
    private var params: SearchParams
    private var matches: [(start: Int, end: Int)] = []
    private var current: (start: Int, end: Int)?
    private(set) var mode: Mode

    private let background = NSVisualEffectView()
    private let searchField = NSTextField()
    private let replaceField = NSTextField()
    private let resultLabel = NSTextField(labelWithString: "No results")
    private let caseToggle = NSButton()
    private let wordToggle = NSButton()
    private let regexToggle = NSButton()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()
    private let expandButton = NSButton()
    private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "All", target: nil, action: nil)

    init(defaultQuery: String, mode: Mode, hooks: EditorSearchHooks) {
        self.hooks = hooks
        self.mode = mode
        params = SearchParams(text: defaultQuery)
        super.init(frame: .zero)
        setUp()
        searchField.stringValue = defaultQuery
        applyMode(mode)
        updateMatches()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    private func setUp() {
        wantsLayer = true
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        addSubview(background)
        shadow = NSShadow()
        layer?.shadowOpacity = 0.2
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        for field in [searchField, replaceField] {
            field.delegate = self
            field.font = .systemFont(ofSize: 12)
            field.bezelStyle = .roundedBezel
            field.focusRingType = .none
            addSubview(field)
        }
        searchField.placeholderString = "Search"
        replaceField.placeholderString = "Replace"
        resultLabel.font = .systemFont(ofSize: 11)
        resultLabel.textColor = .secondaryLabelColor
        addSubview(resultLabel)

        func configure(_ button: NSButton, symbol: String, label: String, action: Selector, toggle: Bool = false) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imagePosition = .imageOnly
            button.bezelStyle = .inline
            button.isBordered = false
            button.setButtonType(toggle ? .pushOnPushOff : .momentaryPushIn)
            button.toolTip = label
            button.target = self
            button.action = action
            addSubview(button)
        }
        configure(caseToggle, symbol: "textformat", label: "Match Case", action: #selector(toggleCase), toggle: true)
        configure(wordToggle, symbol: "text.word.spacing", label: "Whole Word", action: #selector(toggleWord), toggle: true)
        configure(regexToggle, symbol: "asterisk", label: "Regexp", action: #selector(toggleRegex), toggle: true)
        configure(previousButton, symbol: "arrow.up", label: "Previous Match", action: #selector(previousMatch))
        configure(nextButton, symbol: "arrow.down", label: "Next Match", action: #selector(nextMatch))
        configure(closeButton, symbol: "xmark", label: "Close", action: #selector(closePanel))
        configure(expandButton, symbol: "chevron.right", label: "Toggle Replace", action: #selector(toggleReplace))
        for button in [replaceButton, replaceAllButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self
            addSubview(button)
        }
        replaceButton.action = #selector(replaceOne)
        replaceAllButton.action = #selector(replaceAll)
    }

    // MARK: Layout

    static let width: CGFloat = 420
    var preferredHeight: CGFloat { mode == .replace ? 64 : 36 }

    override func layout() {
        super.layout()
        background.frame = bounds
        let rowHeight: CGFloat = 22
        let top: CGFloat = 7
        expandButton.frame = CGRect(x: 4, y: top, width: 18, height: rowHeight)
        var right = bounds.width - 6
        func place(_ view: NSView, width: CGFloat, y: CGFloat = top) {
            right -= width
            view.frame = CGRect(x: right, y: y, width: width, height: rowHeight)
            right -= 2
        }
        place(closeButton, width: 20)
        place(nextButton, width: 20)
        place(previousButton, width: 20)
        place(resultLabel, width: 70)
        resultLabel.frame.origin.y += 4
        place(regexToggle, width: 20)
        place(wordToggle, width: 20)
        place(caseToggle, width: 20)
        searchField.frame = CGRect(x: 24, y: top, width: max(80, right - 26), height: rowHeight)
        let replaceTop = top + rowHeight + 6
        replaceField.isHidden = mode != .replace
        replaceButton.isHidden = mode != .replace
        replaceAllButton.isHidden = mode != .replace
        replaceAllButton.frame = CGRect(x: bounds.width - 6 - 44, y: replaceTop, width: 44, height: rowHeight)
        replaceButton.frame = CGRect(x: replaceAllButton.frame.minX - 66, y: replaceTop, width: 64, height: rowHeight)
        replaceField.frame = CGRect(x: 24, y: replaceTop, width: searchField.frame.width, height: rowHeight)
    }

    // MARK: State

    func applyMode(_ mode: Mode) {
        self.mode = mode
        expandButton.image = NSImage(systemSymbolName: mode == .replace ? "chevron.down" : "chevron.right", accessibilityDescription: "Toggle Replace")
        needsLayout = true
        (superview as? DiffsDocumentView)?.needsLayout = true
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    func updateMatches(syncSelection: Bool = true) {
        matches = params.text.isEmpty ? [] : hooks.search(params)
        let none = matches.isEmpty
        previousButton.isEnabled = !none
        nextButton.isEnabled = !none
        if none {
            resultLabel.stringValue = "No results"
            current = nil
            _ = hooks.onUpdate([], syncSelection)
            return
        }
        updateCurrent(hooks.onUpdate(matches, syncSelection))
    }

    private func updateCurrent(_ match: (start: Int, end: Int)?) {
        if let match, let index = matches.firstIndex(where: { $0.start == match.start && $0.end == match.end }) {
            resultLabel.stringValue = "\(index + 1) of \(matches.count)"
        } else {
            resultLabel.stringValue = "\(matches.count) results"
        }
        current = match
    }

    /// `findNextMatch`.
    func navigate(previous: Bool, retainFocus: Bool = true) {
        var next = matches.first
        if !matches.isEmpty {
            if previous {
                let offset = current?.start ?? 0
                next = matches.last
                for match in matches {
                    if match.end <= offset { next = match } else { break }
                }
            } else {
                let offset = current?.end ?? 0
                for match in matches where match.start >= offset {
                    next = match
                    break
                }
            }
        }
        if let next {
            updateCurrent(next)
            hooks.scrollToMatch(next, retainFocus)
        }
        current = next
    }

    // MARK: Actions

    @objc private func toggleCase() {
        params.caseSensitive = caseToggle.state == .on
        updateMatches()
    }

    @objc private func toggleWord() {
        params.wholeWord = wordToggle.state == .on
        updateMatches()
    }

    @objc private func toggleRegex() {
        params.regex = regexToggle.state == .on
        updateMatches()
    }

    @objc private func previousMatch() { navigate(previous: true) }
    @objc private func nextMatch() { navigate(previous: false) }
    @objc private func toggleReplace() { applyMode(mode == .replace ? .find : .replace) }

    @objc func closePanel() {
        removeFromSuperview()
        hooks.onClose()
    }

    @objc private func replaceOne() {
        guard !params.text.isEmpty, !matches.isEmpty else { return }
        if current == nil { navigate(previous: false) }
        guard let match = current else { return }
        let text = hooks.replacementText(params, match.start, match.end)
        hooks.applyReplace([ResolvedTextEdit(start: match.start, end: match.end, text: text)])
        let caret = match.start + text.utf16.count
        hooks.scrollToMatch((caret, caret), true)
        current = nil
        updateMatches()
    }

    @objc private func replaceAll() {
        guard !params.text.isEmpty, !matches.isEmpty else { return }
        hooks.applyReplace(matches.map { ResolvedTextEdit(start: $0.start, end: $0.end, text: hooks.replacementText(params, $0.start, $0.end)) })
        current = nil
        updateMatches()
    }

    // MARK: Text fields

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === searchField {
            params.text = field.stringValue
            current = nil
            updateMatches()
        } else {
            params.replaceText = field.stringValue
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            closePanel()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if control === replaceField {
                replaceOne()
            } else {
                navigate(previous: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            }
            return true
        default:
            return false
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let keyEvent = editorKeyEvent(from: event)
        if let direction = resolveFindAgainShortcut(keyEvent) {
            navigate(previous: direction == .previous)
            return true
        }
        if isPrimaryModifier(metaKey: keyEvent.metaKey, ctrlKey: keyEvent.ctrlKey), keyEvent.key.lowercased() == "f" || keyEvent.code == "KeyF" {
            applyMode(keyEvent.altKey ? .replace : .find)
            focusSearchField()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
