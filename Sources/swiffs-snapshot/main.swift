// Renders a diff view offscreen to PNG, to compare rendering across
// changes and against upstream's screenshots.
//
// Usage: swiffs-snapshot <case.json> <output.png>
//
// Case JSON:
//   { "kind": "diff" | "file" | "unresolved" | "stream", "scheme": "light" | "dark", "width": 900,
//     "oldFile": {...}, "newFile": {...}, "file": {...},
//     "options": { "diffStyle": "split", "hunkSeparators": "line-info", ... },
//     "annotations": [{ "side": "additions", "lineNumber": 4 }],
//     "selectedLines": { "start": 3, "end": 5, "side": "additions" },
//     "clicks": [[x, y]] }

import AppKit
import SwiftUI
import SwiffsCore
import SwiffsHighlight
import SwiffsUI

struct Case: Decodable {
    struct Options: Decodable {
        var diffStyle: String?
        var hunkSeparators: String?
        var diffIndicators: String?
        var overflow: String?
        var expansionLineCount: Int?
        var disableLineNumbers: Bool?
        var disableBackground: Bool?
        var disableFileHeader: Bool?
        var lineDiffType: String?
        var expandUnchanged: Bool?
        var theme: Theme?
    }

    enum Theme: Decodable {
        case single(String)
        case pair([String: String])

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(String.self) {
                self = .single(single)
            } else {
                self = .pair(try container.decode([String: String].self))
            }
        }

        var selection: ThemeSelection {
            switch self {
            case .single(let name): .single(name)
            case .pair(let pair): .pair(ThemesType(dark: pair["dark"] ?? "pierre-dark", light: pair["light"] ?? "pierre-light"))
            }
        }
    }

    struct Annotation: Decodable {
        var side: String?
        var lineNumber: Int
    }

    var kind: String
    var lang: String?
    var scheme: String?
    var width: Double?
    var oldFile: FileContents?
    var newFile: FileContents?
    var file: FileContents?
    var options: Options?
    var annotations: [Annotation]?
    var selectedLines: SelectedLineRange?
    /// A patch shown as a partial diff whose full files load from
    /// `oldFile` and `newFile`; `expand` hunks are expanded.
    var patch: String?
    var expand: [Int]?
    /// Points clicked before capture, top-left origin.
    var clicks: [[Double]]?
    /// Drags `[x0, y0, x1, y1, clickCount?]`, top-left origin.
    var drags: [[Double]]?
}

struct AnnotationLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Font(DiffTypography.defaultCodeFont(size: 13)))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

func configuration(_ testCase: Case) -> DiffConfiguration {
    var configuration = DiffConfiguration()
    configuration.padding = 0
    configuration.stickyHeaders = false
    configuration.synchronousHighlightLineLimit = .max
    configuration.colorScheme = testCase.scheme == "dark" ? .dark : .light
    guard let options = testCase.options else { return configuration }
    if let value = options.diffStyle.flatMap(DiffStyle.init(rawValue:)) { configuration.style = value }
    if let value = options.hunkSeparators.flatMap(HunkSeparators.init(rawValue:)) { configuration.hunkSeparators = value }
    if let value = options.diffIndicators.flatMap(DiffIndicators.init(rawValue:)) { configuration.indicators = value }
    if let value = options.overflow.flatMap(Overflow.init(rawValue:)) { configuration.overflow = value }
    if let value = options.lineDiffType.flatMap(LineDiffType.init(rawValue:)) { configuration.lineDiffType = value }
    if let value = options.expansionLineCount { configuration.expansionLineCount = value }
    if let value = options.expandUnchanged { configuration.expandsUnchanged = value }
    if options.disableLineNumbers == true { configuration.showsLineNumbers = false }
    if options.disableBackground == true { configuration.showsBackgrounds = false }
    if options.disableFileHeader == true { configuration.showsHeaders = false }
    if let theme = options.theme { configuration.theme = theme.selection }
    return configuration
}

func item(_ testCase: Case) throws -> DiffItem {
    switch testCase.kind {
    case "file", "stream":
        guard var file = testCase.file else { throw CocoaError(.fileReadCorruptFile) }
        if let lang = testCase.lang { file.lang = lang }
        return .file(file)
    case "unresolved":
        guard let file = testCase.file else { throw CocoaError(.fileReadCorruptFile) }
        return .conflicted(file)
    default:
        if let patch = testCase.patch { return .diff(try getSingularPatch(patch)) }
        return .diff(try parseDiffFromFile(oldFile: testCase.oldFile, newFile: testCase.newFile))
    }
}

