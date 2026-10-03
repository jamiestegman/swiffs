# Architecture

Swiffs has four modules. The lower three port upstream libraries and are held to them by golden fixtures. `SwiffsUI` is a native macOS design that renders their output. It matches upstream's look, not its components ([S1](decisions.md)).

| Module | Holds | Isolation | Follows upstream |
| --- | --- | --- | --- |
| `SwiffsCore` | Patches, diffs, hunks, rows, merge conflicts | Nonisolated; public types are `Sendable` values | Yes |
| `SwiffsHighlight` | TextMate tokenizer, Oniguruma, themes, `HighlightService` | Nonisolated; `HighlightService` owns every background thread | Yes |
| `SwiffsEditor` | Editor model: piece table, history, selections, commands | Nonisolated; one owner at a time, not `Sendable` | Yes |
| `SwiffsUI` | `DiffView` (AppKit), `DiffList` (SwiftUI) | Main actor by default | No |

`SwiffsHighlight` depends on `SwiffsCore`; `SwiffsEditor` on both. `SwiffsUI` depends on `SwiffsCore` and `SwiffsHighlight`, and on `SwiffsEditor` once editing is built.

## Isolation

The isolation map ([S3](decisions.md)):

- **Core**: every public type is a `Sendable` value. A cache shared across threads is a `Mutex`.
- **Highlight**: grammars and themes are immutable once loaded; the registry is a `Mutex`. A highlighter belongs to one `HighlightWorker` actor and is never shared. `HighlightService` is the only code that starts work off the caller's thread. Its `highlight(_:options:)` is `async` and `@concurrent`, runs on the least loaded of a bounded set of workers, and gives requests for the same content key one shared task and one cached result. Within one call, a large diff may tokenize its two sides on two threads with a synchronous fork-join.
- **Documented exceptions** in the lower modules, each with its reason at the declaration: compiled Oniguruma regexes are `@unchecked Sendable` (Oniguruma only reads them while searching), the tokenizer's initial state is a never-mutated `nonisolated(unsafe)` sentinel, and edit-prediction patterns wrap an immutable `NSRegularExpression`.
- **Editor**: model types used from one isolation domain at a time (the main actor, once the UI uses them).
- **UI**: the target sets `.defaultIsolation(MainActor.self)`. It awaits `HighlightService` from tasks the view owns, and cancels them when an item leaves or changes. Nothing else crosses threads.

These are not used in `SwiffsUI`, and CI rejects them: `DispatchQueue`, `Timer`, `assumeIsolated`, `@unchecked Sendable`, `nonisolated(unsafe)`, `NSLock`. Animation steps on the view's display link, and the view reads time from an injected clock.

## SwiffsUI

### Shape

```
DiffList (SwiftUI) ── wraps ──▶ DiffView (NSView)
                                  ├─ NSScrollView
                                  │    └─ DocumentView ── draws rows in tiles, places hosts
                                  ├─ StickyHeader overlay
                                  ├─ RowIndex ◀── rows from SwiffsCore, flattened across items
                                  └─ ContentHost × n ── SwiftUI annotations and accessories
HighlightService (SwiffsHighlight) ◀── awaited per item, prefetched ahead of scrolling
```

One view shows a list of items. An item is a diff, a file or a file with merge conflict markers. A single diff is a list of one ([S5](decisions.md)).

### Values in, events out

