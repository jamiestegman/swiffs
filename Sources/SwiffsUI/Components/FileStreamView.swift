// Port of the `FileStream` component: renders code as it streams in,
// highlighting complete lines and re-highlighting the trailing partial line
// as more text arrives.

import AppKit
import SwiffsCore
import SwiffsHighlight

/// Options for `FileStreamView` (`FileStreamOptions`).
public struct FileStreamOptions: Equatable {
    /// Theme, typography, overflow and line number options. The file header,
    /// backgrounds and change indicators are never shown.
    public var code = DiffsCodeOptions()
    /// Language of the streamed code; plain text when nil.
    public var lang: String?
    /// Line number of the first streamed line.
    public var startingLineIndex = 1

    public init(code: DiffsCodeOptions = DiffsCodeOptions(), lang: String? = nil, startingLineIndex: Int = 1) {
        self.code = code
        self.lang = lang
        self.startingLineIndex = startingLineIndex
    }
}

public final class FileStreamView: DiffsDocumentView {
    public private(set) var options: FileStreamOptions

    public var onPreRender: ((FileStreamView) -> Void)?
    public var onPostRender: ((FileStreamView) -> Void)?
    public var onStreamStart: (() -> Void)?
    public var onStreamWrite: ((StreamEvent) -> Void)?
    public var onStreamClose: (() -> Void)?
    public var onStreamAbort: ((Error?) -> Void)?

    /// Rendered lines. Each starts on a `"\\n"` token boundary; like upstream,
    /// a trailing line break leaves an empty last line.
    private var lines: [HighlightedLine] = []
    /// Tokens of the line currently receiving content.
    private var currentTokens: [StreamToken] = []
    private var queuedEvents: [StreamEvent] = []
    private var renderScheduled = false
    private var session = 0
    private var consumer: Task<Void, Never>?
    private var writeChain: Task<Void, Never>?
    private var tokenizer: StreamTokenizer?

    /// Tokenization runs off the main thread on one shared highlighter.
    private static let queue = DispatchQueue(label: "swiffs.file-stream", qos: .userInitiated)
    nonisolated(unsafe) private static let highlighter = DiffsHighlighter()

    public init(options: FileStreamOptions = FileStreamOptions()) {
        self.options = options
        super.init(frame: .zero)
        applyCodeOptions()
    }

    public override init(frame frameRect: NSRect) {
        options = FileStreamOptions()
        super.init(frame: frameRect)
        applyCodeOptions()
    }

    /// Switches between light, dark and system themes (`setThemeType`).
    public func setThemeType(_ themeType: ThemeType) {
        guard options.code.themeType != themeType else { return }
        var next = options
        next.code.themeType = themeType
        setOptions(next)
    }

    public func setOptions(_ options: FileStreamOptions) {
        let restream = options.lang != self.options.lang || options.code.theme != self.options.code.theme
        self.options = options
        applyCodeOptions()
        if restream, tokenizer != nil {
            // Upstream sets options up front; changing the grammar mid-stream
            // only affects later chunks.
            makeTokenizer()
        }
    }

    private func applyCodeOptions() {
        var code = options.code
        code.disableFileHeader = true
        codeOptions = code
        if !refreshStyleIfNeeded() {
            rebuildGrid()
        }
    }

    /// Number of rendered lines.
    public var lineCount: Int { lines.count }

    /// The text rendered so far.
    public var text: String {
        lines.map(\.text).joined(separator: "\n")
    }

    // MARK: - Streaming

    /// Starts rendering a stream of text chunks, replacing any previous
    /// stream (`setup(source, wrapper)`).
    public func setup<S: AsyncSequence & Sendable>(_ source: S) where S.Element == String {
        begin()
        let session = self.session
        consumer = Task { [weak self] in
            do {
                for try await chunk in source {
                    if Task.isCancelled { break }
                    await self?.enqueue(chunk, session: session)
                }
                if Task.isCancelled {
                    await self?.abort(nil, session: session)
                } else {
                    await self?.finish(session: session)
                }
            } catch {
                await self?.abort(error, session: session)
            }
        }
    }

    /// Starts a stream fed by `write(_:)` and `close()`.
    public func begin() {
        cancelConsumer()
        session += 1
        lines = []
        currentTokens = []
        queuedEvents = []
        makeTokenizer()
        rebuildGrid()
        onStreamStart?()
    }

    /// Writes a chunk to a stream started with `begin()`.
    public func write(_ chunk: String) {
        let session = self.session
        chain { await $0.enqueue(chunk, session: session) }
    }

    /// Closes a stream started with `begin()`.
    public func close() {
        let session = self.session
        chain { await $0.finish(session: session) }
    }

    /// Runs writes in order: each waits for the previous one.
    private func chain(_ work: @escaping @MainActor (FileStreamView) async -> Void) {
        let previous = writeChain
        writeChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
    }

    /// Stops the current stream (`cleanUp`).
    public func cleanUp() {
        cancelConsumer()
        session += 1
        tokenizer = nil
    }

