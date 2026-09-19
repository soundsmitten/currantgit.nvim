# 0003: Hunk stage/unstage require strict diff-mode classification

## Context

Staging a hunk runs `git apply --cached --unidiff-zero` with that hunk's
patch text against the *current index*. The diff surface previously decided
whether to offer `s` (stage hunk) by checking `vim.tbl_contains(args,
"--cached")`: present → `mode = "staged"`, absent → `mode = "working"`, and
`hunk.stage` was available whenever `mode == "working"`.

That check only distinguishes "did the user pass `--cached`" — it says
nothing about whether the diff actually represents a comparison against the
live index. `git diff <rev>` and `git diff <rev1> <rev2>` compare the
working tree or two revisions to each other, not to the index, and neither
one passes `--cached`, so both were classified as `mode = "working"`.

This was verified empirically and is a real exploit, not a theoretical one:
starting from a clean repository, opening `:Git diff <old-tag> <newer-tag>`
(a purely historical, two-revision diff with no relation to the working tree
or index) and pressing `s` on a hunk applied that historical patch to the
current index via `git apply --cached`, because the "old" side of that
historical diff happened to match the current index content. The repository
went from clean to having a staged, phantom modification the user never
asked to create, with no error and no confirmation.

## Decision

A dedicated classifier (`classify_diff_mode`) inspects the actual `git diff`
arguments (everything before a trailing `-- <pathspec>`, with the leading
`diff` token stripped) and returns:

- `"working"` only when there are no arguments before the pathspec — a bare
  `git diff`, which is exactly "working tree vs index."
- `"staged"` only when the sole argument is `--cached` or `--staged` — a
  bare `git diff --cached`, which is exactly "index vs HEAD."
- `"historical"` for everything else, including a single revision
  (`git diff HEAD~1`), two revisions, or any extra flag alongside
  `--cached`/`--staged`.

`hunk.stage` and `hunk.unstage` remain gated on `item.mode == "working"` /
`item.mode == "staged"` respectively, so a `"historical"` diff offers neither
action. `diff.parse`'s own internal default was changed from defaulting an
unspecified mode to `"working"` to defaulting to `"historical"`, so a caller
that forgets to classify a diff fails safe instead of silently becoming
mutable.

## Consequences

- Only a diff that is unambiguously "the live index vs the working tree" or
  "the live index vs HEAD" can offer to mutate the index.
- Any two-revision, single-revision, or flag-decorated diff is read-only for
  staging purposes, even if it happens to look stageable.
- This is intentionally conservative: `git diff --cached <rev>` or
  `git diff --no-color` no longer offer hunk staging either, even though the
  former is close to a legitimate use case. Refusing is the correct default
  here — see the Git safety doctrine's "when in doubt, refuse."

## Revisit if

A real product need emerges for staging against a non-default revision
comparison. That would need its own explicit, clearly-labeled action (e.g.
"apply this historical hunk to the index," with real user confirmation) —
not a loosening of what counts as `"working"`/`"staged"`.
