import AppKit
import SwiftUI
import SwiffsCore

/// Where a diff list is scrolled: the item at the top, kept current by the
/// list, and a target to scroll to.
public struct DiffScrollPosition: Equatable {
    public private(set) var target: DiffScrollTarget?
    /// The item at the top of the viewport.
    public internal(set) var itemID: String?
    var request = 0

    public init() {}

    /// Scrolls the list to a target.
    public mutating func scroll(to target: DiffScrollTarget) {
        self.target = target
        request += 1
    }
}

/// Content with the environment of the list that hosts it.
public struct EnvironmentBound<Content: View>: View {
    let content: Content
    let environment: EnvironmentValues

    public var body: some View {
        content.environment(\.self, environment)
    }
}

/// A scrolling list of diffs, files and conflicted files: `DiffView` in
/// SwiftUI. Annotation and accessory content takes the list's environment.
public struct DiffList<AnnotationID: Hashable & Sendable, Annotation: View, Accessory: View>: NSViewRepresentable {
    public typealias NSViewType = DiffView<AnnotationID, EnvironmentBound<Annotation>, EnvironmentBound<Accessory>>

    let items: [DiffItem]
    let annotations: [DiffAnnotation<AnnotationID>]
    let configuration: DiffConfiguration
    @Binding var selection: DiffLineSelection?
    @Binding var position: DiffScrollPosition
    let annotation: (AnnotationID) -> Annotation
    let accessory: (DiffItem) -> Accessory

