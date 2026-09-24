// Port of `editor/tokenizer.ts`: incremental single-theme tokenization for
// the editor. Grammar states are cached per line; after an edit only the
// changed lines are re-tokenized until the state reconverges, and the rest
// continues in small background chunks.

import Foundation
import SwiffsCore
import SwiffsHighlight

private let tokenizeTimeLimit: Double = 500

/// Editor colors from the active theme (the CSS variables upstream sets on
/// the editor host).
public struct EditorThemeColors: Hashable, Sendable {
    public var selectionBackground: String?
    /// Nil when the theme has no usable line highlight background.
    public var lineHighlightBackground: String?
    /// `editor.lineHighlightBorder`, or nil for the default mix
    /// (`color-mix(in lab, bg 70%, fg)`) when there is no line highlight
    /// background.
    public var lineHighlightBorder: String?
    public var hasLineHighlightBorder: Bool
    /// `--diffs-editor-active-line-source-mix` in percent.
    public var activeLineSourceMix: Double
    public var cursorForeground: String?
    public var findMatchBackground: String?
    public var findMatchHighlightBackground: String?
    public var bracketMatchBackground: String?
    public var bracketMatchBorder: String?
    public var hintForeground: String?
    public var infoForeground: String?
    public var warningForeground: String?
    public var errorForeground: String?

    public init(theme: ThemeRegistration) {
        let colors = theme.colors
        selectionBackground = colors["editor.selectionBackground"]
        let highlight = colors["editor.lineHighlightBackground"]
        let usable = highlight.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            if let color = RGBAColor(css: trimmed), color.a == 0 { return nil }
            return value
        }
        lineHighlightBackground = usable
        if let border = colors["editor.lineHighlightBorder"] {
            lineHighlightBorder = border
            hasLineHighlightBorder = true
        } else {
            lineHighlightBorder = nil
            // Transparent when the background carries the highlight.
            hasLineHighlightBorder = usable == nil
        }
        activeLineSourceMix = usable == nil ? 100 : 85
        cursorForeground = colors["editorCursor.foreground"]
        findMatchBackground = colors["editor.findMatchBackground"]
        findMatchHighlightBackground = colors["editor.findMatchHighlightBackground"]
        bracketMatchBackground = colors["editorBracketMatch.background"]
        bracketMatchBorder = colors["editorBracketMatch.border"]
        hintForeground = colors["editorHint.foreground"]
        infoForeground = colors["editorInfo.foreground"]
        warningForeground = colors["editorWarning.foreground"]
        errorForeground = colors["editorError.foreground"]
    }
}

private enum BracketRangesCache {
    case none
    case ranges([(start: Int, end: Int)])
}

/// `EditorTokenizer`. Not thread safe; use from one thread (the main thread
/// in the editor view).
public final class EditorTokenizer<Annotation> {
    public let highlighter: DiffsHighlighter
    public let document: TextDocument<Annotation>
    public let tokenizeMaxLineLength: Int
    public let matchBrackets: Bool
    public private(set) var themeType: ThemeKind = .dark
    public private(set) var themeName = ""
    public private(set) var themeColors: EditorThemeColors?

