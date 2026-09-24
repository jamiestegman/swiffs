// Port of the color variables and line background cascade in
// `packages/diffs/src/style.css`.
//
// The stylesheet derives every surface color from a handful of theme inputs
// with `color-mix(in lab, ...)` and `light-dark()`. `DiffsPalette` resolves
// those variables for one color scheme, and `lineBackground` reproduces the
// per-element cascade (diff line tint -> selection -> hover).

import Foundation

/// The theme colors `getHighlighterThemeStyles` exposes for one theme.
public struct ThemeColorInputs: Hashable, Sendable {
    public var fg: RGBAColor
    public var bg: RGBAColor
    /// `gitDecoration.addedResourceForeground` / `terminal.ansiGreen`.
    public var additionColor: RGBAColor?
    /// `gitDecoration.deletedResourceForeground` / `terminal.ansiRed`.
    public var deletionColor: RGBAColor?
    /// `gitDecoration.modifiedResourceForeground` / `terminal.ansiBlue`.
    public var modifiedColor: RGBAColor?

    public init(fg: RGBAColor, bg: RGBAColor, additionColor: RGBAColor? = nil, deletionColor: RGBAColor? = nil, modifiedColor: RGBAColor? = nil) {
        self.fg = fg
        self.bg = bg
        self.additionColor = additionColor
        self.deletionColor = deletionColor
        self.modifiedColor = modifiedColor
    }
}

/// CSS custom property overrides (`--diffs-*-override`).
public struct DiffsColorOverrides: Hashable, Sendable {
    public var bgBuffer: RGBAColor?
    public var bgHover: RGBAColor?
    public var bgContext: RGBAColor?
    public var bgContextGutter: RGBAColor?
    public var bgSeparator: RGBAColor?
    public var fgNumber: RGBAColor?
    public var fgNumberAddition: RGBAColor?
    public var fgNumberDeletion: RGBAColor?
    public var fgConflictMarker: RGBAColor?
    public var deletionColor: RGBAColor?
    public var additionColor: RGBAColor?
    public var modifiedColor: RGBAColor?
    public var bgDeletion: RGBAColor?
    public var bgDeletionNumber: RGBAColor?
    public var bgDeletionEmphasis: RGBAColor?
    public var bgAddition: RGBAColor?
    public var bgAdditionNumber: RGBAColor?
    public var bgAdditionEmphasis: RGBAColor?
    public var conflictBgCurrent: RGBAColor?
    public var conflictBgCurrentNumber: RGBAColor?
    public var conflictBgCurrentHeader: RGBAColor?
    public var conflictBgIncoming: RGBAColor?
    public var conflictBgIncomingNumber: RGBAColor?
    public var conflictBgIncomingHeader: RGBAColor?
    public var selection: RGBAColor?
    public var bgSelection: RGBAColor?
    public var bgSelectionNumber: RGBAColor?

    public init() {}
}

public struct DiffsPalette: Hashable, Sendable {
    public var isDark: Bool
    public var bg: RGBAColor
    public var fg: RGBAColor
    /// `--diffs-mixer`: black in light schemes, white in dark schemes.
    public var mixer: RGBAColor
    public var bgBuffer: RGBAColor
    public var bgContext: RGBAColor
    public var bgContextGutter: RGBAColor
    public var bgSeparator: RGBAColor
    public var fgNumber: RGBAColor
    public var fgConflictMarker: RGBAColor
    public var deletionBase: RGBAColor
    public var additionBase: RGBAColor
    public var modifiedBase: RGBAColor
    public var warningBase: RGBAColor
    public var bgDeletion: RGBAColor
    public var bgDeletionEmphasis: RGBAColor
    public var bgAddition: RGBAColor
    public var bgAdditionEmphasis: RGBAColor
    public var selectionBase: RGBAColor
    public var selectionNumberFg: RGBAColor
    public var overrides: DiffsColorOverrides

    static let addedLight = RGBAColor(css: "#0dbe4e")!
    static let addedDark = RGBAColor(css: "#5ecc71")!
    static let modifiedLight = RGBAColor(css: "#009fff")!
    static let modifiedDark = RGBAColor(css: "#69b1ff")!
    static let deletedLight = RGBAColor(css: "#ff2e3f")!
    static let deletedDark = RGBAColor(css: "#ff6762")!
    static let warningLight = RGBAColor(css: "#d5a910")!
    static let warningDark = RGBAColor(css: "#ffd452")!

