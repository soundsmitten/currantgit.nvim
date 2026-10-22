# 0014: Conflict region keys are `c`-prefixed and fall back to Vim

## Context

docs/issues/0010 proposed `o`, `t`, `b`/`B` and `0` for taking ours,
theirs, both and base. Those keys would be buffer-local mappings on the
result pane, which is the user's real, editable file. `o` (open line), `b`
(word back) and `0` (line start) are core Vim editing keys; taking them
away in a file the user is editing breaks the buffer-first rule in
AGENTS.md.

## Decision

The region keys are `co`, `ct`, `cb`, `cB` and `c0`, the same family
git-conflict.nvim and similar plugins use. They act only when the cursor is
inside a conflict region. Anywhere else the mapping replays the keys
unmapped (with any count), so `cb` still changes back a word and `c0` still
changes to the start of the line.

Regression coverage: `tests/conflict.lua`, `test_region_actions` (every
key inside a region, and `cb` outside one).

## Consequences

- No native key is lost outside conflict regions.
- Inside a region, `cb`/`cB`/`c0` mean "take", not "change". A user who
  wants the native change there can use another motion or edit the markers
  directly.
- Typing `c` waits up to 'timeoutlen' for a possible second key, as any
  `c`-prefixed mapping does.

## Revisit if

Users find the in-region meaning of `cb`/`c0` surprising in practice, or a
non-mapping entry point (a menu or picker over the region's actions) is added.
