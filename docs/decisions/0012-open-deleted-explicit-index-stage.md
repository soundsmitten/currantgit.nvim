# 0012: `open_deleted` uses the explicit `:0:<path>` index-object form

## Context

Audit continuation item 6 flagged `open_deleted`'s `<rev>:<path>` object
specifier as a theoretical colon-in-filename ambiguity worth checking
against current Git documentation rather than assuming. For a
worktree-deleted-but-still-indexed file (status `" D"`), `open_deleted` built
the target as the bare shorthand `":" .. item.path`.

Per `git help gitrevisions`, `:[<n>:]<path>` optionally reads a leading
stage number (0-3) followed by a colon before the path; a missing stage
number defaults to stage 0. This introduces a real, confirmed ambiguity: for
a file literally named `2:file.txt`, Git parses `:2:file.txt` as "stage 2,
path `file.txt`", not "stage 0, path `2:file.txt`" — and fails with a
misleading `fatal: path 'file.txt' does not exist` even though the file is
genuinely present in the index. Reproduced directly against real Git in a
disposable repository.

The `<rev>:<path>` form used for the staged-delete case (`"HEAD:" ..
item.path`) has no equivalent ambiguity — verified separately with a
`HEAD:2:file.txt`-style path — because that form takes everything after the
first colon as the path unconditionally, with no stage-number special-casing
to misfire.

## Decision

`open_deleted` now always builds the index-lookup case as the explicit
`":0:" .. item.path` rather than the ambiguous bare `":" .. item.path`
shorthand. Git only strips one stage-number prefix (the one it was
explicitly given), not a repeated one, so this resolves correctly
regardless of what the path itself starts with.

Regression coverage: `tests/safety.lua`,
`test_open_deleted_colon_in_filename` (a worktree-deleted file literally
named `2:file.txt`, opened through the real `<CR>` mapping end-to-end).

## Consequences

- Opening a worktree-deleted (but still-indexed) file whose name starts with
  a digit 0-3 followed by a colon now works correctly instead of failing
  with a misleading error.
- The staged-delete (`HEAD:<path>`) branch was already correct and is
  unchanged.

## Revisit if

A future feature needs to address a *non-zero* index stage explicitly (e.g.
showing a specific side of an unresolved merge conflict) — that would need
its own explicit `:<n>:<path>` construction with the same "always specify
the stage number" discipline, not a reversion to the ambiguous shorthand.
