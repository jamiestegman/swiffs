// Port of `editor/command.ts`: editor commands and keymaps.

import Foundation

/// Editor commands (`EditorCommand`).
public enum EditorCommand: String, Hashable, Sendable, CaseIterable {
    case indent, outdent, indentLess, indentMore, undo, redo, selectAll, findNextMatch
    case openSearchPanel, openSearchReplacePanel, moveLineUp, moveLineDown, copyLineUp, copyLineDown
    case simplifySelection, insertBlankLine, deleteHardLineForward, toggleComment, toggleBlockComment
    case moveCursorToDocStart, moveCursorToDocEnd, expandSelectionDocStart, expandSelectionDocEnd
}

/// Keymap platform.
public enum EditorPlatform: String, Hashable, Sendable {
    case mac, windows, linux
}

/// A key press, described like a DOM `KeyboardEvent`.
public struct EditorKeyEvent: Hashable, Sendable {
    /// The produced key (`event.key`), e.g. `"a"`, `"Enter"`, `"ArrowUp"`, `" "`.
    public var key: String
    /// The physical key (`event.code`), e.g. `"KeyA"`, `"Digit1"`, `"Slash"`.
    public var code: String?
    public var altKey: Bool
    public var ctrlKey: Bool
    public var metaKey: Bool
    public var shiftKey: Bool

    public init(key: String, code: String? = nil, altKey: Bool = false, ctrlKey: Bool = false, metaKey: Bool = false, shiftKey: Bool = false) {
        self.key = key
        self.code = code
        self.altKey = altKey
        self.ctrlKey = ctrlKey
        self.metaKey = metaKey
        self.shiftKey = shiftKey
    }
}

/// A keymap group; later groups take precedence (`EditorKeymap`).
public struct EditorKeymapGroup: Sendable {
    /// Nil applies on every platform.
    public var platform: EditorPlatform?
    /// Shortcut strings like `"cmdOrCtrl+shift+z"` to commands.
    public var bindings: [String: EditorCommand]

    public init(platform: EditorPlatform? = nil, bindings: [String: EditorCommand]) {
        self.platform = platform
        self.bindings = bindings
    }
}

public typealias EditorKeymap = [EditorKeymapGroup]

/// The default keymap (`defaultKeymap`).
public let defaultEditorKeymap: EditorKeymap = [
    EditorKeymapGroup(bindings: [
        "Tab": .indent,
        "shift+Tab": .outdent,
        "cmdOrCtrl+[": .indentLess,
        "cmdOrCtrl+]": .indentMore,
        "cmdOrCtrl+z": .undo,
        "cmdOrCtrl+shift+z": .redo,
        "cmdOrCtrl+a": .selectAll,
        "cmdOrCtrl+d": .findNextMatch,
        "cmdOrCtrl+f": .openSearchPanel,
        "cmdOrCtrl+alt+f": .openSearchReplacePanel,
        "alt+ArrowUp": .moveLineUp,
        "alt+ArrowDown": .moveLineDown,
        "shift+alt+ArrowUp": .copyLineUp,
        "shift+alt+ArrowDown": .copyLineDown,
        "Escape": .simplifySelection,
        "cmdOrCtrl+Enter": .insertBlankLine,
        "cmdOrCtrl+/": .toggleComment,
        "shift+alt+a": .toggleBlockComment,
        "cmdOrCtrl+Home": .moveCursorToDocStart,
        "cmdOrCtrl+End": .moveCursorToDocEnd,
        "cmdOrCtrl+shift+Home": .expandSelectionDocStart,
        "cmdOrCtrl+shift+End": .expandSelectionDocEnd,
    ]),
    EditorKeymapGroup(platform: .mac, bindings: [
        "ctrl+k": .deleteHardLineForward,
        "ctrl+alt+p": .moveLineUp,
        "ctrl+alt+n": .moveLineDown,
        "cmd+ArrowUp": .moveCursorToDocStart,
        "cmd+ArrowDown": .moveCursorToDocEnd,
        "cmd+shift+ArrowUp": .expandSelectionDocStart,
        "cmd+shift+ArrowDown": .expandSelectionDocEnd,
    ]),
    EditorKeymapGroup(platform: .windows, bindings: ["ctrl+y": .redo]),
    EditorKeymapGroup(platform: .linux, bindings: [
        "ctrl+y": .redo,
        "ctrl+alt+p": .moveLineUp,
        "ctrl+alt+n": .moveLineDown,
    ]),
]