    /// Resolves the palette for one color scheme.
    ///
    /// - Parameters:
    ///   - theme: The theme providing `--diffs-fg` / `--diffs-bg` and git
    ///     colors for this scheme.
    ///   - isDark: The active color scheme (`light-dark()` branch).
    public init(theme: ThemeColorInputs, isDark: Bool, overrides: DiffsColorOverrides = DiffsColorOverrides()) {
        self.isDark = isDark
        self.overrides = overrides
        let bg = theme.bg
        let fg = theme.fg
        let mixer: RGBAColor = isDark ? .white : .black
        func ld(_ light: Double, _ dark: Double) -> Double { isDark ? dark : light }
        self.bg = bg
        self.fg = fg
        self.mixer = mixer
        bgBuffer = overrides.bgBuffer ?? bg.mix(mixer, 92)
        let bgContext = overrides.bgContext ?? bg.mix(mixer, ld(98.5, 92.5))
        self.bgContext = bgContext
        bgContextGutter = overrides.bgContextGutter ?? bgContext.mix(bg, ld(90, 45))
        bgSeparator = overrides.bgSeparator ?? bg.mix(mixer, ld(96, 85))
        let fgNumber = overrides.fgNumber ?? fg.mix(bg, 65)
        self.fgNumber = fgNumber
        fgConflictMarker = overrides.fgConflictMarker ?? fgNumber

        let deletionBase = overrides.deletionColor ?? theme.deletionColor ?? (isDark ? Self.deletedDark : Self.deletedLight)
        let additionBase = overrides.additionColor ?? theme.additionColor ?? (isDark ? Self.addedDark : Self.addedLight)
        let modifiedBase = overrides.modifiedColor ?? theme.modifiedColor ?? (isDark ? Self.modifiedDark : Self.modifiedLight)
        self.deletionBase = deletionBase
        self.additionBase = additionBase
        self.modifiedBase = modifiedBase
        warningBase = isDark ? Self.warningDark : Self.warningLight

        bgDeletion = overrides.bgDeletion ?? bg.mix(deletionBase, ld(88, 80))
        bgDeletionEmphasis = overrides.bgDeletionEmphasis ?? deletionBase.withAlpha(ld(0.15, 0.2))
        bgAddition = overrides.bgAddition ?? bg.mix(additionBase, ld(88, 80))
        bgAdditionEmphasis = overrides.bgAdditionEmphasis ?? additionBase.withAlpha(ld(0.15, 0.2))

        let selectionBase = overrides.selection ?? modifiedBase
        self.selectionBase = selectionBase
        selectionNumberFg = selectionBase.mix(mixer, ld(65, 75))
    }

    /// Color for a pair of `light-dark(light%, dark%)` values.
    func pick(_ light: Double, _ dark: Double) -> Double { isDark ? dark : light }
}

/// The kind of element whose background is resolved (the attribute the CSS
/// rules select on).
public enum DiffsSurface: Hashable, Sendable {
    /// `[data-line]`
    case line
    /// `[data-no-newline]`
    case noNewline
    /// `[data-column-number]`
    case lineNumber
    /// `[data-gutter-buffer]` next to rows of the given kind.
    case gutterBuffer(GutterBufferKind)
    /// `[data-line-annotation]`
    case annotation
    /// `[data-merge-conflict]` marker rows.
    case mergeConflictMarker(MergeConflictMarkerRowType)
    /// `[data-merge-conflict-actions]`
    case mergeConflictActions
}

public enum GutterBufferKind: Hashable, Sendable {
    case annotation
    case buffer
    case metadata
    case mergeConflictAction
    case mergeConflictMarker(MergeConflictMarkerRowType)
}

/// Merge conflict tint for lines inside unresolved conflicts.
public enum MergeConflictLineTint: Hashable, Sendable {
    case current
    case incoming
}

public struct LineVisualState: Hashable, Sendable {
    public var lineType: LineType?
    public var mergeConflict: MergeConflictLineTint?
    /// `data-background` (the `disableBackground` option is off).
    public var backgroundEnabled: Bool
    public var selected: Bool
    public var hovered: Bool
    /// Rendered inside a file with merge conflicts (`data-has-merge-conflict`).
    public var hasMergeConflict: Bool

    public init(
        lineType: LineType? = nil,
        mergeConflict: MergeConflictLineTint? = nil,
        backgroundEnabled: Bool = true,
        selected: Bool = false,
        hovered: Bool = false,
        hasMergeConflict: Bool = false
    ) {
        self.lineType = lineType
        self.mergeConflict = mergeConflict
        self.backgroundEnabled = backgroundEnabled
        self.selected = selected
        self.hovered = hovered
        self.hasMergeConflict = hasMergeConflict
    }
}

