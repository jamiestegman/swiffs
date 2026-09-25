# Local patches to Oniguruma 6.9.10

Every change is marked with a `swiffs` comment. Re-apply them when upgrading.

## Cached position-lead regset search (`src/regexec.c`)

`swiffs_onig_regset_search_cached` is `onig_regset_search` in
`ONIG_REGSET_POSITION_LEAD` mode, except that each regex's forward-search state
(`SearchRange`) is kept in the set between calls on the same string instead of
being recomputed for every call.

TextMate tokenizers call a scanner repeatedly on one line with increasing start
positions. `forward_search()` finds the first candidate position at or after
`start + dist_min`; that result depends only on the string and the candidate,
not on the call. State computed at position `c` is therefore reused for a
later start `s` when:

- the string, end, range and options are the same (the caller passes
  `same_string` and must keep the string alive and unmodified), and
- `c <= s` for that regex.

Staleness beyond that is harmless: the search loop already re-runs
`forward_search()` when `s >= high`, and an `SRS_ALL_RANGE` entry only means
`match_at()` is tried at more positions. The extra validity checks on reuse
skip that extra work.

Changes:

- `SearchRange` is declared before `struct OnigRegSetStruct`, which gains the
  cache fields (initialized in `onig_regset_new`, freed in `onig_regset_free`,
  invalidated in `onig_regset_add`/`onig_regset_replace`).
- `regset_search_body_position_lead` uses the set's arrays when the cache is
  enabled, records where each entry was computed, and keeps them on exit.
- `swiffs_onig_regset_search_cached` (declared in
  `include/swiffs_onig_shim.h`) enables the cache for one call.

Tests: `OnigParityTests` replays scanner calls recorded from vscode-oniguruma,
in order and shuffled, and compares a reused scanner against fresh scanners
for random start positions.