    public init(
        _ items: [DiffItem],
        annotations: [DiffAnnotation<AnnotationID>] = [],
        configuration: DiffConfiguration = DiffConfiguration(),
        selection: Binding<DiffLineSelection?> = .constant(nil),
        position: Binding<DiffScrollPosition> = .constant(DiffScrollPosition()),
        @ViewBuilder annotation: @escaping (AnnotationID) -> Annotation,
        @ViewBuilder headerAccessory: @escaping (DiffItem) -> Accessory
    ) {
        self.items = items
        self.annotations = annotations
        self.configuration = configuration
        _selection = selection
        _position = position
        self.annotation = annotation
        accessory = headerAccessory
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> NSViewType {
        let environment = context.environment
        let view = NSViewType(
            configuration: configuration(context.environment),
            annotation: { [annotation] id in EnvironmentBound(content: annotation(id), environment: environment) },
            headerAccessory: { [accessory] item in EnvironmentBound(content: accessory(item), environment: environment) })
        view.delegate = context.coordinator
        return view
    }

    public func updateNSView(_ view: NSViewType, context: Context) {
        context.coordinator.list = self
        context.coordinator.environment = context.environment
        let environment = context.environment
        view.setContent(
            annotation: { [annotation] id in EnvironmentBound(content: annotation(id), environment: environment) },
            headerAccessory: { [accessory] item in EnvironmentBound(content: accessory(item), environment: environment) })
        view.update(items: items, annotations: annotations, configuration: configuration(environment))
        if view.lineSelection != selection { view.lineSelection = selection }
        if position.request != context.coordinator.appliedRequest {
            context.coordinator.appliedRequest = position.request
            if let target = position.target { view.scroll(to: target) }
        }
    }

    private func configuration(_ environment: EnvironmentValues) -> DiffConfiguration {
        var configuration = configuration
        if environment.diffFileLoader != nil { configuration.loadsFullFiles = true }
        return configuration
    }

    public final class Coordinator: DiffViewDelegate {
        var list: DiffList
        var environment = EnvironmentValues()
        var appliedRequest = 0

        init(_ list: DiffList) {
            self.list = list
        }

        public func diffView(_ diffView: NSView, didChangeLineSelection selection: DiffLineSelection?) {
            list.selection = selection
        }

        public func diffView(_ diffView: NSView, didRequestGutterActionFor selection: DiffLineSelection) {
            environment.diffGutterAction?(selection)
        }

        public func diffView(_ diffView: NSView, didResolveConflict resolution: DiffConflictResolution) {
            environment.diffConflictResolution?(resolution)
        }

        public func diffView(_ diffView: NSView, didScrollToItem itemID: String?) {
            guard list.position.itemID != itemID else { return }
            list.position.itemID = itemID
        }

        public func diffView(_ diffView: NSView, loadFilesFor diff: FileDiffMetadata, itemID: String) async throws -> DiffLoadedFiles {
            guard let load = environment.diffFileLoader else { throw CancellationError() }
            return try await load(diff, itemID)
        }
    }
}

extension DiffList where Accessory == EmptyView {
    public init(
        _ items: [DiffItem],
        annotations: [DiffAnnotation<AnnotationID>] = [],
        configuration: DiffConfiguration = DiffConfiguration(),
        selection: Binding<DiffLineSelection?> = .constant(nil),
        position: Binding<DiffScrollPosition> = .constant(DiffScrollPosition()),
        @ViewBuilder annotation: @escaping (AnnotationID) -> Annotation
    ) {
        self.init(items, annotations: annotations, configuration: configuration, selection: selection, position: position, annotation: annotation) { _ in EmptyView() }
    }
}

extension DiffList where AnnotationID == NoAnnotation, Annotation == EmptyView, Accessory == EmptyView {
    public init(
        _ items: [DiffItem],
        configuration: DiffConfiguration = DiffConfiguration(),
        selection: Binding<DiffLineSelection?> = .constant(nil),
        position: Binding<DiffScrollPosition> = .constant(DiffScrollPosition())
    ) {
        self.init(items, configuration: configuration, selection: selection, position: position, annotation: NoAnnotation.content) { _ in EmptyView() }
    }
}

private struct GutterActionKey: EnvironmentKey {
    static var defaultValue: (@MainActor (DiffLineSelection) -> Void)? { nil }
}

private struct ConflictResolutionKey: EnvironmentKey {
    static var defaultValue: (@MainActor (DiffConflictResolution) -> Void)? { nil }
}

private struct FileLoaderKey: EnvironmentKey {
    static var defaultValue: (@MainActor (FileDiffMetadata, String) async throws -> DiffLoadedFiles)? { nil }
}

/// Handlers only `DiffList` reads, so holding closures costs no other view
/// an update.
extension EnvironmentValues {
    var diffGutterAction: (@MainActor (DiffLineSelection) -> Void)? {
        get { self[GutterActionKey.self] }
        set { self[GutterActionKey.self] = newValue }
    }

    var diffConflictResolution: (@MainActor (DiffConflictResolution) -> Void)? {
        get { self[ConflictResolutionKey.self] }
        set { self[ConflictResolutionKey.self] = newValue }
    }

    var diffFileLoader: (@MainActor (FileDiffMetadata, String) async throws -> DiffLoadedFiles)? {
        get { self[FileLoaderKey.self] }
        set { self[FileLoaderKey.self] = newValue }
    }
}

extension View {
    /// Performs an action when the user presses or drags from a diff list's
    /// gutter action button, with the lines it applies to.
    public func onDiffGutterAction(perform action: @escaping @MainActor (DiffLineSelection) -> Void) -> some View {
        environment(\.diffGutterAction, action)
    }

    /// Performs an action when the user resolves a conflict in a diff list.
    /// Pass `resolution.file` back as the item's content to show the result.
    public func onDiffConflictResolution(perform action: @escaping @MainActor (DiffConflictResolution) -> Void) -> some View {
        environment(\.diffConflictResolution, action)
    }

    /// Loads full files for partial diffs, so a diff list can expand their
    /// hidden context.
    public func diffFileLoader(_ load: @escaping @MainActor (FileDiffMetadata, String) async throws -> DiffLoadedFiles) -> some View {
        environment(\.diffFileLoader, load)
    }
}