extension DiffsPalette {
    /// Resolves `background-color` for a surface following the cascade in
    /// `style.css`.
    public func background(for surface: DiffsSurface, state: LineVisualState) -> RGBAColor {
        let isNumberish: Bool = {
            switch surface {
            case .lineNumber, .gutterBuffer: return true
            default: return false
            }
        }()

        // --diffs-computed-decoration-bg
        var decorationBg = bg
        var hoverTarget = overrides.bgHover ?? mixer
        switch surface {
        case .annotation, .gutterBuffer(.annotation):
            decorationBg = state.hasMergeConflict ? bg : (surface == .annotation ? bgContext : bgContextGutter)
        case .mergeConflictActions, .gutterBuffer(.mergeConflictAction),
             .gutterBuffer(.mergeConflictMarker(.markerBase)), .gutterBuffer(.mergeConflictMarker(.markerSeparator)),
             .mergeConflictMarker(.markerBase), .mergeConflictMarker(.markerSeparator):
            decorationBg = bgContext
        case .gutterBuffer(.mergeConflictMarker(.markerStart)), .mergeConflictMarker(.markerStart):
            decorationBg = bg.mix(overrides.conflictBgCurrentHeader ?? additionBase, pick(78, 68))
        case .gutterBuffer(.mergeConflictMarker(.markerEnd)), .mergeConflictMarker(.markerEnd):
            decorationBg = bg.mix(overrides.conflictBgIncomingHeader ?? modifiedBase, pick(78, 68))
        default:
            break
        }
        let hoverIsActiveBg: Bool = {
            switch surface {
            case .annotation, .mergeConflictActions, .mergeConflictMarker, .gutterBuffer(.annotation),
                 .gutterBuffer(.mergeConflictAction), .gutterBuffer(.mergeConflictMarker):
                return true
            default:
                return false
            }
        }()

        if case .gutterBuffer(.buffer) = surface {
            // `[data-gutter-buffer='buffer']` pins `--diffs-line-bg`.
            return bgContextGutter
        }

        // --diffs-computed-diff-line-bg
        var diffLineBg = decorationBg
        var diffLineMixTarget: RGBAColor?
        let participatesInDiffTint: Bool = {
            switch surface {
            case .line, .noNewline, .lineNumber, .gutterBuffer: return true
            default: return false
            }
        }()
        if state.backgroundEnabled, participatesInDiffTint {
            let mixLight = isNumberish ? 91.0 : 88.0
            let mixDark = isNumberish ? 85.0 : 80.0
            var target: RGBAColor?
            if let tint = state.mergeConflict {
                switch tint {
                case .current:
                    target = isNumberish
                        ? (overrides.conflictBgCurrentNumber ?? additionBase)
                        : (overrides.conflictBgCurrent ?? additionBase)
                case .incoming:
                    target = isNumberish
                        ? (overrides.conflictBgIncomingNumber ?? modifiedBase)
                        : (overrides.conflictBgIncoming ?? modifiedBase)
                }
            } else if state.lineType == .changeDeletion {
                target = isNumberish
                    ? (overrides.bgDeletionNumber ?? deletionBase)
                    : (overrides.bgDeletion ?? deletionBase)
            } else if state.lineType == .changeAddition {
                target = isNumberish
                    ? (overrides.bgAdditionNumber ?? additionBase)
                    : (overrides.bgAddition ?? additionBase)
            }
            if let target {
                diffLineMixTarget = target
                hoverTarget = target
                diffLineBg = decorationBg.mix(target, pick(mixLight, mixDark))
            }
        }

        // --diffs-computed-selected-line-bg
        var selectedBg = diffLineBg
        let selectionTarget: RGBAColor = isNumberish
            ? (overrides.bgSelectionNumber ?? selectionBase)
            : (overrides.bgSelection ?? selectionBase)
        if state.selected {
            let (light, dark) = isNumberish ? (75.0, 60.0) : (82.0, 75.0)
            selectedBg = diffLineBg.mix(selectionTarget, pick(light, dark))
            hoverTarget = selectionTarget
        }
        _ = diffLineMixTarget

        // --diffs-computed-hovered-line-bg
        var result = selectedBg
        if state.hovered {
            let target = hoverIsActiveBg ? selectedBg : hoverTarget
            result = selectedBg.mix(target, pick(97, 91))
        }
        return result
    }

    /// Foreground color of line numbers.
    public func lineNumberColor(state: LineVisualState) -> RGBAColor {
        if state.selected { return selectionNumberFg }
        if state.backgroundEnabled {
            if let tint = state.mergeConflict {
                switch tint {
                case .current: return overrides.fgNumberAddition ?? additionBase
                case .incoming: return modifiedBase
                }
            }
            switch state.lineType {
            case .changeDeletion: return overrides.fgNumberDeletion ?? deletionBase
            case .changeAddition: return overrides.fgNumberAddition ?? additionBase
            default: break
            }
        }
        return fgNumber
    }

    /// Background of intra-line change spans.
    public func diffSpanBackground(lineType: LineType) -> RGBAColor? {
        switch lineType {
        case .changeAddition: return bgAdditionEmphasis
        case .changeDeletion: return bgDeletionEmphasis
        default: return nil
        }
    }
}
