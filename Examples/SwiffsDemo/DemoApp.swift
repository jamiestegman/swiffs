import SwiftUI
import SwiffsCore
import SwiffsUI

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup("Swiffs") {
            DemoView()
        }
        .defaultSize(width: 1200, height: 820)
    }
}

enum Sample: String, CaseIterable, Identifiable {
    case patch = "Patch"
    case conflict = "Conflict"
    case growing = "Growing file"

    var id: Self { self }
}

struct Comment: Identifiable, Hashable {
    let id: UUID
    let itemID: String
    let range: SelectedLineRange
    var text: String
    var isDraft: Bool

    var annotation: DiffAnnotation<UUID> {
        DiffAnnotation(id: id, itemID: itemID, side: range.endSide ?? range.side, lineNumber: range.end)
    }
}

@Observable final class DemoModel {
    var sample = Sample.patch
    var items: [DiffItem] = []
    var comments: [Comment] = []
    var viewed: Set<String> = []
    var selection: DiffLineSelection?
    var position = DiffScrollPosition()
    var split = true
    var wraps = false
    private var growth: Task<Void, Never>?

    init() {
        show(.patch)
    }

    var configuration: DiffConfiguration {
        var configuration = DiffConfiguration()
        configuration.style = split ? .split : .unified
        configuration.overflow = wraps ? .wrap : .scroll
        configuration.lineHoverHighlight = .both
        configuration.allowsLineSelection = true
        configuration.showsGutterAction = true
        configuration.gutterActionLabel = "Comment"
        return configuration
    }

    var displayedItems: [DiffItem] {
        items.map { item in
            var item = item
            item.isCollapsed = viewed.contains(item.id)
            return item
        }
    }

    func show(_ sample: Sample) {
        growth?.cancel()
        comments = []
        viewed = []
        selection = nil
        switch sample {
        case .patch:
            // The patch has several commits, so a file can appear more than once.
            items = parsePatchFiles(Self.resource("diff.patch")).flatMap(\.files).enumerated().map { DiffItem.diff($1, id: "\($0) \($1.name)") }
        case .conflict:
            items = [.conflicted(FileContents(name: "fileConflict.ts", contents: Self.resource("fileConflict.txt")))]
        case .growing:
            items = [.file(FileContents(name: "example.ts", contents: ""))]
            grow()
        }
        position.scroll(to: .item(items.first?.id ?? "", animation: .none))
    }

    /// Appends the example a few characters at a time, as an agent writes a file.
    private func grow() {
        let text = Self.resource("example_ts.txt")
        growth = Task { [weak self] in
            var written = text.startIndex
            while written < text.endIndex, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                let end = text.index(written, offsetBy: 24, limitedBy: text.endIndex) ?? text.endIndex
                written = end
                self?.items = [.file(FileContents(name: "example.ts", contents: String(text[..<written])))]
            }
        }
    }

    func startComment(on lines: DiffLineSelection) {
        comments.removeAll { $0.isDraft }
        comments.append(Comment(id: UUID(), itemID: lines.itemID, range: lines.range, text: "", isDraft: true))
    }

    func resolve(_ resolution: DiffConflictResolution) {
        items = items.map { $0.id == resolution.itemID ? .conflicted(resolution.file, id: $0.id) : $0 }
    }

    func comment(_ id: UUID) -> Comment? {
        comments.first { $0.id == id }
    }

    func update(_ id: UUID, _ change: (inout Comment) -> Void) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else { return }
        change(&comments[index])
    }

    private static func resource(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: "Resources/\(name)", withExtension: nil), let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }
}

struct DemoView: View {
    @State private var model = DemoModel()

    var body: some View {
        DiffList(
            model.displayedItems, annotations: model.comments.map(\.annotation), configuration: model.configuration,
            selection: $model.selection, position: $model.position
        ) { id in
            CommentCard(model: model, id: id)
        } headerAccessory: { item in
            Toggle("Viewed", isOn: Binding(
                get: { model.viewed.contains(item.id) },
                set: { if $0 { model.viewed.insert(item.id) } else { model.viewed.remove(item.id) } }))
                .toggleStyle(.checkbox)
                .font(.callout)
        }
        .onDiffGutterAction { model.startComment(on: $0) }
        .onDiffConflictResolution { model.resolve($0) }
        .toolbar {
            Picker("Sample", selection: Binding(get: { model.sample }, set: { model.sample = $0; model.show($0) })) {
                ForEach(Sample.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Split", isOn: $model.split)
            Toggle("Wrap", isOn: $model.wraps)
            if let id = model.position.itemID {
                Text(id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// A comment under its lines: a form while drafting, a card once added.
struct CommentCard: View {
    let model: DemoModel
    let id: UUID

    var body: some View {
        if let comment = model.comment(id) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Lines \(comment.range.start) to \(comment.range.end)").font(.caption).foregroundStyle(.secondary)
                if comment.isDraft {
                    TextField("Leave a comment", text: Binding(get: { model.comment(id)?.text ?? "" }, set: { text in model.update(id) { $0.text = text } }), axis: .vertical)
                        .lineLimit(1 ... 9)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer()
                        Button("Cancel") { model.comments.removeAll { $0.id == id } }
                        Button("Add comment") {
                            model.update(id) { $0.isDraft = false }
                            model.selection = nil
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(comment.text.isEmpty)
                    }
                } else {
                    Text(comment.text)
                }
            }
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .padding(8)
        }
    }
}
