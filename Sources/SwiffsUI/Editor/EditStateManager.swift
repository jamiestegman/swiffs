// Port of `editor/EditStateManager.ts` and `cloneRetainedDiffSessionSnapshot.ts`:
// dormant edit state per `editStateKey`, kept in independent file and diff
// namespaces, with active-key exclusion.

import Foundation
import SwiffsCore
import SwiffsEditor

/// `EditorType`.
public enum EditorType: String, Hashable, Sendable {
    case file
    case fileDiff = "file-diff"
}

/// Horizontal and vertical scroll offsets (`EditorViewportState`).
public struct EditorViewportState: Hashable, Sendable {
    /// Horizontal position of the editable code columns.
    public var scrollLeft: CGFloat
    /// Vertical position of the editor viewport, when the editor owns one.
    public var scrollTop: CGFloat?

    public init(scrollLeft: CGFloat, scrollTop: CGFloat? = nil) {
        self.scrollLeft = scrollLeft
        self.scrollTop = scrollTop
    }
}

/// Restorable selections and viewport (`EditorViewState`).
public struct EditorViewState: Hashable, Sendable {
    public var selections: [EditorSelection]?
    public var view: EditorViewportState?

    public init(selections: [EditorSelection]? = nil, view: EditorViewportState? = nil) {
        self.selections = selections
        self.view = view
    }
}

/// The diff a retained session resumes (`RetainedDiffSessionSnapshot`).
public struct RetainedDiffSessionSnapshot: Hashable, Sendable {
    public struct OldFile: Hashable, Sendable {
        public var name: String
        public var lines: [String]

        public init(name: String, lines: [String]) {
            self.name = name
            self.lines = lines
        }
    }

    public var oldFile: OldFile?
    public var type: ChangeType
    public var hunks: [Hunk]

    public init(oldFile: OldFile?, type: ChangeType, hunks: [Hunk]) {
        self.oldFile = oldFile
        self.type = type
        self.hunks = hunks
    }
}

/// The objects that make up an edit session (`ManagedEditSession`). A class,
/// like upstream's shared object: state supplied as `initialState` is
/// transferred by reference.
@MainActor
public final class DiffsEditState<Annotation: EditorLineAnnotationPosition> {
    public let type: EditorType
    public var document: TextDocument<Annotation>?
    /// The edited file's name and language (`fileInfo`).
    public var fileInfo: (name: String, lang: SupportedLanguage?)?
    public var editor: EditorViewState?
    /// Diffs only.
    public var diffSession: RetainedDiffSessionSnapshot?

    public init(type: EditorType, document: TextDocument<Annotation>? = nil, fileInfo: (name: String, lang: SupportedLanguage?)? = nil, editor: EditorViewState? = nil, diffSession: RetainedDiffSessionSnapshot? = nil) {
        self.type = type
        self.document = document
        self.fileInfo = fileInfo
        self.editor = editor
        self.diffSession = diffSession
    }
}

/// Which parts of dormant state to clear (`ClearEditStateOptions`).
public struct ClearEditStateOptions: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let document = ClearEditStateOptions(rawValue: 1 << 0)
    public static let history = ClearEditStateOptions(rawValue: 1 << 1)
    public static let editor = ClearEditStateOptions(rawValue: 1 << 2)
    public static let selections = ClearEditStateOptions(rawValue: 1 << 3)
    public static let view = ClearEditStateOptions(rawValue: 1 << 4)
}

public enum EditStateManagerError: Error, Equatable {
    /// `editStateKey` is already attached to another editor.
    case keyInUse(String)
    /// `setCapacity` requires a positive integer.
    case invalidCapacity
    /// `initialState` has the wrong editor type.
    case typeMismatch
}

/// A complete session (`toManagedEditState`), or nil when the document, file
/// info or (for diffs) diff session is missing.
@MainActor
public func toManagedEditState<A>(_ session: DiffsEditState<A>) -> DiffsEditState<A>? {
    guard session.document != nil, session.fileInfo != nil else { return nil }
    if session.type == .fileDiff, session.diffSession == nil { return nil }
    if session.editor == nil { session.editor = EditorViewState() }
    return session
}

/// Protocol for type-erased access to a session's dormant parts.
@MainActor
private protocol AnyEditState: AnyObject {
    var type: EditorType { get }
    func clearHistory()
    func clearEditor(selections: Bool, view: Bool)
    func isComplete() -> Bool
}

extension DiffsEditState: AnyEditState {
    fileprivate func clearHistory() { document?.clearHistory() }
    fileprivate func clearEditor(selections: Bool, view: Bool) {
        guard editor != nil else { return }
        if selections { editor?.selections = nil }
        if view { editor?.view = nil }
    }
    fileprivate func isComplete() -> Bool { toManagedEditState(self) != nil }
}