    /// Lines re-tokenized outside `tokenize` (offscreen and background).
    public var onDeferTokenize: (([Int: [EditorLineToken]], ThemeKind) -> Void)?
    /// Called after the theme changed.
    public var onThemeChange: (() -> Void)?
    /// Runs background work later (upstream: `postMessage`).
    public var scheduler: (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) }

    private var grammar: Grammar?
    private var colorMap: [String] = []
    private var stateStack: [StateStack?] = [.initial]
    private var comparisonStateStack: [StateStack?] = []
    private var comparisonStateStackStart = 0
    private var comparisonLineChanges: [TextDocumentChange.LineChange] = []
    private var lastLine = -1
    private var isStopped = true
    private var isPaused = false
    private var backgroundJobID = 0
    private var backgroundPrebuildEndLine = -1
    private var pendingPrebuildEndLine = -1
    private var backgroundChangedLineRanges: [ClosedRange<Int>]?
    private var backgroundChangedRangeIndex = 0
    private var bracketIgnoredRanges: [BracketRangesCache?] = []
    private var isCleanedUp = false

    public init(
        highlighter: DiffsHighlighter,
        document: TextDocument<Annotation>,
        themeName: String,
        themeType: ThemeKind? = nil,
        tokenizeMaxLineLength: Int = 1000,
        matchBrackets: Bool = true
    ) {
        self.highlighter = highlighter
        self.document = document
        self.tokenizeMaxLineLength = tokenizeMaxLineLength
        self.matchBrackets = matchBrackets
        ensureGrammar()
        setTheme(themeName, themeType)
    }

    private var isGrammarless: Bool {
        document.languageId == "text" || document.languageId == "ansi"
    }

    // MARK: Theme

    private func setTheme(_ name: String, _ type: ThemeKind?) {
        guard let (theme, colorMap) = try? highlighter.activateTheme(name) else { return }
        themeColors = EditorThemeColors(theme: theme)
        themeName = name
        themeType = type ?? theme.type
        self.colorMap = colorMap
    }

    /// Switches the rendered theme and re-tokenizes (`emitThemeChange`).
    public func changeTheme(_ name: String, themeType type: ThemeKind) {
        if name == themeName, type == themeType { return }
        setTheme(name, type)
        stopBackgroundTokenize()
        stateStack = [.initial]
        comparisonStateStack = []
        comparisonStateStackStart = 0
        comparisonLineChanges = []
        if grammar != nil, document.lineCount > 0 {
            scheduleBackgroundTokenize(0)
        }
        onThemeChange?()
    }

    /// Re-activates the theme's color map on the shared highlighter
    /// (`ensureActiveTheme`).
    private func ensureActiveTheme() {
        if themeName.isEmpty { return }
        if let (_, colorMap) = try? highlighter.activateTheme(themeName) {
            self.colorMap = colorMap
        }
    }

    public func cleanUp() {
        isCleanedUp = true
        stopBackgroundTokenize()
    }

    private func ensureGrammar() {
        if grammar == nil, !isGrammarless {
            grammar = highlighter.grammar(for: document.languageId)
        }
    }

    // MARK: Bracket support

    /// String/comment/regexp ranges of a line, tokenizing it if needed
    /// (`getStringCommentRegexpRangesInLine`).
    public func getStringCommentRegexpRangesInLine(_ line: Int) -> [(start: Int, end: Int)]? {
        if !matchBrackets || line < 0 || line >= document.lineCount { return nil }
        ensureGrammar()
        guard grammar != nil else { return nil }
        if line >= bracketIgnoredRanges.count || bracketIgnoredRanges[line] == nil {
            _ = buildStateStack(line)
            let state = stateAt(line) ?? .initial
            let result = tokenizeLineAt(line, state)
            setState(line + 1, result.state)
        }
        guard line < bracketIgnoredRanges.count, case .ranges(let ranges)? = bracketIgnoredRanges[line] else { return nil }
        return ranges
    }

    // MARK: Tokenizing

    private func stateAt(_ index: Int) -> StateStack? {
        index >= 0 && index < stateStack.count ? stateStack[index] : nil
    }

    private func setState(_ index: Int, _ state: StateStack) {
        if index >= stateStack.count {
            stateStack.append(contentsOf: [StateStack?](repeating: nil, count: index - stateStack.count + 1))
        }
        stateStack[index] = state
    }

    private func truncateBracketCache(_ length: Int) {
        if bracketIgnoredRanges.count > length {
            bracketIgnoredRanges.removeLast(bracketIgnoredRanges.count - max(0, length))
        }
    }

    /// Re-tokenizes the lines a change touched within the render range and
    /// returns them; the remainder continues in the background.
    public func tokenize(_ change: TextDocumentChange, renderRange: RenderRange? = nil, hostRealignsRows: Bool = false) throws -> [Int: [EditorLineToken]] {
        ensureGrammar()
        ensureActiveTheme()
        if grammar == nil, !isGrammarless {
            throw DiffsError("Grammar for language \"\(document.languageId)\" not loaded")
        }
        let lineCount = document.lineCount
        let startingLine = renderRange?.startingLine ?? 0
        let totalLines = renderRange?.totalLines ?? .max
        let renderRangeEndLine = totalLines == .max ? lineCount : min(startingLine + totalLines, lineCount)
        let dirtyStart = change.startLine
        let viewStart = max(startingLine, dirtyStart)
        let crossesRenderRangeEnd = renderRange != nil && totalLines != .max && change.lineDelta > 0 && dirtyStart < renderRangeEndLine && change.endLine >= renderRangeEndLine
        let canReuseCachedStates = change.lineDelta == 0 && change.changedLineChanges.allSatisfy { $0.lineDelta == 0 }
        if matchBrackets, !canReuseCachedStates {
            truncateBracketCache(change.startLine)
        }
        let canReuseShiftedStates = hostRealignsRows && change.lineDelta != 0 && dirtyStart >= startingLine
        let canCacheTokenizedStates = canReuseCachedStates || renderRange == nil || dirtyStart >= viewStart
        let changedLineRanges = change.changedLineRanges.isEmpty ? [dirtyStart ... change.endLine] : change.changedLineRanges
        comparisonStateStack = []
        comparisonStateStackStart = 0
        comparisonLineChanges = []
        var offscreenSyncEnd = -1
        if dirtyStart < viewStart {
            for range in changedLineRanges where range.lowerBound < viewStart {
                offscreenSyncEnd = max(offscreenSyncEnd, min(range.upperBound, viewStart - 1))
            }
        }
        let shouldFlushOffscreen = offscreenSyncEnd >= dirtyStart && (canReuseCachedStates || change.lineDelta < 0)
        if canReuseCachedStates {
            _ = buildStateStack(dirtyStart)
        } else {
            shiftComparisonStateStack(change)
            if renderRange == nil || dirtyStart >= viewStart {
                _ = buildStateStack(viewStart)
            }
        }

        var changedRangeIndex = 0
        var currentChangedRangeEnd = changedLineRanges[0].upperBound
        var backgroundStartLine: Int?
        var backgroundChangedRangeIndex = 0
        var line = canReuseCachedStates ? changedLineRanges[0].lowerBound : viewStart
        var settled = false
        var dirtyLines: [Int: [EditorLineToken]] = [:]
        var offscreenDirtyLines: [Int: [EditorLineToken]]? = shouldFlushOffscreen ? [:] : nil
        if offscreenDirtyLines != nil, !canReuseCachedStates {
            let offscreenEnd = min(offscreenSyncEnd + 1, viewStart, renderRangeEndLine)
            if offscreenEnd > dirtyStart {
                _ = buildStateStack(offscreenEnd)
                var offscreenState = stateAt(dirtyStart) ?? .initial
                for offscreenLine in dirtyStart ..< offscreenEnd {
                    let resolved = tokenizeLineAt(offscreenLine, offscreenState)
                    offscreenState = resolved.state
                    offscreenDirtyLines?[offscreenLine] = resolved.tokens
                }
                setState(offscreenEnd, offscreenState)
            }
        }
        // Seed after the offscreen flush so a delete reaching the viewport
        // reads the rebuilt state.
        var state = stateAt(line) ?? .initial
        while line < renderRangeEndLine {
            let previousNextState: StateStack? = canReuseCachedStates
                ? stateAt(line + 1)
                : canReuseShiftedStates ? getPreviousEndState(line + 1) : nil
            if canCacheTokenizedStates { setState(line, state) }
            let resolved = tokenizeLineAt(line, state)
            state = resolved.state
            if line >= viewStart {
                dirtyLines[line] = resolved.tokens
            } else {
                offscreenDirtyLines?[line] = resolved.tokens
            }
            if canCacheTokenizedStates { setState(line + 1, state) }
            settled = line >= currentChangedRangeEnd
                && (canReuseCachedStates || canReuseShiftedStates)
                && previousNextState != nil
                && state.equals(previousNextState)
            if settled {
                changedRangeIndex += 1
                guard changedRangeIndex < changedLineRanges.count else { break }
                let nextRange = changedLineRanges[changedRangeIndex]
                if nextRange.lowerBound >= renderRangeEndLine {
                    backgroundStartLine = nextRange.lowerBound
                    backgroundChangedRangeIndex = changedRangeIndex
                    break
                }
                var nextState = stateAt(nextRange.lowerBound)
                if canReuseShiftedStates {
                    var stateLine = line + 2
                    while stateLine <= nextRange.lowerBound {
                        nextState = getPreviousEndState(stateLine)
                        guard let found = nextState else { break }
                        setState(stateLine, found)
                        stateLine += 1
                    }
                }
                if let nextState {
                    line = nextRange.lowerBound
                    state = nextState
                } else {
                    line += 1
                }
                currentChangedRangeEnd = nextRange.upperBound
                settled = false
                continue
            }
            line += 1
        }

        if canCacheTokenizedStates {
            setState(line < renderRangeEndLine ? line + 1 : line, state)
        }
        if settled, canReuseShiftedStates, backgroundStartLine == nil {
            var stateLine = line + 2
            while stateLine <= lineCount, let previous = getPreviousEndState(stateLine) {
                setState(stateLine, previous)
                stateLine += 1
            }
            comparisonStateStack = []
            comparisonStateStackStart = 0
            comparisonLineChanges = []
        }
        if let offscreenDirtyLines, !offscreenDirtyLines.isEmpty {
            onDeferTokenize?(offscreenDirtyLines, themeType)
        }
        if let backgroundStartLine {
            if matchBrackets, canReuseCachedStates { truncateBracketCache(backgroundStartLine) }
            scheduleBackgroundTokenize(backgroundStartLine, changedLineRanges, backgroundChangedRangeIndex)
        } else if !settled, line < lineCount {
            let backgroundLine = crossesRenderRangeEnd && dirtyStart >= viewStart
                ? renderRangeEndLine
                : (dirtyStart < viewStart && !canReuseCachedStates ? dirtyStart : line)
            if matchBrackets, canReuseCachedStates { truncateBracketCache(backgroundLine) }
            scheduleBackgroundTokenize(backgroundLine, changedLineRanges, changedRangeIndex)
        }
        return dirtyLines
    }

    /// Tokenizes lines `[start, end)` from cached states, for initial render.
    public func tokenizeLines(_ range: Range<Int>) -> [Int: [EditorLineToken]] {
        ensureGrammar()
        ensureActiveTheme()
        _ = buildStateStack(range.lowerBound)
        var state = stateAt(range.lowerBound) ?? .initial
        var lines: [Int: [EditorLineToken]] = [:]
        for line in range where line < document.lineCount {
            setState(line, state)
            let resolved = tokenizeLineAt(line, state)
            lines[line] = resolved.tokens
            state = resolved.state
            setState(line + 1, state)
        }
        return lines
    }

    /// Builds cached states up to the end of a render range in the
    /// background (`prebuildStateStack`).
    public func prebuildStateStack(renderRange: RenderRange? = nil) {
        ensureGrammar()
        guard !isCleanedUp else { return }
        let startingLine = renderRange?.startingLine ?? 0
        let totalLines = renderRange?.totalLines ?? .max
        let endLine = min(totalLines == .max ? Int.max : startingLine + totalLines, document.lineCount)
        ensureActiveTheme()
        scheduleStatePrebuild(endLine)
    }

    public func stopBackgroundTokenize() {
        pendingPrebuildEndLine = -1
        if isStopped { return }
        isStopped = true
        isPaused = false
        lastLine = -1
        backgroundPrebuildEndLine = -1
        backgroundChangedLineRanges = nil
        backgroundChangedRangeIndex = 0
        comparisonStateStack = []
        comparisonStateStackStart = 0
        comparisonLineChanges = []
    }

    public func pauseBackgroundTokenize() {
        if isStopped || isPaused { return }
        isPaused = true
    }

    public func resumeBackgroundTokenize() {
        if isStopped || !isPaused || grammar == nil || lastLine < 0 { return }
        isPaused = false
        post(backgroundJobID)
    }

    private func post(_ jobID: Int) {
        scheduler { [weak self] in
            guard let self, jobID == self.backgroundJobID else { return }
            if self.backgroundPrebuildEndLine >= 0 {
                self.backgroundPrebuild(jobID)
            } else {
                self.backgroundTokenize(jobID)
            }
        }
    }

    private func scheduleBackgroundTokenize(_ startLine: Int, _ changedLineRanges: [ClosedRange<Int>]? = nil, _ changedRangeIndex: Int = 0) {
        if isGrammarless { return }
        backgroundJobID += 1
        let jobID = backgroundJobID
        isStopped = false
        isPaused = false
        lastLine = startLine
        if backgroundPrebuildEndLine >= 0 {
            pendingPrebuildEndLine = max(pendingPrebuildEndLine, backgroundPrebuildEndLine)
        }
        backgroundPrebuildEndLine = -1
        backgroundChangedLineRanges = changedLineRanges
        backgroundChangedRangeIndex = changedRangeIndex
        post(jobID)
    }

    private func scheduleStatePrebuild(_ endLine: Int) {
        if grammar == nil || stateStack.count > endLine { return }
        if !isStopped {
            if backgroundPrebuildEndLine >= 0 {
                backgroundPrebuildEndLine = max(backgroundPrebuildEndLine, endLine)
            } else {
                pendingPrebuildEndLine = max(pendingPrebuildEndLine, endLine)
            }
            return
        }
        backgroundJobID += 1
        let jobID = backgroundJobID
        isStopped = false
        isPaused = false
        lastLine = stateStack.count - 1
        backgroundPrebuildEndLine = endLine
        pendingPrebuildEndLine = -1
        backgroundChangedLineRanges = nil
        backgroundChangedRangeIndex = 0
        post(jobID)
    }

    private func isBlank(_ units: [UInt16]) -> Bool {
        jsTrimmed(units).isEmpty
    }

    private func tokenizeLineAt(_ line: Int, _ state: StateStack) -> (tokens: [EditorLineToken], state: StateStack) {
        let units = document.getLineUnits(line)
        let lineText = UTF16Text.string(units)
        if units.count > tokenizeMaxLineLength {
            cacheBracketIgnoredRanges(line, nil)
            return ([EditorLineToken(offset: 0, color: "", text: lineText)], state)
        }
        guard let grammar, !units.isEmpty, !isBlank(units) else {
            cacheBracketIgnoredRanges(line, nil)
            return ([EditorLineToken(offset: 0, color: "", text: lineText)], state)
        }
        let result = tokenizeEditorLine(grammar: grammar, colorMap: colorMap, lineText: lineText, state: state, timeLimit: tokenizeTimeLimit, collectBracketIgnoredRanges: matchBrackets)
        cacheBracketIgnoredRanges(line, result.bracketIgnoredRanges)
        return (result.tokens, result.ruleStack)
    }

    private func cacheBracketIgnoredRanges(_ line: Int, _ ranges: [(start: Int, end: Int)]?) {
        guard matchBrackets else { return }
        if line >= bracketIgnoredRanges.count {
            bracketIgnoredRanges.append(contentsOf: [BracketRangesCache?](repeating: nil, count: line - bracketIgnoredRanges.count + 1))
        }
        bracketIgnoredRanges[line] = ranges.map { .ranges($0) } ?? BracketRangesCache.none
    }

    /// Keeps old end states as comparison-only sentinels
    /// (`shiftComparisonStateStack`).
    private func shiftComparisonStateStack(_ change: TextDocumentChange) {
        let lineChanges = change.changedLineChanges.isEmpty
            ? [TextDocumentChange.LineChange(startLine: change.startLine, endLine: change.endLine, lineDelta: change.lineDelta, startCharacter: 0, endCharacter: 0, endedAtDocumentEnd: false)]
            : change.changedLineChanges
        let comparisonStart = change.startLine + 1
        let comparisonLength = stateStack.count - comparisonStart
        if comparisonStart <= comparisonLength {
            comparisonStateStack = stateStack
            comparisonStateStackStart = 0
            stateStack = Array(stateStack.prefix(comparisonStart))
        } else {
            comparisonStateStackStart = comparisonStart
            comparisonStateStack = comparisonStart < stateStack.count ? Array(stateStack[comparisonStart...]) : []
            stateStack = Array(stateStack.prefix(min(stateStack.count, comparisonStart)))
        }
        comparisonLineChanges = lineChanges
    }

    private func getPreviousEndState(_ line: Int) -> StateStack? {
        var previousLine = line
        for change in comparisonLineChanges.reversed() where change.lineDelta != 0 {
            if previousLine > change.endLine {
                previousLine -= change.lineDelta
            } else if previousLine > change.startLine {
                return stateAt(line)
            }
        }
        let index = previousLine - comparisonStateStackStart
        if index >= 0, index < comparisonStateStack.count, let state = comparisonStateStack[index] {
            return state
        }
        return stateAt(line)
    }

    /// Fills cached states up to `endAt`; false when the time budget ran out.
    private func buildStateStack(_ endAt: Int, timeBudget: Double? = nil) -> Bool {
        let bounded = min(max(0, endAt), document.lineCount)
        guard let grammar, stateStack.count <= bounded else { return true }
        let startedAt = Date()
        var line = stateStack.count - 1
        var state = stateAt(line) ?? .initial
        while line < bounded {
            setState(line, state)
            let units = document.getLineUnits(line)
            if units.count <= tokenizeMaxLineLength, !units.isEmpty, !isBlank(units) {
                let result = tokenizeEditorLine(grammar: grammar, colorMap: colorMap, lineText: UTF16Text.string(units), state: state, timeLimit: tokenizeTimeLimit, collectBracketIgnoredRanges: matchBrackets, resolveTokens: false)
                cacheBracketIgnoredRanges(line, result.bracketIgnoredRanges)
                state = result.ruleStack
            } else {
                cacheBracketIgnoredRanges(line, nil)
            }
            line += 1
            setState(line, state)
            if let timeBudget, Date().timeIntervalSince(startedAt) * 1000 > timeBudget { break }
        }
        return line >= bounded
    }

    private func backgroundPrebuild(_ jobID: Int) {
        guard !isStopped, !isPaused, grammar != nil, jobID == backgroundJobID else { return }
        ensureActiveTheme()
        let complete = buildStateStack(backgroundPrebuildEndLine, timeBudget: 1)
        if isStopped || isPaused || jobID != backgroundJobID { return }
        if complete {
            stopBackgroundTokenize()
            return
        }
        lastLine = stateStack.count - 1
        post(jobID)
    }

    private func backgroundTokenize(_ jobID: Int) {
        guard !isStopped, !isPaused, let grammar, jobID == backgroundJobID else { return }
        ensureActiveTheme()
        let startedAt = Date()
        var lines: [Int: [EditorLineToken]] = [:]
        let totalLines = document.lineCount
        let changedLineRanges = backgroundChangedLineRanges
        var line = lastLine
        var state = stateAt(line) ?? .initial
        var settled = false
        var changedRangeIndex = backgroundChangedRangeIndex
        var currentChangedRangeEnd = changedLineRanges.flatMap { changedRangeIndex < $0.count ? $0[changedRangeIndex].upperBound : nil }
        while line < totalLines {
            setState(line, state)
            let previousNextState = currentChangedRangeEnd != nil ? getPreviousEndState(line + 1) : nil
            let units = document.getLineUnits(line)
            let lineText = UTF16Text.string(units)
            if units.count > tokenizeMaxLineLength || units.isEmpty || isBlank(units) {
                lines[line] = [EditorLineToken(offset: 0, color: "", text: lineText)]
                cacheBracketIgnoredRanges(line, nil)
            } else {
                let result = tokenizeEditorLine(grammar: grammar, colorMap: colorMap, lineText: lineText, state: state, timeLimit: tokenizeTimeLimit, collectBracketIgnoredRanges: matchBrackets)
                lines[line] = result.tokens
                cacheBracketIgnoredRanges(line, result.bracketIgnoredRanges)
                state = result.ruleStack
            }
            setState(line + 1, state)
            settled = currentChangedRangeEnd.map { line >= $0 } == true && previousNextState != nil && state.equals(previousNextState)
            line += 1
            if settled {
                changedRangeIndex += 1
                guard let ranges = changedLineRanges, changedRangeIndex < ranges.count else { break }
                let nextRange = ranges[changedRangeIndex]
                currentChangedRangeEnd = nextRange.upperBound
                if let nextState = stateAt(nextRange.lowerBound) {
                    line = nextRange.lowerBound
                    state = nextState
                    settled = false
                    continue
                }
                settled = false
            }
            // Limit each chunk to about 1ms.
            if Date().timeIntervalSince(startedAt) * 1000 > 1 { break }
        }
        onDeferTokenize?(lines, themeType)
        if isStopped || isPaused || jobID != backgroundJobID { return }
        if settled || line >= totalLines {
            let pending = pendingPrebuildEndLine
            stopBackgroundTokenize()
            if pending >= 0 { scheduleStatePrebuild(pending) }
            return
        }
        lastLine = line
        backgroundChangedRangeIndex = changedRangeIndex
        post(jobID)
    }
}
