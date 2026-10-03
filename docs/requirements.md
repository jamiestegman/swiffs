# SwiffsUI requirements

What the rebuilt view must do, and for whom ([S7](decisions.md)). Manta is the first user.

## Required: Manta uses it today

| Feature | Use in Manta |
| --- | --- |
| One virtualised list of every changed file, sticky file headers | Branch review, like a pull request |
| Unified and split styles | `⌘\` |
| Highlighting that matches Shiki, light and dark themes, cached by a content key, prefetched before scrolling in | Every diff; Manta keys by file name and blob ids |
| Word-level change spans within a line | Reading small edits |
| New, deleted, renamed and binary files; no newline at end of file | Every branch |
| Header with icon, name, `+`/`−` counts and an accessory view | The Viewed checkbox |
| Collapsed items showing only their header | Viewed files; large and generated files |
| Annotations: SwiftUI views on either side, any number per line, growing and shrinking with their content | Comment cards and the inline comment form |
| Line selection on either side and across sides; a gutter action button that follows the pointer and pins to a selection | Range comments |
| Scroll to an item, line or range; smooth for short distances | `n`/`p` files, `j`/`k` hunks |
| Text selection and copy | Copying code |
| Typography that follows the app's text size | View ▸ Make Text Bigger |
| Accessibility for rows, lines and actions | VoiceOver |

## Kept: Manta has a named use

| Feature | Use in Manta |
| --- | --- |
| **Conflicted files**: a file with conflict markers shown as current against incoming, with Accept current, Accept incoming and Accept both on each conflict. The resolution goes to the client, which writes the file | During a merge or rebase, show conflicted files in the diff and resolve the simple ones with a click. The rest go to the agent through Resolve conflicts |
| **Growing files**: appended text redraws and highlights only the new tail, and earlier rows keep their layout | A file the agent is writing, shown live |
| Hunk expansion, with full files loaded on demand for a patch | Seeing context around a change, as on GitHub |
| Line wrapping as an option | Long lines in narrow panes |
| Line hover highlight | Pointer feedback in review |

## Later: waits for a user

| Feature | Notes |
| --- | --- |
| **Editing**: an editable file or new side, multiple selections, undo, keymaps, edit prediction | Manta's product is not an editor. The `SwiffsEditor` model keeps its fixtures, and the document view leaves room for text input. Likely first use: hand-editing a conflict that no accept action resolves |

## Dropped

| Feature | Why |
| --- | --- |
| Token hover and click events | No use. Hit testing makes them cheap to add later |
| Separate file, diff, stream and unresolved views, and a SwiftUI wrapper for each | One view over items ([S5](decisions.md)) |
| Render lifecycle callbacks (`onPreRender`, `onPostRender`) and a "height changed" call | Inputs are values, and hosts report their own size ([S4](decisions.md)) |
| Retained edit state across editors (`EditStateManager`) | Goes with editing |
| Custom conflict action content | No use; the three actions are drawn natively |