/// Dormant edit state and active-key exclusion for one editor type.
@MainActor
private final class EditStateNamespace {
    let type: EditorType
    /// LRU order: least recently used first.
    private var states: [String: AnyEditState] = [:]
    private var order: [String] = []
    private var sessions: [String: (owner: ObjectIdentifier, session: AnyEditState)] = [:]
    var capacity = 100

    init(type: EditorType) {
        self.type = type
    }

    /// `accepts` filters retained state an editor cannot resume (a different
    /// annotation type); such state is dropped.
    func activate(_ key: String, owner: AnyObject, initialState: AnyEditState?, accepts: (AnyEditState) -> Bool, makeEmpty: () -> AnyEditState) throws -> AnyEditState {
        if let active = sessions[key] {
            guard active.owner == ObjectIdentifier(owner) else { throw EditStateManagerError.keyInUse(key) }
            if let initialState { sessions[key] = (active.owner, initialState) }
            return sessions[key]!.session
        }
        let retained = removeState(key).flatMap { accepts($0) ? $0 : nil }
        let state = initialState ?? retained ?? makeEmpty()
        sessions[key] = (ObjectIdentifier(owner), state)
        return state
    }

    func release(_ key: String, owner: AnyObject, discard: Bool) {
        guard let active = sessions[key], active.owner == ObjectIdentifier(owner) else { return }
        sessions.removeValue(forKey: key)
        if discard { return }
        if active.session.isComplete() { setState(key, active.session) }
    }

    func get(_ key: String) -> AnyEditState? {
        if let active = sessions[key] {
            return active.session.isComplete() ? active.session : nil
        }
        return states[key]
    }

    func clear(_ key: String, parts: ClearEditStateOptions?) -> Bool {
        if sessions[key] != nil { return false }
        guard let state = states[key] else { return false }
        if let parts, !parts.contains(.document) {
            if parts.contains(.history) { state.clearHistory() }
            state.clearEditor(
                selections: parts.contains(.editor) || parts.contains(.selections),
                view: parts.contains(.editor) || parts.contains(.view)
            )
        } else {
            removeState(key)
        }
        return true
    }

    func clearAll() {
        states = [:]
        order = []
    }

    func setCapacity(_ value: Int) {
        capacity = value
        evict()
    }

    private func setState(_ key: String, _ state: AnyEditState) {
        states[key] = state
        order.removeAll { $0 == key }
        order.append(key)
        evict()
    }

    @discardableResult
    private func removeState(_ key: String) -> AnyEditState? {
        guard let state = states.removeValue(forKey: key) else { return nil }
        order.removeAll { $0 == key }
        return state
    }

    private func evict() {
        while order.count > capacity {
            states.removeValue(forKey: order.removeFirst())
        }
    }
}

/// Keeps file and diff edit state in independent persistence domains
/// (`EditStateManager`).
@MainActor
public final class EditStateManager {
    public static let shared = EditStateManager()

    private let files = EditStateNamespace(type: .file)
    private let diffs = EditStateNamespace(type: .fileDiff)

    init() {}

    private func namespace(_ type: EditorType) -> EditStateNamespace {
        type == .file ? files : diffs
    }

    /// Marks a keyed session active and returns its initial or stored state.
    func activate<A>(_ type: EditorType, _ key: String, owner: AnyObject, initialState: DiffsEditState<A>?) throws -> DiffsEditState<A> {
        if let initialState, initialState.type != type { throw EditStateManagerError.typeMismatch }
        let state = try namespace(type).activate(key, owner: owner, initialState: initialState, accepts: { $0 is DiffsEditState<A> }) { DiffsEditState<A>(type: type) }
        guard let typed = state as? DiffsEditState<A> else {
            // The key is active with a different annotation type, which only
            // the same owner could have claimed.
            throw EditStateManagerError.keyInUse(key)
        }
        return typed
    }

    /// Stops tracking a session as active and stores its state unless
    /// `discard` is true (`releaseFile` / `releaseFileDiff`).
    func release(_ type: EditorType, _ key: String, owner: AnyObject, discard: Bool = false) {
        namespace(type).release(key, owner: owner, discard: discard)
    }

    /// Current state for an active or dormant session.
    public func get<A>(_ type: EditorType, _ key: String, annotation: A.Type = A.self) -> DiffsEditState<A>? {
        namespace(type).get(key) as? DiffsEditState<A>
    }

    /// Clears a dormant session; false when it is active or missing. Omit
    /// `parts` to clear everything.
    @discardableResult
    public func clear(_ type: EditorType, _ key: String, parts: ClearEditStateOptions? = nil) -> Bool {
        namespace(type).clear(key, parts: parts)
    }

    /// Clears all dormant sessions without affecting active editors.
    public func clearAll() {
        files.clearAll()
        diffs.clearAll()
    }

    public func setCapacity(_ capacity: Int) throws {
        guard capacity >= 1 else { throw EditStateManagerError.invalidCapacity }
        files.setCapacity(capacity)
        diffs.setCapacity(capacity)
    }
}
