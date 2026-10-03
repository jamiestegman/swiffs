import Foundation
import SwiffsCore
import SwiftUI

/// One entry in a diff view: a diff, a file, or a file with merge conflict
/// markers.
nonisolated public struct DiffItem: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case diff(FileDiffMetadata)
        case file(FileContents)
        /// A file containing conflict markers, shown as current against
        /// incoming with an action to resolve each conflict.
        case conflicted(FileContents)
    }

    /// Identifies the item across updates. Ids are unique within a list; an
    /// item repeating an earlier id is not shown.
    public var id: String
    public var content: Content
    /// Shows only the item's header.
    public var isCollapsed: Bool

    public init(id: String, content: Content, isCollapsed: Bool = false) {
        self.id = id
        self.content = content
        self.isCollapsed = isCollapsed
    }

    public static func diff(_ diff: FileDiffMetadata, id: String? = nil, isCollapsed: Bool = false) -> DiffItem {
        DiffItem(id: id ?? diff.name, content: .diff(diff), isCollapsed: isCollapsed)
    }

    public static func file(_ file: FileContents, id: String? = nil, isCollapsed: Bool = false) -> DiffItem {
        DiffItem(id: id ?? file.name, content: .file(file), isCollapsed: isCollapsed)
    }

    public static func conflicted(_ file: FileContents, id: String? = nil, isCollapsed: Bool = false) -> DiffItem {
        DiffItem(id: id ?? file.name, content: .conflicted(file), isCollapsed: isCollapsed)
    }

    /// The file name shown in the header.
    public var name: String {
        switch content {
        case .diff(let diff): diff.name
        case .file(let file), .conflicted(let file): file.name
        }
    }
}

/// Content the client shows under a line, identified by the client's own
/// id. Several annotations on one line stack in the order given.
nonisolated public struct DiffAnnotation<ID: Hashable & Sendable>: Identifiable, Hashable, Sendable {
    public var id: ID
    public var itemID: String
    /// The side of a diff the line is on; nil for files.
    public var side: AnnotationSide?
    /// One-based line number; 0 annotates the whole item, above its first
    /// line.
    public var lineNumber: Int

    public init(id: ID, itemID: String, side: AnnotationSide?, lineNumber: Int) {
        self.id = id
        self.itemID = itemID
        self.side = side
        self.lineNumber = lineNumber
    }
}

/// The annotation id of a diff view that shows no annotations.
nonisolated public enum NoAnnotation: Hashable, Sendable {
    /// Content for an annotation that cannot exist.
    static func content(_ id: NoAnnotation) -> EmptyView {}
}

/// Selected lines in one item.
nonisolated public struct DiffLineSelection: Hashable, Sendable {
    public var itemID: String
    public var range: SelectedLineRange

    public init(itemID: String, range: SelectedLineRange) {
        self.itemID = itemID
        self.range = range
    }
}

/// A conflict resolved with one of its actions. The client writes `file`
/// and passes it back as the item's new content.
nonisolated public struct DiffConflictResolution: Hashable, Sendable {
    public var itemID: String
    public var conflictIndex: Int
    public var resolution: MergeConflictResolution
    /// The item's file with this conflict resolved.
    public var file: FileContents
}

/// Where to scroll.
nonisolated public struct DiffScrollTarget: Hashable, Sendable {
    public enum Location: Hashable, Sendable {
        case item(String)
        case line(itemID: String, lineNumber: Int, side: AnnotationSide?)
        case range(itemID: String, range: SelectedLineRange)
    }

    public enum Alignment: Hashable, Sendable {
        case start, center, end
        /// Scrolls only as far as needed to show the target.
        case nearest
    }

    public enum Animation: Hashable, Sendable {
        case none
        case smooth
        /// Smooth for distances within two viewports, instant beyond.
        case automatic
    }

    public var location: Location
    public var alignment: Alignment
    public var animation: Animation

    public init(_ location: Location, alignment: Alignment = .start, animation: Animation = .automatic) {
        self.location = location
        self.alignment = alignment
        self.animation = animation
    }

    public static func item(_ id: String, alignment: Alignment = .start, animation: Animation = .automatic) -> DiffScrollTarget {
        DiffScrollTarget(.item(id), alignment: alignment, animation: animation)
    }

    public static func line(_ lineNumber: Int, side: AnnotationSide? = nil, in itemID: String, alignment: Alignment = .start, animation: Animation = .automatic) -> DiffScrollTarget {
        DiffScrollTarget(.line(itemID: itemID, lineNumber: lineNumber, side: side), alignment: alignment, animation: animation)
    }

    public static func range(_ range: SelectedLineRange, in itemID: String, alignment: Alignment = .start, animation: Animation = .automatic) -> DiffScrollTarget {
        DiffScrollTarget(.range(itemID: itemID, range: range), alignment: alignment, animation: animation)
    }
}
