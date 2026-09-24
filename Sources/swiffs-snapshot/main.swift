// Renders Swiffs views offscreen to PNG. Used to compare the native
// rendering against reference screenshots of the upstream library.
//
// Usage: swiffs-snapshot <case.json> <output.png>
//
// Case JSON format:
//   { "kind": "diff" | "file" | "unresolved", "scheme": "light" | "dark", "width": 900,
//     "oldFile": {...}, "newFile": {...}, "file": {...},
//     "options": { "diffStyle": "split", "hunkSeparators": "line-info", ... },
//     "annotations": [{ "side": "additions", "lineNumber": 4 }],
//     "selectedLines": { "start": 3, "end": 5, "side": "additions" } }

import AppKit
import SwiffsCore
import SwiffsEditor
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
        var theme: ThemeValue?
    }

    enum ThemeValue: Decodable {
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
            case .single(let name): return .single(name)
            case .pair(let pair): return .pair(ThemesType(dark: pair["dark"] ?? "pierre-dark", light: pair["light"] ?? "pierre-light"))
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
    /// Points (in view coordinates, top-left origin) clicked before capture.
    var clicks: [[Double]]?
    /// Drags `[x0, y0, x1, y1, clickCount?]`; the selected text is printed.
    var drags: [[Double]]?
    /// Editor actions for `kind: "edit"`.
    var editActions: [EditAction]?

    struct EditAction: Decodable {
        var type: String
        var text: String?
        var keyCode: UInt16?
        var chars: String?
        var mods: [String]?
        var x: Double?
        var y: Double?
        var clickCount: Int?
    }
}