- **Input** is values: `[DiffItem]` (id, content, highlight key, collapsed), `[DiffAnnotation<ID>]` (the client's id and an anchor: item, side, line) and a `DiffConfiguration` (style, theme, typography, options). Selection and scroll position are bindings.
- **Diffing**: each input is compared with the last by id, as a diffable data source does. Unchanged items keep their layout, highlighting and hosted content. A changed item rebuilds only itself.
- **Events** go to one `DiffViewDelegate` protocol in AppKit, and to a few view modifiers in SwiftUI. There are no closure properties, and no `Any` ([S6](decisions.md)).

### Rows and heights

- Each item's rows come from `SwiffsCore` (`buildDiffRows`, `buildFileRows`, merge-conflict parsing), which the fixtures already verify. The view flattens them into one row space across items. Kinds of row: item header, hunk separator, line, annotation, conflict actions, no newline, split buffer.
- **`RowIndex`** maps between a y offset and a row in O(log n).
  - Most rows are one line high.
  - Rows of other heights are stored sparsely: annotations, separators, wrapped lines and conflict actions.
  - A collapsed item contributes only its header.
- When a row's height changes, the index updates and the first visible row stays at the same place on screen. Content changing above the viewport never moves what is being read.

### Drawing

- Rows are drawn with Core Text into tile views.
  - Each tile covers at most a viewport of rows, and tiles are recycled as the view scrolls.
  - No layer grows with the file, and opaque tiles keep AppKit's responsive scrolling.
- Lines are laid out once each (`LineLayout`, a `CTLine` per visual line), cached by item, side, line and wrap width.
- **Highlighting**:
  - Until highlighting arrives, lines draw in the theme's foreground colour.
  - Colours then fill in without changing the layout, since the font is unchanged.
  - Items within the prefetch distance are highlighted before they scroll in.

### Hosted content: the layout contract

Annotations, header accessories and custom conflict actions are SwiftUI views. Each sits in one `ContentHost` ([S4](decisions.md)).

1. The document view sets every frame. Hosts are placed by frame, and the document view uses no Auto Layout.
2. A host is created when its annotation appears in the input, keyed by the client's id. It lives until that id is gone. Moving an annotation to another line moves its host, so its SwiftUI state survives rows, scrolling and other annotations changing.
3. On creation, a host is measured synchronously at its column's content width with `NSHostingController.sizeThatFits(in:)`. The first frame draws at the right height.
4. From then on, the host gives its content a fixed width and its ideal height, and reports that height with `onGeometryChange`.
   - A report sets the row height in the same layout pass.
   - A width change reaches the content the same way.
   - Clients never call a "height changed" method.
5. Measurement never uses `NSHostingView.fittingSize` or `intrinsicContentSize`, which ignore the width.
6. Each input replaces a host's root view, and SwiftUI diffs it. Content that shows live state observes the client's model.

AppKit content is wrapped by the client in `NSViewRepresentable`, and sizes itself through SwiftUI like any other view.

### Interaction

- Hit testing goes through the row index: a point resolves to an item, row, column and region.
- The view handles:
  - line hover;
  - line selection (drag over numbers, `⇧`-click), on either side and across sides;
  - the gutter action button, pinned to a selection while there is one;
  - text selection and copy;
  - hunk expansion;
  - conflict actions.
- **State ownership**:
  - Presentation state lives in the view: hover, drags, text selection, expanded hunks, horizontal offsets.
  - Client state comes in as input: items, annotations, collapsed items, line selection.
- Rows are accessibility elements.

### Scrolling

- Scroll targets are an item, a line or a range, with an alignment and an offset. They scroll instantly or smoothly.
- Smooth scrolling is a spring stepped on the display link.
- The sticky header is the header of the item at the top of the viewport, drawn in an overlay.
- Code scrolls horizontally per item, with both split columns together. It is drawn at an offset, not in a nested scroll view.

## Testing

| What | How |
| --- | --- |
| Row flattening, the index, input diffing | Unit tests on values |
| Layout contract | `DiffList` in an `NSHostingView` in a window, as apps host it. Content and width changes are asserted within one layout pass ([S8](decisions.md)) |
| Look | `Scripts/visual-regression` against references, and `swiffs-snapshot` against upstream's rendering |
| Interaction | `NSEvent`s sent through the window |
| Time | An injected clock; no test sleeps |
| Concurrency | `SwiffsHighlight` tests under Thread Sanitizer; the banned-construct check on `SwiffsUI` |
| Performance | Scrolling and mounting a large fixture in Release, measured with Instruments' Animation Hitches, at 120 Hz |
| Parity | Golden fixtures for Core and Highlight, unchanged |
