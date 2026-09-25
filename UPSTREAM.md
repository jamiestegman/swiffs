# Upstream

Swiffs ports `packages/diffs` from
[pierrecomputer/pierre](https://github.com/pierrecomputer/pierre).

## Baseline

| | |
| --- | --- |
| Commit | [`6460d4ecf6f11a7e4d52a99a87cb1024109723d1`](https://github.com/pierrecomputer/pierre/commit/6460d4ecf6f11a7e4d52a99a87cb1024109723d1) (2026-09-23, #1151) |
| `@pierre/diffs` | 1.4.3 |

The source and the golden fixtures in `Tests/*/Fixtures` both match this
commit.

Upstream changes not yet ported:

| Commit | Change |
| --- | --- |
| [`80c8daf`](https://github.com/pierrecomputer/pierre/commit/80c8daf5) | CodeView / Edit Improvements (#1152), released in 1.5.0 |
| [`41de1fa`](https://github.com/pierrecomputer/pierre/commit/41de1fa7) | New `lineDiffType` `'word-line'` (#1156), released in 1.5.1 |
| [`6ec71c4`](https://github.com/pierrecomputer/pierre/commit/6ec71c4b) | Resolve special filenames nested in a path (#1153) |

## Dependencies

Versions from upstream's `pnpm-lock.yaml` at the baseline commit.

| Upstream dependency | Version | In Swiffs |
| --- | --- | --- |
| `diff` (jsdiff) | 9.0.0 | Ported to `Sources/SwiffsCore/JSDiff` |
| `shiki`, `@shikijs/core` | 4.4.1 | Ported to `Sources/SwiffsHighlight/Shiki` |
| `@shikijs/vscode-textmate` | 10.0.2 | Ported to `Sources/SwiffsHighlight/TextMate` |
| `@shikijs/langs`, `@shikijs/themes` | 4.4.1 | Bundled in `Sources/SwiffsHighlight/Resources` |
| `@pierre/theme` | 2.0.0 | Bundled in `Sources/SwiffsHighlight/Resources/Themes` |
| `lru_map` | 0.4.1 | Replaced by a native LRU cache |
| Oniguruma | 6.9.10 | Vendored in `Sources/COniguruma` |

## Porting upstream changes

- Port released versions of `@pierre/diffs`, in order. Unreleased commits on
  upstream `main` wait for a release.
- Port each upstream change in its own commit, and reference it with a
  trailer, for example `Upstream: pierrecomputer/pierre@41de1fa7`.
- Regenerate the fixtures (`Scripts/fixtures`) from the new commit in the
  same change, so tests always compare against the stated baseline.
- Update the baseline and the tables above when a release is fully ported.
- Changes to web-only code (DOM, React, SSR, workers, CSS) have no Swift
  counterpart; note them as skipped instead of porting them.
- Where Swiffs deliberately differs from upstream, record the difference
  here.
