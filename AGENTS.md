# Swiffs

Native diff and code rendering for macOS. The diff, highlighting and editor-model modules port [`@pierre/diffs`](https://github.com/pierrecomputer/pierre/tree/main/packages/diffs). `SwiffsUI` is a native AppKit and SwiftUI view over their output.

## Read this first

| You need | Read |
| --- | --- |
| Modules, isolation, the view's design, the layout contract | `docs/architecture.md` |
| Why something is the way it is | `docs/decisions.md` |
| What the view must do, and for whom | `docs/requirements.md` |
| What to build next | `docs/plan.md` |
| Upstream baseline and porting policy | `UPSTREAM.md` |

## Structure

- **Upstream fidelity stops at the UI.** Core, Highlight and Editor follow upstream, proven by golden fixtures. `SwiffsUI` borrows neither upstream's component shapes nor its names ([S1](docs/decisions.md)).
- **The isolation map is a rule.** `SwiffsUI` is main-actor; `HighlightService` is the only way off the main thread. Banned constructs are listed in the architecture doc.
- **Hosted content follows the layout contract.** Measure with `sizeThatFits` at the column width, then follow `onGeometryChange`. Never measure with `fittingSize` or `intrinsicContentSize`.
- **One path per feature.** One view, one row index, one content host. If a fix has to land in two places, the structure is wrong: fix the structure.
- **Values in, events out.** Inputs are values diffed by id, events go to one delegate or SwiftUI modifiers, and selection and scroll position are bindings. No closure properties, no `Any`.
- **Illegal states are unrepresentable.** Lifecycles are enums; required collaborators are non-optional; errors are typed.

## Working rules

- Write the black-box test first, and see it fail. UI tests host the view inside SwiftUI as apps do ([S8](docs/decisions.md)), inject time, and never sleep.
- A UI change is checked in the setup it is for. A probe or test in a plain window does not prove behaviour inside a SwiftUI-hosted one.
- Update the docs in the same commit as the change. Record a new decision in `docs/decisions.md`, and tick finished steps in `docs/plan.md`.
- Commit small, one idea each: behaviour, refactors, formatting and dependency updates never share a commit.
- No comments in code unless essential. One line at most.
- This repository is public. Never commit absolute user paths, usernames, emails, hostnames, tokens, or anyone's prompts or transcripts.
