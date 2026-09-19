# 0004: Status parsing uses `--porcelain=v1 -z`, not human `--short`

## Context

Status was parsed from `git status --short --branch`, taking `line:sub(4)`
as the path. Per `git help status`, that human-oriented short format has two
problems for a parser:

1. A staged rename renders as a single line, `R  old.txt -> new.txt` — the
   "path" is the literal string `old.txt -> new.txt`, not two paths. Every
   action built from `item.path` (stage, unstage, discard, diff, open) then
   operated on a pathspec that matches no real file.
2. Filenames containing tabs, newlines, quotes, backslashes, or (by default,
   since `core.quotePath` defaults to true) most non-ASCII bytes are
   C-quoted and octal-escaped in this format. `vim.trim(line:sub(4))` does
   not undo that quoting, so such filenames were parsed as their quoted
   literal representation, not their real name.

Both were verified empirically: a staged `git mv old.txt new.txt` produced
exactly the `"old.txt -> new.txt"` single-string item described above, and
`git diff`/`stage`/`discard` against it silently no-op'd or failed cleanly
depending on the action, never touching the wrong file, but never doing
anything useful either.

Git's own documentation describes an alternate machine format for exactly
this: "`-z` ... the `->` is omitted from rename entries and the field order
is reversed (`from -> to` becomes `to`, `from`) ... a NUL follows each
filename ... filenames containing special characters are not specially
formatted; no quoting or backslash-escaping is performed." `-z` implies
`--porcelain=v1` if no other format is given.

## Decision

`open_status` runs `git status --porcelain=v1 -z --branch`. `parse_status`
splits the NUL-delimited stream into fields. The branch header is the first
field. Every subsequent field is a `"XY path"` entry; when the status code's
first *or* second character is `R` or `C`, the entry consumes one *more*
field, which is the origin path (in `-z` output, rename/copy entries are a
`to`, `from` pair with no `->`, matching Git's documented field order).

Items now carry `old_path` (already part of the documented item shape in
`docs/architecture.md`, previously never populated) alongside `path`, which
is always the item's current, real, on-disk name. Every action still keys
off `item.path`.

## Consequences

- Renamed files are addressable, diffable, stageable, and discardable again,
  keyed by their real current path.
- Filenames with tabs, quotes, or non-ASCII bytes parse as their real bytes,
  not a quoted/escaped placeholder — no separate unquoting step is needed.
- The status line rendering shows `old -> new` for renames using the
  correctly-split fields, restoring the visual affordance the broken format
  accidentally still displayed.

## Revisit if

A future Git version changes the `-z` field-order contract described above
(unlikely — it is a stable, documented machine format) or CurrantGit needs
to detect worktree-only (unstaged) renames, which this repository's
installed Git does not report as `R` by default even with
`--find-renames` — that would need its own investigation against upstream
Git before assuming the same two-field shape applies.
