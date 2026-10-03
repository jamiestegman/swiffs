# Plan

## Rebuild of SwiffsUI

Each step ends with `swift test` passing and its docs true. Manta stays on its pinned revision until R6.

- [x] R0 Architecture, decisions, requirements and agent instructions
- [x] R1 Lower modules to the isolation map: `Sendable` values and `Mutex` caches in Core and Highlight, `HighlightService` with an async `@concurrent` API, Highlight tests under Thread Sanitizer in CI. Fixtures unchanged
- [ ] R2 Tag `legacy-ui`, and record visual-regression references from it. Replace `SwiffsUI` with the new module: rows flattened across items, `RowIndex`, tiles drawing a static list, the banned-construct check. Match the references; measure scrolling against the legacy view
- [ ] R3 `ContentHost` and the layout contract, tested in a SwiftUI-hosted window; annotations, header accessories, collapsed items
- [ ] R4 Hover, line selection, the gutter action button, text selection and copy, accessibility
- [ ] R5 Hunk expansion, scroll targets with smooth scrolling, the sticky header, horizontal scrolling, wrapping
- [ ] R6 `DiffList`, `SwiffsDemo` and `swiffs-snapshot` on the new view. Manta moves to it and deletes its own wrapper
- [ ] R7 Conflicted files
- [ ] R8 Growing files
- [ ] R9 Tag `0.1.0`

Later: editing ([requirements](requirements.md#later-waits-for-a-user)).
