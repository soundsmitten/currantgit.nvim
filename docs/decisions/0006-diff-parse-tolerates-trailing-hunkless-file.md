# 0006: `diff.parse` tolerates a trailing file with no hunk

## Context

`diff.parse`'s finalization step ran `current_hunk.end_line = #lines`
unconditionally whenever any file in the diff had at least one `@@` hunk
(`has_hunk == true`). `current_hunk` itself is reset to `nil` at each new
`diff --git` file boundary and only reassigned when that file's own `@@`
line appears. Whenever the *last* file in a multi-file diff has no hunk at
all — a binary file, a pure mode/chmod change, a 100%-similarity rename, an
empty file add/delete — while an *earlier* file did have one, `current_hunk`
is `nil` at the end of the loop and indexing it crashes.

This was verified with a real captured `git diff` (a text file with a hunk,
followed alphabetically by a binary file with none). Because `open_diff_args`
calls `diff.parse` inside the async `schedule()` wrapper's `xpcall`, the
crash was caught and surfaced as an error notification rather than a hard
Neovim crash — an availability bug, not a data-loss one, but one that fully
blocked viewing or staging any changeset that happened to end in a
hunkless file.

## Decision

Guard the finalization line: `if current_hunk then current_hunk.end_line =
#lines end`, matching the guard style already used at the two other
`current_hunk.end_line = ...` sites in the same function.

## Consequences

- Multi-file diffs ending in a binary file, mode-only change, pure rename,
  or empty file no longer crash the parser; the last real hunk's
  `end_line` is finalized correctly and the hunkless trailing file simply
  contributes no hunk.

## Revisit if

`diff.parse` grows dedicated handling for binary/mode-only entries (e.g.
surfacing them as their own non-hunk item instead of silently producing no
hunk) — that's a real product gap, not fixed here, just made non-fatal.