    private func cancelConsumer() {
        consumer?.cancel()
        consumer = nil
        writeChain = nil
    }

    private func makeTokenizer() {
        let lang = options.lang ?? "text"
        let themes = ThemeSlots(options.code.theme)
        let maxLineLength = options.code.tokenizeMaxLineLength
        let highlighter = Self.highlighter
        tokenizer = Self.queue.sync {
            try? highlighter.prepare(langs: [lang], themes: themes.themeNames)
            return StreamTokenizer(highlighter: highlighter, lang: lang, themes: themes, tokenizeMaxLineLength: maxLineLength)
        }
    }

    /// Tokenizes on the shared queue, then applies the events here. Chunks of
    /// one session are serialized because each call awaits the previous.
    private func enqueue(_ chunk: String, session: Int) async {
        guard session == self.session, let tokenizer else { return }
        let events: [StreamEvent] = await withCheckedContinuation { continuation in
            nonisolated(unsafe) let tokenizer = tokenizer
            Self.queue.async {
                let events = (try? tokenizer.transform(chunk)) ?? []
                continuation.resume(returning: events)
            }
        }
        guard session == self.session else { return }
        for event in events {
            handleWrite(event)
        }
    }

    private func finish(session: Int) async {
        guard session == self.session, let tokenizer else { return }
        // With recalls enabled the final tokens were already emitted.
        await withCheckedContinuation { continuation in
            nonisolated(unsafe) let tokenizer = tokenizer
            Self.queue.async {
                _ = tokenizer.close()
                continuation.resume()
            }
        }
        guard session == self.session else { return }
        flushRender()
        onStreamClose?()
    }

    private func abort(_ error: Error?, session: Int) async {
        guard session == self.session else { return }
        onStreamAbort?(error)
    }

    // MARK: - Rendering

    private func handleWrite(_ event: StreamEvent) {
        // Recalls of tokens not rendered yet drop them from the queue.
        if case .recall(let count) = event, queuedEvents.count >= count {
            queuedEvents.removeLast(count)
        } else {
            queuedEvents.append(event)
        }
        scheduleRender()
        onStreamWrite?(event)
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.flushRender()
            }
        }
    }

    private func flushRender() {
        renderScheduled = false
        guard !queuedEvents.isEmpty else { return }
        onPreRender?(self)
        let previousCount = lines.count
        var touched = Set<Int>()
        for event in queuedEvents {
            switch event {
            case .recall(let count):
                currentTokens.removeLast(min(count, currentTokens.count))
            case .token(let token):
                if lines.isEmpty {
                    lines.append(HighlightedLine(text: "", tokens: []))
                }
                if token.isLineBreak {
                    lines[lines.count - 1] = makeLine(currentTokens)
                    touched.insert(lines.count - 1)
                    currentTokens = []
                    lines.append(HighlightedLine(text: "", tokens: []))
                    continue
                }
                currentTokens.append(token)
            }
            if !lines.isEmpty {
                lines[lines.count - 1] = makeLine(currentTokens)
                touched.insert(lines.count - 1)
            }
        }
        queuedEvents.removeAll()
        grid.invalidateLines(side: .additions, lineIndexes: touched.filter { $0 < previousCount })
        rebuildGrid()
        onPostRender?(self)
    }

    private func makeLine(_ tokens: [StreamToken]) -> HighlightedLine {
        var text = ""
        var highlighted: [HighlightedToken] = []
        var offset = 0
        for token in tokens {
            let length = token.content.utf16.count
            text += token.content
            if length > 0 {
                highlighted.append(HighlightedToken(start: offset, end: offset + length, styles: token.styles))
            }
            offset += length
        }
        return HighlightedLine(text: text, tokens: highlighted)
    }

    private func rebuildGrid() {
        let rows = buildFileRows(lineCount: lines.count).rows.map { row -> RenderRow in
            guard case .line(var line)? = row.cells.first ?? nil else { return row }
            line.lineNumber = line.lineIndex + options.startingLineIndex
            return RenderRow(cells: [.line(line)])
        }
        let model = GridModel(
            kind: .file,
            rows: rows,
            isSplit: false,
            columnCount: 1,
            hasDeletionsColumn: false,
            hasAdditionsColumn: false,
            totalLines: lines.count + options.startingLineIndex - 1
        )
        let gridOptions = GridOptions(
            overflow: options.code.overflow,
            diffIndicators: .none,
            disableBackground: true,
            disableLineNumbers: options.code.disableLineNumbers,
            hunkSeparators: .lineInfo,
            lineHoverHighlight: .disabled,
            enableGutterUtility: false,
            enableLineSelection: false,
            enableTokenInteractionsOnWhitespace: false,
            hasHeader: false
        )
        grid.update(model: model, options: gridOptions, style: style)
        gridContentChanged()
    }

    override func styleDidChange() {
        grid.invalidateLines()
        rebuildGrid()
    }

    override func line(side: AnnotationSide, lineIndex: Int) -> HighlightedLine {
        lineIndex < lines.count ? lines[lineIndex] : HighlightedLine(text: "", tokens: [])
    }
}