func annotations(_ testCase: Case, item: DiffItem) -> [DiffAnnotation<String>] {
    (testCase.annotations ?? []).map { annotation in
        let side = item.isFile ? nil : AnnotationSide(rawValue: annotation.side ?? "additions") ?? .additions
        let label = side.map { "Annotation on \($0.rawValue) \(annotation.lineNumber)" } ?? "Annotation on \(annotation.lineNumber)"
        return DiffAnnotation(id: label, itemID: item.id, side: side, lineNumber: annotation.lineNumber)
    }
}

extension DiffItem {
    var isFile: Bool {
        if case .file = content { return true }
        return false
    }
}

/// Acts as the client: loads full files and applies conflict resolutions.
final class Client: DiffViewDelegate {
    let testCase: Case
    var resolved: DiffConflictResolution?

    init(_ testCase: Case) {
        self.testCase = testCase
    }

    func diffView(_ diffView: NSView, didResolveConflict resolution: DiffConflictResolution) {
        resolved = resolution
    }

    func diffView(_ diffView: NSView, loadFilesFor diff: FileDiffMetadata, itemID: String) async throws -> DiffLoadedFiles {
        guard let newFile = testCase.newFile else { throw CocoaError(.fileReadNoSuchFile) }
        return DiffLoadedFiles(oldFile: testCase.oldFile, newFile: newFile)
    }
}

func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 3 else {
        FileHandle.standardError.write("usage: swiffs-snapshot <case.json> <output.png>\n".data(using: .utf8)!)
        exit(2)
    }
    let testCase = try JSONDecoder().decode(Case.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
    let width = CGFloat(testCase.width ?? 900)
    let appearance = NSAppearance(named: testCase.scheme == "dark" ? .darkAqua : .aqua)!
    let item = try item(testCase)
    let view = DiffView(configuration: configuration(testCase)) { (label: String) in AnnotationLabel(text: label) }
    view.appearance = appearance
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 4000), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = view

    func fit() {
        view.layoutSubtreeIfNeeded()
        let height = max(1, view.contentHeight)
        window.setContentSize(CGSize(width: width, height: height))
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
    }

    let client = Client(testCase)
    view.delegate = client
    var configuration = configuration(testCase)
    configuration.loadsFullFiles = testCase.patch != nil
    view.update(items: [item], annotations: annotations(testCase, item: item), configuration: configuration)
    if let selected = testCase.selectedLines { view.lineSelection = DiffLineSelection(itemID: item.id, range: selected) }
    fit()
    fit()
    for hunk in testCase.expand ?? [] {
        view.expand(hunk: hunk, inItem: item.id)
        // Loading files is asynchronous; let it finish.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        fit()
    }
    for click in testCase.clicks ?? [] {
        let location = CGPoint(x: click[0], y: view.frame.height - click[1])
        guard let target = window.contentView?.hitTest(location) else { continue }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
        }
        if let resolution = client.resolved {
            client.resolved = nil
            view.update(items: [.conflicted(resolution.file, id: item.id)], configuration: configuration)
        }
        fit()
    }

    for drag in testCase.drags ?? [] {
        let start = CGPoint(x: drag[0], y: view.frame.height - drag[1])
        let end = CGPoint(x: drag[2], y: view.frame.height - drag[3])
        let clickCount = drag.count > 4 ? Int(drag[4]) : 1
        guard let target = window.contentView?.hitTest(start) else { continue }
        func event(_ type: NSEvent.EventType, _ location: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
        }
        target.mouseDown(with: event(.leftMouseDown, start))
        if start != end { target.mouseDragged(with: event(.leftMouseDragged, end)) }
        target.mouseUp(with: event(.leftMouseUp, end))
    }

    let height = view.frame.height
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = CGSize(width: width, height: height)
    appearance.performAsCurrentDrawingAppearance {
        view.cacheDisplay(in: view.bounds, to: rep)
    }
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
    print("\(arguments[2]) \(Int(width))x\(Int(height))")
}

_ = NSApplication.shared
do {
    try run()
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
