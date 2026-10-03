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
                                  │    └─ DocumentView ── draws the rows in view, places hosted views
                                  ├─ StickyHeaderView ── over the scroll view
                                  ├─ DocumentLayout ── items' positions ◀── ItemModel × n ◀── rows from SwiffsCore
                                  ├─ AnnotationHost × n, AccessoryHost × n ── SwiftUI content
                                  └─ ScrollAnimator ── scroll targets, spring
HighlightService (SwiffsHighlight) ◀── awaited per item before it scrolls in
```

One view shows a list of items. An item is a diff, a file or a file with merge conflict markers. A single diff is a list of one ([S5](decisions.md)).

| Type | Owns |
| --- | --- |
| `DiffView` | The public view: input, hosted views, highlighting tasks, scrolling, the delegate |
| `DocumentLayout` | Items' positions in the document; which items have rows |
| `ItemModel` | One item: parsed content, rows and their heights, highlighting, laid out lines, expanded hunks |
| `DocumentView` | Drawing, hit testing, hover, line and text selection, copy |
| `ItemPainter`, `HeaderPainter` | Core Text and Core Graphics drawing of one item |
| `AnnotationHost`, `AccessoryHost` | SwiftUI content under the layout contract |
| `DiffList` | The SwiftUI wrapper: bindings, event modifiers, the environment |

### Values in, events out

- **Input** is values ([S6](decisions.md)):
  - `update(items:annotations:configuration:)` takes `[DiffItem]` (id, content, collapsed), `[DiffAnnotation<ID>]` (the client's id, item, side, line) and a `DiffConfiguration`;
  - content keys its highlighting with `FileDiffMetadata.cacheKey` or `FileContents.cacheKey`;
  - an update equal to the last does nothing.
- **Diffing**: items are matched by id. Unchanged items keep their rows, highlighting and hosted views; a changed item rebuilds only itself.
- **Events** go to one `DiffViewDelegate`; every method has a default. `DiffList` turns them into bindings (`selection`, `position`) and modifiers (`onDiffGutterAction`, `onDiffConflictResolution`, `diffFileLoader`). There are no closure properties and no `Any` in the API.
- **Conflicts are values too**: an action reports the resolved file, and the client passes it back as the item's content ([S11](decisions.md)).

### Rows and heights

- An item's rows come from `SwiffsCore` (`buildDiffRows`, `buildFileRows`, merge-conflict parsing), which the fixtures verify.
- **Rows are built only near the viewport** ([S12](decisions.md)).
  - Items within the overscan build their rows and lay them out.
  - Items farther away are estimated from their hunks. The estimate equals the built height when nothing wraps and nothing is annotated, so building rows moves nothing.
  - Items several viewports away release their rows and laid out lines, and keep their height.
  - A collapsed item is only its header.
- **Lookups are binary searches**: items by y, then rows within an item. Row offsets are prefix sums per item.
- **The read line stays put**: before laying out again, the view records the row at the top of the viewport and its offset, and restores them afterwards. Content changing above the viewport never moves what is being read.

### Drawing

- One flipped `DocumentView` draws the items and rows that intersect the dirty rect, with Core Text. AppKit tiles its layer and keeps responsive scrolling, so no layer grows with the content ([S9](decisions.md)).
- Hover, selection and highlighting redraw only the rows or items they change; a layout redraws only when something moved.
- Lines are laid out once each (`LineLayout`, a `CTLine` per visual line), cached per item by side and line.
- **Highlighting**:
  - Items within the overscan and prefetch distance are highlighted on `HighlightService` before they scroll in.
  - Content an update shows is highlighted at once when it is small (`synchronousHighlightLineLimit`), so it never appears plain. While scrolling, nothing highlights on the main thread.
  - Until its highlighting arrives, a line draws in the theme's foreground colour. The colours then fill in without moving anything.

### Hosted content: the layout contract

Annotations and header accessories are SwiftUI views, hosted by `AnnotationHost` and `AccessoryHost` ([S4](decisions.md)).

1. The document view sets every frame. Hosts are placed by frame, and the document view uses no Auto Layout.
2. An annotation's host is created when its id appears in the input, and lives until the id is gone. Moving an annotation to another line moves its host, so its SwiftUI state survives rows, scrolling and other annotations changing.
3. On creation, and when its column's width changes, a host is measured at the column's content width with `NSHostingController.sizeThatFits(in:)`. The frame it is drawn at is already the right height.
4. From then on, the host gives its content that width and its ideal height, and reports the height with `onGeometryChange`.
   - A report lays the item out again in the same layout pass.
   - Clients never call a "height changed" method.
5. Measurement never uses `NSHostingView.fittingSize` or `intrinsicContentSize`, which ignore the width.
6. Each update replaces a host's root view, and SwiftUI diffs it. Content that shows live state observes the client's model.
7. Annotations on one line stack in input order, each at the column's full width.
8. An accessory sits at its ideal size at the trailing edge of its item's header, and moves into the sticky header while that item is stuck.

`DiffList` gives hosted content its own environment (`.environment(\.self, …)`), so content reads the same environment values as the rest of the app ([S10](decisions.md)). AppKit content is wrapped by the client in `NSViewRepresentable`, and sizes itself through SwiftUI like any other view.

### Interaction

- **Hit testing** goes through the layout: a point resolves to an item, row, column and region (a line or its number, an annotation, a separator button, a conflict action, the gutter action button).
- **The view handles**:
  - line hover;
  - line selection (drag over numbers, `⇧`-click to extend, click a selected line to clear);
  - the gutter action button, pinned to a selection while there is one, and dragged to select;
  - text selection within one column (drag, double-click for a word, triple-click for a line) and copy;
  - hunk expansion, loading full files first for partial diffs when `loadsFullFiles` is set;
  - conflict actions;
  - horizontal scrolling of an item's code.
- **State ownership**:
  - Presentation state lives in the view: hover, gestures, text selection, expanded hunks, horizontal offsets.
  - Client state comes in as input: items, annotations, collapsed items, line selection.

### Scrolling

- Scroll targets are an item, a line or a range, aligned to the start, centre, end or nearest edge. They scroll instantly, smoothly, or smoothly within two viewports.
- A line target in an item without rows builds that item's rows first.
- Smooth scrolling is a critically damped spring stepped on the view's display link. `stepScrollAnimation(at:)` takes the time, so tests drive it frame by frame.
- The sticky header is the header of the item at the top of the viewport, drawn in a view over the scroll view, and pushed up by the next item.
- Code scrolls horizontally per item, with both split columns together, drawn at an offset rather than in a nested scroll view.

## Testing

| What | How |
| --- | --- |
| Layout contract | `DiffList` in an `NSHostingView` in a window, as apps host it. Content and width changes are asserted within one layout pass ([S8](decisions.md)) |
| Behaviour | `DiffView` in a window, driven with `NSEvent`s and inputs: virtualisation, anchoring, scrolling, selection, the gutter action, conflicts, highlighting |
| Look | `Scripts/visual-regression` renders cases with `swiffs-snapshot` and compares them pixel for pixel; images are never committed |
| Time | Smooth scrolling steps with given timestamps; asynchronous highlighting is awaited by yielding. No test sleeps |
| Concurrency | `SwiffsHighlight` concurrency tests under Thread Sanitizer in CI; a test fails if `SwiffsUI` uses a banned construct |
| Performance | Scrolling and first frame of 300 files, measured in Release against the `legacy-ui` view |
| Parity | Golden fixtures for Core and Highlight, unchanged |

`swift test --filter SwiffsUITests` runs the view's tests in about a second.
