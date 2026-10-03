# Plan

## Rebuild of SwiffsUI

Each step ends with `swift test` passing and its docs true. Manta stays on its pinned revision until R6.

- [x] R0 Architecture, decisions, requirements and agent instructions
- [x] R1 Lower modules to the isolation map: `Sendable` values and `Mutex` caches in Core and Highlight, `HighlightService` with an async `@concurrent` API, Highlight tests under Thread Sanitizer in CI. Fixtures unchanged
- [x] R2 Tag `legacy-ui` and record visual-regression references from it. Replace `SwiffsUI` with the new module: items laid out lazily in one document, drawn by one view, the banned-construct check. The references match pixel for pixel except SwiftUI annotation text; scrolling and first frame measured against the legacy view
- [x] R3 Hosted content and the layout contract, tested in a SwiftUI-hosted window; annotations, header accessories, collapsed items
- [x] R4 Hover, line selection, the gutter action button, text selection and copy, accessibility
- [x] R5 Hunk expansion, scroll targets with smooth scrolling, the sticky header, horizontal scrolling, wrapping
- [x] R6 `DiffList`, `swiffs-snapshot` and `SwiffsDemo`; Manta moves to `DiffList` and deletes its own wrapper (on Manta's `swiffs-native-ui` branch, pinned to this module's first complete commit)
- [x] R7 Conflicted files
- [x] R8 Growing files
- [x] R9 Tag `0.1.0`

Later: editing ([requirements](requirements.md#later-waits-for-a-user)).