@MainActor
func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 3 else {
        FileHandle.standardError.write("usage: swiffs-snapshot <case.json> <output.png>\n".data(using: .utf8)!)
        exit(2)
    }
    let testCase = try JSONDecoder().decode(Case.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
    let width = CGFloat(testCase.width ?? 900)
    let appearance = NSAppearance(named: testCase.scheme == "dark" ? .darkAqua : .aqua)!

    var options = DiffsDiffOptions()
    if let o = testCase.options {
        if let value = o.diffStyle { options.diffStyle = DiffStyle(rawValue: value) ?? .split }
        if let value = o.hunkSeparators { options.hunkSeparators = HunkSeparators(rawValue: value) ?? .lineInfo }
        if let value = o.diffIndicators { options.diffIndicators = DiffIndicators(rawValue: value) ?? .bars }
        if let value = o.overflow { options.code.overflow = Overflow(rawValue: value) ?? .scroll }
        if let value = o.expansionLineCount { options.expansionLineCount = value }
        if let value = o.disableLineNumbers { options.code.disableLineNumbers = value }
        if let value = o.disableBackground { options.disableBackground = value }
        if let value = o.disableFileHeader { options.code.disableFileHeader = value }
        if let value = o.lineDiffType { options.lineDiffType = LineDiffType(rawValue: value) ?? .wordAlt }
        if let value = o.expandUnchanged { options.expandUnchanged = value }
        if let value = o.theme { options.code.theme = value.selection }
    }

    let view: NSView
    let preferredHeight: (CGFloat) -> CGFloat
    if testCase.kind == "edit", let file = testCase.file {
        let documentView: DiffsDocumentView
        let getText: () -> String
        let getSelections: () -> [EditorSelection]
        var keepAlive: AnyObject?
        if let oldFile = testCase.oldFile {
            let diffView = FileDiffView<Void>(options: options)
            diffView.appearance = appearance
            diffView.synchronousHighlightLineLimit = .max
            try diffView.render(oldFile: oldFile, newFile: file)
            documentView = diffView
            diffView.frame = CGRect(x: 0, y: 0, width: width, height: diffView.preferredHeight(forWidth: width))
            let editor = DiffsEditor<DiffLineAnnotation<Void>>()
            _ = editor.edit(diffView)
            keepAlive = editor
            getText = { editor.getText() }
            getSelections = { editor.selections }
        } else {
            let fileView = FileView<Void>(options: options.code)
            fileView.appearance = appearance
            fileView.synchronousHighlightLineLimit = .max
            fileView.render(file: file)
            documentView = fileView
            fileView.frame = CGRect(x: 0, y: 0, width: width, height: fileView.preferredHeight(forWidth: width))
            let editor = DiffsEditor<LineAnnotation<Void>>()
            _ = editor.edit(fileView)
            keepAlive = editor
            getText = { editor.getText() }
            getSelections = { editor.selections }
        }
        _ = keepAlive
        let window = NSWindow(contentRect: documentView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = documentView
        guard let grid = documentView.subviews.first(where: { $0 is NSTextInputClient }) else { fatalError("no grid") }
        window.makeFirstResponder(grid)
        documentView.layoutSubtreeIfNeeded()
        for action in testCase.editActions ?? [] {
            switch action.type {
            case "text":
                (grid as? NSTextInputClient)?.insertText(action.text ?? "", replacementRange: NSRange(location: NSNotFound, length: 0))
            case "key":
                var flags: NSEvent.ModifierFlags = []
                for mod in action.mods ?? [] {
                    switch mod {
                    case "shift": flags.insert(.shift)
                    case "cmd": flags.insert(.command)
                    case "alt": flags.insert(.option)
                    case "ctrl": flags.insert(.control)
                    default: break
                    }
                }
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: action.chars ?? "", charactersIgnoringModifiers: action.chars ?? "", isARepeat: false, keyCode: action.keyCode ?? 0
                )!
                if !grid.performKeyEquivalent(with: event) { grid.keyDown(with: event) }
            case "click":
                let location = grid.convert(CGPoint(x: action.x ?? 0, y: action.y ?? 0), from: documentView)
                let windowPoint = grid.convert(location, to: nil)
                let event = NSEvent.mouseEvent(
                    with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: action.clickCount ?? 1, pressure: 1
                )!
                grid.mouseDown(with: event)
                grid.mouseUp(with: event)
            default:
                break
            }
            documentView.frame.size.height = documentView.preferredHeight(forWidth: width)
            window.setContentSize(documentView.frame.size)
            documentView.layoutSubtreeIfNeeded()
        }
        print("text: \(getText().debugDescription)")
        print("selections: \(getSelections().map { "\($0.start.line):\($0.start.character)-\($0.end.line):\($0.end.character)" })")
        view = documentView
        preferredHeight = documentView.preferredHeight(forWidth:)
    } else if testCase.kind == "stream", let file = testCase.file {
        let streamView = FileStreamView(options: FileStreamOptions(code: options.code, lang: testCase.lang))
        streamView.appearance = appearance
        var closed = false
        streamView.onStreamClose = { closed = true }
        streamView.begin()
        var chunk = ""
        for character in file.contents {
            chunk.append(character)
            if chunk.utf16.count >= 7 {
                streamView.write(chunk)
                chunk = ""
            }
        }
        if !chunk.isEmpty { streamView.write(chunk) }
        streamView.close()
        let deadline = Date().addingTimeInterval(20)
        while !closed, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        view = streamView
        preferredHeight = streamView.preferredHeight(forWidth:)
    } else if testCase.kind == "unresolved", let file = testCase.file {
        let unresolvedView = UnresolvedFileView<Void>(options: options)
        unresolvedView.appearance = appearance
        unresolvedView.diffView.synchronousHighlightLineLimit = .max
        try unresolvedView.render(file: file)
        view = unresolvedView
        preferredHeight = unresolvedView.preferredHeight(forWidth:)
    } else if testCase.kind == "file", let file = testCase.file {
        let fileView = FileView<Void>(options: options.code)
        fileView.appearance = appearance
        fileView.renderAnnotation = { annotation in
            let label = NSTextField(labelWithString: "Annotation on \(annotation.lineNumber)")
            label.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            return padded(label)
        }
        fileView.render(file: file, lineAnnotations: (testCase.annotations ?? []).map { LineAnnotation(lineNumber: $0.lineNumber) })
        if let selected = testCase.selectedLines { fileView.setSelectedLines(selected) }
        view = fileView
        preferredHeight = fileView.preferredHeight(forWidth:)
    } else {
        let diffView = FileDiffView<Void>(options: options)
        diffView.appearance = appearance
        diffView.synchronousHighlightLineLimit = .max
        diffView.renderAnnotation = { annotation in
            let label = NSTextField(labelWithString: "Annotation on \(annotation.side.rawValue) \(annotation.lineNumber)")
            label.font = NSFont(name: "SFMono-Regular", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            return padded(label)
        }
        let annotations = (testCase.annotations ?? []).map {
            DiffLineAnnotation(side: AnnotationSide(rawValue: $0.side ?? "additions") ?? .additions, lineNumber: $0.lineNumber)
        }
        try diffView.render(oldFile: testCase.oldFile, newFile: testCase.newFile, lineAnnotations: annotations)
        if let selected = testCase.selectedLines { diffView.setSelectedLines(selected) }
        view = diffView
        preferredHeight = diffView.preferredHeight(forWidth:)
    }
    view.frame = CGRect(x: 0, y: 0, width: width, height: 100)
    view.frame = CGRect(x: 0, y: 0, width: width, height: preferredHeight(width))
    view.layoutSubtreeIfNeeded()

    if let clicks = testCase.clicks, !clicks.isEmpty {
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        for click in clicks {
            let height = view.frame.height
            let location = CGPoint(x: click[0], y: height - click[1])
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                )!
                // `sendEvent` does not dispatch to offscreen windows.
                guard let target = window.contentView?.hitTest(location) else { continue }
                if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
            }
            let newHeight = preferredHeight(width)
            view.frame = CGRect(x: 0, y: 0, width: width, height: newHeight)
            window.setContentSize(view.frame.size)
            view.layoutSubtreeIfNeeded()
        }
        view.removeFromSuperview()
        view.frame = CGRect(x: 0, y: 0, width: width, height: preferredHeight(width))
        view.layoutSubtreeIfNeeded()
    }

    if let drags = testCase.drags, !drags.isEmpty {
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        let height = view.frame.height
        for drag in drags {
            let from = CGPoint(x: drag[0], y: height - drag[1])
            let to = CGPoint(x: drag[2], y: height - drag[3])
            let clickCount = drag.count > 4 ? Int(drag[4]) : 1
            guard let target = window.contentView?.hitTest(from) else { continue }
            func event(_ type: NSEvent.EventType, _ location: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
                )!
            }
            target.mouseDown(with: event(.leftMouseDown, from))
            if from != to { target.mouseDragged(with: event(.leftMouseDragged, to)) }
            target.mouseUp(with: event(.leftMouseUp, to))
        }
        if let document = view as? DiffsDocumentView {
            print("selection: \((document.selectedText ?? "<none>").debugDescription)")
        }
        view.removeFromSuperview()
        view.frame = CGRect(x: 0, y: 0, width: width, height: preferredHeight(width))
        view.layoutSubtreeIfNeeded()
    }

    let height = view.frame.height
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * scale),
        pixelsHigh: Int(height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = CGSize(width: width, height: height)
    appearance.performAsCurrentDrawingAppearance {
        view.cacheDisplay(in: view.bounds, to: rep)
    }
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
    print("\(arguments[2]) \(Int(width))x\(Int(height))")
}

@MainActor
func padded(_ view: NSView) -> NSView {
    let container = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
        view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
        view.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
        view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
    ])
    return container
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    do {
        try run()
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
