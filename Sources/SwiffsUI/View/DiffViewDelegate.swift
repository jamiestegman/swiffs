import AppKit
import SwiffsCore

/// What a diff view reports to its owner. Every method has a default that
/// does nothing.
public protocol DiffViewDelegate: AnyObject {
    /// The user changed the selected lines.
    func diffView(_ diffView: NSView, didChangeLineSelection selection: DiffLineSelection?)
    /// The user pressed or dragged from the gutter action button.
    func diffView(_ diffView: NSView, didRequestGutterActionFor selection: DiffLineSelection)
    /// The user resolved a conflict. Pass `resolution.file` back as the
    /// item's content to show the result.
    func diffView(_ diffView: NSView, didResolveConflict resolution: DiffConflictResolution)
    /// The item at the top of the viewport changed.
    func diffView(_ diffView: NSView, didScrollToItem itemID: String?)
    /// Loads the full files of a partial diff so its hidden context can be
    /// expanded. Called when `DiffConfiguration.loadsFullFiles` is set.
    func diffView(_ diffView: NSView, loadFilesFor diff: FileDiffMetadata, itemID: String) async throws -> DiffLoadedFiles
}

public extension DiffViewDelegate {
    func diffView(_ diffView: NSView, didChangeLineSelection selection: DiffLineSelection?) {}
    func diffView(_ diffView: NSView, didRequestGutterActionFor selection: DiffLineSelection) {}
    func diffView(_ diffView: NSView, didResolveConflict resolution: DiffConflictResolution) {}
    func diffView(_ diffView: NSView, didScrollToItem itemID: String?) {}
    func diffView(_ diffView: NSView, loadFilesFor diff: FileDiffMetadata, itemID: String) async throws -> DiffLoadedFiles {
        throw CancellationError()
    }
}