/// Modifier mask → key → command, per platform.
public struct CompiledEditorKeymap: Sendable {
    var platforms: [EditorPlatform: [Int: [String: EditorCommand]]] = [:]

    public init(_ keymap: EditorKeymap) {
        for group in keymap {
            // Upstream iterates `Object.keys`, i.e. insertion order; within one
            // group a key maps to a single command, so order does not matter.
            for (shortcut, command) in group.bindings {
                var parts = shortcut.components(separatedBy: "+")
                // `cmdOrCtrl++` is not a valid shortcut; `+` never appears as
                // a key.
                let key = parts.removeLast()
                for platform in [EditorPlatform.mac, .windows, .linux] {
                    if let only = group.platform, only != platform { continue }
                    var modifiers = 0
                    for modifier in parts {
                        switch modifier {
                        case "alt": modifiers |= 1
                        case "ctrl": modifiers |= 2
                        case "cmd": modifiers |= 4
                        case "shift": modifiers |= 8
                        case "cmdOrCtrl": modifiers |= platform == .mac ? 4 : 2
                        default: break
                        }
                    }
                    platforms[platform, default: [:]][modifiers, default: [:]][key] = command
                }
            }
        }
    }

    func bindings(_ platform: EditorPlatform, _ modifiers: Int) -> [String: EditorCommand]? {
        platforms[platform]?[modifiers]
    }
}

private let compiledDefaultKeymap = CompiledEditorKeymap(defaultEditorKeymap)

private let keyboardCodeKeys: [String: String] = [
    "Backquote": "`", "Minus": "-", "Equal": "=", "Comma": ",", "Period": ".", "Slash": "/",
    "Semicolon": ";", "Quote": "'", "BracketLeft": "[", "BracketRight": "]", "Backslash": "\\", "Space": "Space",
]

/// The current platform.
public var currentEditorPlatform: EditorPlatform {
    #if os(macOS) || os(iOS)
    return .mac
    #elseif os(Linux)
    return .linux
    #else
    return .windows
    #endif
}

/// Resolves the command bound to a key press; a custom keymap takes
/// precedence over the default one (`resolveEditorCommandFromKeyboardEvent`).
public func resolveEditorCommand(_ event: EditorKeyEvent, keymap: CompiledEditorKeymap? = nil, platform: EditorPlatform = currentEditorPlatform) -> EditorCommand? {
    let eventKey = event.key == " " ? "Space" : (event.key.utf16.count == 1 ? event.key.lowercased() : event.key)
    let code = event.code ?? ""
    let codeKey: String?
    if code.hasPrefix("Key"), code.utf16.count == 4 {
        codeKey = String(code.dropFirst(3)).lowercased()
    } else if code.hasPrefix("Digit"), code.utf16.count == 6 {
        codeKey = String(code.dropFirst(5))
    } else {
        codeKey = keyboardCodeKeys[code]
    }
    let modifiers = (event.altKey ? 1 : 0) | (event.ctrlKey ? 2 : 0) | (event.metaKey ? 4 : 0) | (event.shiftKey ? 8 : 0)
    if let keymap {
        let bindings = keymap.bindings(platform, modifiers)
        if let command = bindings?[eventKey] ?? codeKey.flatMap({ bindings?[$0] }) {
            return command
        }
    }
    let bindings = compiledDefaultKeymap.bindings(platform, modifiers)
    return bindings?[eventKey] ?? codeKey.flatMap { bindings?[$0] }
}

/// Cmd/Ctrl+G and Shift+Cmd/Ctrl+G (`resolveFindAgainShortcut`).
public func resolveFindAgainShortcut(_ event: EditorKeyEvent, platform: EditorPlatform = currentEditorPlatform) -> FindDirection? {
    if event.altKey { return nil }
    guard isPrimaryModifier(metaKey: event.metaKey, ctrlKey: event.ctrlKey, platform: platform) else { return nil }
    let key = event.key.utf16.count == 1 ? event.key.lowercased() : event.key
    if key == "g" || event.code == "KeyG" {
        return event.shiftKey ? .previous : .next
    }
    return nil
}

public enum FindDirection: Sendable {
    case next, previous
}

/// Cmd on macOS, Ctrl elsewhere, without the other one (`isPrimaryModifier`).
public func isPrimaryModifier(metaKey: Bool, ctrlKey: Bool, platform: EditorPlatform = currentEditorPlatform) -> Bool {
    platform == .mac ? metaKey && !ctrlKey : ctrlKey && !metaKey
}
