// Swiffs demo: exercises FileDiffView, FileView and CodeView with the
// sample content from the upstream demo app.

import AppKit
import SwiftUI
import SwiffsCore
import SwiffsHighlight
import SwiffsUI

enum Example: String, CaseIterable, Identifiable {
    case diff = "File diff"
    case patch = "Patch (CodeView)"
    case file = "File"
    case markdown = "Markdown file"
    case ansi = "ANSI"
    case conflict = "Merge conflict"

    var id: String { rawValue }
}

func resource(_ name: String) -> String {
    let url = Bundle.module.url(forResource: "Resources/\(name)", withExtension: nil)!
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

@main
struct DemoApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        DemoSnapshot.scheduleIfRequested()
    }

    var body: some Scene {
        WindowGroup("Swiffs") {
            DemoView()
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

struct DemoView: View {
    @State private var example: Example = .diff
    @State private var diffStyle: DiffStyle = .split
    @State private var wrap = false
    @State private var themeType: ThemeType = .system
    @State private var theme = "pierre"
    @State private var indicators: DiffIndicators = .bars
    @State private var separators: HunkSeparators = .lineInfo
    @State private var lineDiffType: LineDiffType = .wordAlt
    @State private var hover = true
    @State private var selection: CodeViewLineSelection?
    @State private var conflictResetID = 0

    private static let fileDiff: FileDiffMetadata = {
        (try? parseDiffFromFile(
            oldFile: FileContents(name: "file.ts", contents: resource("fileOld.txt")),
            newFile: FileContents(name: "file.ts", contents: resource("fileNew.txt"))
        )) ?? FileDiffMetadata(name: "file.ts", isPartial: false)
    }()

    private static let patchItems: [CodeViewItem<String>] = {
        parsePatchFiles(resource("diff.patch")).flatMap(\.files).enumerated().map { index, file in
            .diff(id: "\(index)-\(file.name)", file)
        }
    }()

    private var themeSelection: ThemeSelection {
        switch theme {
        case "github": return .pair(ThemesType(dark: "github-dark", light: "github-light"))
        case "one": return .pair(ThemesType(dark: "one-dark-pro", light: "one-light"))
        case "catppuccin": return .pair(ThemesType(dark: "catppuccin-mocha", light: "catppuccin-latte"))
        default: return .pair(DiffsConstants.defaultThemes)
        }
    }

    private var diffOptions: DiffsDiffOptions {
        var options = DiffsDiffOptions()
        options.diffStyle = diffStyle
        options.code.overflow = wrap ? .wrap : .scroll
        options.code.themeType = themeType
        options.code.theme = themeSelection
        options.code.lineHoverHighlight = hover ? .both : .disabled
        options.code.enableLineSelection = true
        options.diffIndicators = indicators
        options.hunkSeparators = separators
        options.lineDiffType = lineDiffType
        return options
    }

    var body: some View {
        NavigationSplitView {
            List(Example.allCases, selection: Binding(get: { example }, set: { example = $0 ?? .diff })) { item in
                Text(item.rawValue).tag(item)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            content
                .toolbar { toolbar }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch example {
        case .diff:
            let items: [CodeViewItem<String>] = [
                .diff(
                    id: "diff",
                    Self.fileDiff,
                    annotations: [DiffLineAnnotation(side: .additions, lineNumber: 12, metadata: "Looks good!")]
                ),
            ]
            DiffsCodeList(
                items: items,
                options: codeViewOptions,
                selectedLines: selection,
                renderDiffAnnotation: { annotation, _ in annotationView(annotation.metadata) },
                onSelectedLinesChange: { selection = $0 }
            )
        case .patch:
            DiffsCodeList(items: Self.patchItems, options: codeViewOptions)
        case .file:
            DiffsCodeList(items: [CodeViewItem<String>.file(id: "file", FileContents(name: "example.ts", contents: resource("example_ts.txt")))], options: codeViewOptions)
        case .markdown:
            DiffsCodeList(items: [CodeViewItem<String>.file(id: "md", FileContents(name: "example.md", contents: resource("example_md.txt")))], options: codeViewOptions)
        case .ansi:
            DiffsCodeList(items: [CodeViewItem<String>.file(id: "ansi", FileContents(name: "output.log", contents: resource("fileAnsi.txt"), lang: "ansi"))], options: codeViewOptions)
        case .conflict:
            ScrollView {
                DiffsUnresolvedFile(
                    file: FileContents(name: "fileConflict.ts", contents: resource("fileConflict.txt")),
                    options: diffOptions
                )
                .id(conflictResetID)
            }
            .toolbar {
                Button("Reset conflicts") { conflictResetID += 1 }
            }
        }
    }

    private var codeViewOptions: CodeViewOptions {
        var options = CodeViewOptions()
        options.diff = diffOptions
        return options
    }

    private func annotationView(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        return container
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Style", selection: $diffStyle) {
                Text("Split").tag(DiffStyle.split)
                Text("Unified").tag(DiffStyle.unified)
            }
            .pickerStyle(.segmented)
            Toggle("Wrap", isOn: $wrap)
            Toggle("Hover", isOn: $hover)
            Picker("Theme", selection: $theme) {
                Text("Pierre").tag("pierre")
                Text("GitHub").tag("github")
                Text("One").tag("one")
                Text("Catppuccin").tag("catppuccin")
            }
            Picker("Appearance", selection: $themeType) {
                Text("System").tag(ThemeType.system)
                Text("Light").tag(ThemeType.light)
                Text("Dark").tag(ThemeType.dark)
            }
            Picker("Indicators", selection: $indicators) {
                Text("Bars").tag(DiffIndicators.bars)
                Text("Classic").tag(DiffIndicators.classic)
                Text("None").tag(DiffIndicators.none)
            }
            Picker("Separators", selection: $separators) {
                Text("Line info").tag(HunkSeparators.lineInfo)
                Text("Line info basic").tag(HunkSeparators.lineInfoBasic)
                Text("Metadata").tag(HunkSeparators.metadata)
                Text("Simple").tag(HunkSeparators.simple)
            }
            Picker("Line diff", selection: $lineDiffType) {
                Text("Word alt").tag(LineDiffType.wordAlt)
                Text("Word").tag(LineDiffType.word)
                Text("Char").tag(LineDiffType.char)
                Text("None").tag(LineDiffType.none)
            }
        }
    }
}


/// When `SWIFFS_DEMO_SNAPSHOT=/path/to.png` is set, captures the window
/// after a short delay (optionally scrolling by `SWIFFS_DEMO_SCROLL`) and
/// exits. Used for automated visual checks.
enum DemoSnapshot {
    static func scheduleIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SWIFFS_DEMO_SNAPSHOT"] else { return }
        let scroll = environment["SWIFFS_DEMO_SCROLL"].flatMap(Double.init) ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                guard let window = NSApplication.shared.windows.first, let content = window.contentView else { exit(1) }
                if scroll > 0, let scrollView = findScrollView(in: content) {
                    scrollView.contentView.scroll(to: CGPoint(x: 0, y: scroll))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    MainActor.assumeIsolated {
                        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { exit(1) }
                        content.cacheDisplay(in: content.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                        exit(0)
                    }
                }
            }
        }
    }

    @MainActor
    static func findScrollView(in view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView, scrollView.documentView is NSView, String(describing: type(of: scrollView.documentView!)).contains("CodeView") {
                return scrollView
            }
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }
}
