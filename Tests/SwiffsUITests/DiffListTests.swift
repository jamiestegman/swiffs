import AppKit
import SwiftUI
import SwiffsCore
import Testing
@testable import SwiffsUI

private struct Probe: EnvironmentKey {
    static var defaultValue: String { "default" }
}

extension EnvironmentValues {
    var probe: String {
        get { self[Probe.self] }
        set { self[Probe.self] = newValue }
    }
}

@Observable final class ListState {
    var selection: DiffLineSelection?
    var position = DiffScrollPosition()
    var actions: [DiffLineSelection] = []
    var resolutions: [DiffConflictResolution] = []
    var items: [DiffItem]

    init(items: [DiffItem]) {
        self.items = items
    }
}

/// Reads an environment value set outside the list.
private struct EnvironmentLabel: View {
    @Environment(\.probe) private var probe

    var body: some View {
        Text(probe).frame(height: CGFloat(probe.count) * 10)
    }
}

private struct ListScreen: View {
    @Bindable var state: ListState
    var configuration = Fixtures.configuration()

    var body: some View {
        DiffList(
            state.items, annotations: [DiffAnnotation(id: "a", itemID: state.items[0].id, side: .additions, lineNumber: 1)], configuration: configuration,
            selection: $state.selection, position: $state.position
        ) { _ in
            EnvironmentLabel()
        } headerAccessory: { _ in
            EnvironmentLabel()
        }
        .onDiffGutterAction { state.actions.append($0) }
        .onDiffConflictResolution { state.resolutions.append($0) }
        .environment(\.probe, "outside")
    }
}

private typealias ScreenView = DiffList<String, EnvironmentLabel, EnvironmentLabel>.NSViewType

struct DiffListTests {
    private func host(_ state: ListState, configuration: DiffConfiguration = Fixtures.configuration()) throws -> (HostingWindow<ListScreen>, ScreenView) {
        let window = HostingWindow(ListScreen(state: state, configuration: configuration))
        return (window, try #require(window.find(ScreenView.self)))
    }

    @Test func hostedContentReadsTheListsEnvironment() throws {
        let state = ListState(items: [.diff(try Fixtures.diff(step: 3))])
        let (_, view) = try host(state)
        let hosts = view.documentView.subviews.compactMap { $0 as? NSHostingView<WidthBoundContent<EnvironmentBound<EnvironmentLabel>>> }
        #expect(hosts.first?.frame.height == 70, "the annotation read \"outside\", seven characters")
    }

    @Test func selectionIsABinding() throws {
        var configuration = Fixtures.configuration()
        configuration.allowsLineSelection = true
        let state = ListState(items: [.diff(try Fixtures.diff(step: 3))])
        let (window, view) = try host(state, configuration: configuration)
        let selection = DiffLineSelection(itemID: "a.swift", range: SelectedLineRange(start: 2, side: .additions, end: 4))
        state.selection = selection
        window.layout()
        #expect(view.lineSelection == selection)
        view.documentView.setLineSelection(nil)
        #expect(state.selection == nil)
    }

    @Test func gutterActionsAndResolutionsReachTheirModifiers() throws {
        let state = ListState(items: [.conflicted(ConflictTests.file)])
        let (_, view) = try host(state)
        let item = try #require(view.layoutModel.item("c.swift"))
        view.documentView(view.documentView, resolve: item, conflict: 0, resolution: .both)
        #expect(state.resolutions.map(\.resolution) == [.both])
        let action = DiffLineSelection(itemID: "c.swift", range: SelectedLineRange(start: 1, side: .additions, end: 1))
        view.documentView(view.documentView, didRequestGutterAction: action)
        #expect(state.actions == [action])
    }

    @Test func scrollPositionScrollsAndFollowsTheTopItem() throws {
        let state = ListState(items: try (0 ..< 20).map { .diff(try Fixtures.diff(name: "f\($0).swift")) })
        let (window, view) = try host(state)
        state.position.scroll(to: .item("f6.swift", animation: .none))
        window.layout()
        #expect(view.topItemID == "f6.swift")
        #expect(state.position.itemID == "f6.swift")
    }

    @Test func aScrollAskedForBeforeLayoutHappensOnceLaidOut() throws {
        let state = ListState(items: try (0 ..< 20).map { .diff(try Fixtures.diff(name: "f\($0).swift")) })
        state.position.scroll(to: .item("f9.swift", animation: .none))
        let (_, view) = try host(state)
        #expect(view.topItemID == "f9.swift")
    }
}
